import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class AudioCaptureEngine {
  let audioEngine = AVAudioEngine()
  private var audioConverter: AVAudioConverter?
  private let targetFormat: AVAudioFormat

  // Dedicated background audio processing queue (keeps CoreAudio render thread non-blocking)
  let audioProcessingQueue = DispatchQueue(
    label: "com.adhishthite.tok.audioProcessing", qos: .userInteractive)

  let lock = NSLock()
  var isRecording: Bool = false
  var isEngineRunning: Bool { lifecycle.healthy }
  private var tapInstalled = false
  private var notificationObservers: [NSObjectProtocol] = []
  private var bufferEpoch: UInt64 = 0
  var turnInterrupted = false
  private var interruptionNotified = false
  private var queuedBuffers = 0
  // Buffer health goes straight to the lifecycle's own queue. It used to hop through main,
  // so a main-thread stall of about a second aged every buffer past the recovery
  // controller's 0.75 s freshness window: a live hold was interrupted with "Microphone
  // stopped delivering audio" and the hardware was rebuilt while audio was still flowing.
  // Internal, not private, so a test can assert the delivery target stays off main.
  lazy var healthDelivery = QueueDelivery<(UInt64, TimeInterval)>(queue: lifecycle.queue) {
    [weak self] value in
    self?.lifecycle.receivedBufferOnQueue(generation: value.0, at: value.1)
  }
  private lazy var overloadDelivery = MainQueueDelivery<UInt64> { [weak self] epoch in
    guard let self else { return }
    self.lock.lock()
    let current = self.bufferEpoch == epoch && self.turnInterrupted
    self.lock.unlock()
    if current { self.interruptCapture("Microphone audio processing could not keep up") }
  }
  var onCaptureInterrupted: ((String) -> Void)?
  lazy var lifecycle = MicrophoneLifecycle(
    rebuild: { [weak self] in self?.rebuildHardware() ?? false },
    stop: { [weak self] in self?.stopHardware() },
    running: { [weak self] in self?.audioEngine.isRunning ?? false },
    interrupted: { [weak self] reason in self?.interruptCapture(reason) }
  )
  var recordedPCMData = Data()
  private var chunkCount: Int = 0
  var recordingStartTime: CFAbsoluteTime = 0
  private var lastMeterUpdateTime: CFAbsoluteTime = 0
  // Latest RMS level while recording, polled by stopRecording's adaptive trailing-capture
  // wait; updated on every buffer (not just the 10Hz meter throttle) so the poll sees a
  // fresh reading.
  private var lastLevelDb: Double = -120.0
  private var lastLevelTime: CFAbsoluteTime = 0

  // Pre-roll rolling ring buffer (default 400ms = 6400 samples @ 16kHz = 12800 bytes)
  private var preRollRingBuffer = Data()
  private let maxPreRollBytes: Int
  private var preRollBytesInTurn = 0
  // Count of frameDbValues entries contributed by pre-roll audio at the start of this turn
  // (item AB's onset_db excludes them). Set once, right after the pre-roll folds into the
  // stats accumulator in startRecordingOnQueue, under `lock` like preRollBytesInTurn.
  private var preRollFrameCountInTurn = 0

  // Streaming chunk accumulator (CHUNK_MS; default 150ms = 4800 bytes, docs suggest ~100ms
  // for the dedicated transcribe model)
  private var pendingChunkBuffer = Data()
  private let streamingChunkTargetBytes: Int

  // Synthetic trailing silence appended at stopRecording (SILENCE_FLUSH_MS; 0 disables)
  private let silenceFlushBytes: Int

  // Silence-gate statistics, accumulated inline as audio arrives so stopRecording never
  // rescans the whole clip on the key-up critical path. Framing is continuous across
  // chunks AND across the pre-roll/live boundary, matching the old whole-clip scan
  // exactly. All under `lock`; per-frame dB values are classified against the caller's
  // threshold at stopRecording time (the threshold is a stopRecording argument).
  private static let speechFrameSamples = 320  // 20ms of 16kHz mono
  private static let minTrailSec: Double = 0.06
  // Post-roll poll step. 10ms, not 25ms: the old step quantized the exit of an
  // already-banked turn to about 75ms against a 60ms floor (measured minimum 77ms).
  private static let postRollPollSec: Double = 0.010
  var turnMaxAbsSample: Int32 = 0
  private var frameSumSquares: Double = 0
  private var frameSampleCount: Int = 0
  var frameDbValues: [Double] = []
  var statSampleCount: Int = 0

  var onAudioChunk: ((Data) -> Void)?
  var onAudioLevel: ((Double) -> Void)?

  // Item AB: milliseconds of pre-roll audio actually prepended to the turn now finishing (0
  // when pre-roll was off or the mic was cold). Snapshot under `lock`, then compute outside
  // it - no I/O or callbacks here, just arithmetic on the copy.
  var preRollMsUsedInTurn: Double {
    lock.lock()
    let bytes = preRollBytesInTurn
    lock.unlock()
    return Double(bytes) / 32.0
  }

  // Item AB: first-word-clipping proxy - the loudest of the first five 20ms frames of
  // NEWLY captured audio after capture start, excluding pre-roll. NULL (nil) if the clip has
  // no post-pre-roll frames at all. Snapshot under `lock`, compute outside it.
  var onsetDbInTurn: Double? {
    lock.lock()
    let frames = frameDbValues
    let preRollFrames = preRollFrameCountInTurn
    lock.unlock()
    return Self.onsetDb(frames: frames, preRollFrameCount: preRollFrames)
  }

  /// Pure function backing `onsetDbInTurn`, tested directly: the max of up to the first five
  /// frames at and after `preRollFrameCount`, or nil if none exist.
  static func onsetDb(frames: [Double], preRollFrameCount: Int) -> Double? {
    let start = max(0, preRollFrameCount)
    guard start < frames.count else { return nil }
    let end = min(frames.count, start + 5)
    return frames[start..<end].max()
  }

  /// Item C: pure function backing CaptureFinalizeStats.noiseFloorDb, tested directly. 10th
  /// percentile (linear interpolation between the two closest ranks) of every per-20ms-frame
  /// dB value in the clip. nil if fewer than 10 frames exist - too little signal for a
  /// percentile to mean anything.
  static func noiseFloorDb(frames: [Double]) -> Double? {
    guard frames.count >= 10 else { return nil }
    let sorted = frames.sorted()
    let rank = 0.10 * Double(sorted.count - 1)
    let lowerIndex = Int(rank)
    let upperIndex = min(lowerIndex + 1, sorted.count - 1)
    let fraction = rank - Double(lowerIndex)
    return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
  }

  /// Item C: pure function classifying why the adaptive trailing-capture loop just broke
  /// (called only at the instant `postRollWakeDelay` returns <= 0 for the same arguments, so
  /// it mirrors that function's own branching rather than re-deciding anything). `quietIsStale`
  /// is whether the iteration that made quiet win was a stale level reading rather than a
  /// genuine below-threshold one; it only changes the result when quiet (not cap) wins.
  static func trailExitReason(
    now: TimeInterval, entryTime: TimeInterval, quietStart: TimeInterval?, graceSec: Double,
    minTrailSec: Double, maxTrailSec: Double, quietIsStale: Bool
  ) -> String {
    if entryTime + maxTrailSec - now <= 0 { return "cap" }
    if let quietStart = quietStart, quietStart + graceSec - now <= 0,
      entryTime + minTrailSec - now <= 0
    {
      return quietIsStale ? "quiet_stale" : "quiet"
    }
    // Unreachable when called only at a genuine break (see postRollWakeDelay: those are the
    // only two conditions under which it returns <= 0), kept as an honest default rather than
    // one that claims a quiet exit that was not actually satisfied.
    return "cap"
  }

  // Device metadata is written on the hardware queue and read through a locked snapshot.
  private var inputSnapshot: InputDeviceCatalog.Device?
  var currentInput: InputDeviceCatalog.Device? {
    lock.lock()
    defer { lock.unlock() }
    return inputSnapshot
  }
  private let preferredInputDevice: String
  private var autoInput: Bool { preferredInputDevice.lowercased() == "auto" }
  // Hardware-queue-only: a lid flip arrived mid-dictation; re-pin once the turn is over.
  private var pendingReselect = false

  init(
    preRollMs: Int = 400, chunkMs: Int = 150, silenceFlushMs: Int = 700, inputDevice: String = ""
  ) {
    self.preferredInputDevice = inputDevice
    // Standard 16kHz 16-bit Mono Linear PCM for speech AI models
    self.targetFormat = AVAudioFormat(
      commonFormat: .pcmFormatInt16,
      sampleRate: 16000.0,
      channels: 1,
      interleaved: true
    )!
    // 16,000 samples/sec * 2 bytes/sample = 32 bytes per ms
    self.maxPreRollBytes = max(0, preRollMs * 32)
    self.streamingChunkTargetBytes = max(640, chunkMs * 32)
    self.silenceFlushBytes = max(0, silenceFlushMs * 32)
  }

  func setup(startImmediately: Bool = true) -> Bool {
    // Initialize lazy delivery/state objects before hardware work can access them.
    _ = lifecycle
    _ = healthDelivery
    _ = overloadDelivery
    // Device changes (AirPods connect/disconnect, default-input switch) invalidate both
    // the tap's captured format and the converter; AVAudioEngine posts this after
    // reconfiguring itself. Forward notifications to the serialized hardware lifecycle.
    notificationObservers.append(
      NotificationCenter.default.addObserver(
        forName: .AVAudioEngineConfigurationChange, object: audioEngine, queue: .main
      ) { [weak self] _ in
        self?.handleConfigurationChange()
      })
    // A lid open/close with an external display attached always reshuffles the screen
    // list; that's the trigger for INPUT_DEVICE=auto (the HAL itself often stays quiet).
    if autoInput {
      notificationObservers.append(
        NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
          self?.reselectForLidState()
        })
    }

    if startImmediately { lifecycle.start() }
    return true
  }

  deinit {
    for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
  }

  // Bound copied hardware buffers before allocation; callbacks never perform conversion.
  private func installTap(on inputNode: AVAudioInputNode, format: AVAudioFormat) {
    let epoch = bufferEpoch
    let generation = lifecycle.generation
    let healthDelivery = self.healthDelivery
    let overloadDelivery = self.overloadDelivery
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] (buffer, when) in
      guard let self = self else { return }
      self.lock.lock()
      let currentEpoch = self.bufferEpoch == epoch
      let accepted = currentEpoch && self.queuedBuffers < 8
      if accepted {
        self.queuedBuffers += 1
      } else if currentEpoch && self.isRecording {
        self.turnInterrupted = true
      }
      self.lock.unlock()
      guard accepted else {
        if currentEpoch { overloadDelivery.submit(epoch) }
        return
      }
      var enqueued = false
      defer {
        if !enqueued {
          self.lock.lock()
          self.queuedBuffers -= 1
          if self.isRecording { self.turnInterrupted = true }
          self.lock.unlock()
          overloadDelivery.submit(epoch)
        }
      }
      guard
        let bufferCopy = AVAudioPCMBuffer(
          pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity)
      else { return }
      bufferCopy.frameLength = buffer.frameLength
      let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
      let destination = UnsafeMutableAudioBufferListPointer(bufferCopy.mutableAudioBufferList)
      guard source.count == destination.count else { return }
      for index in source.indices {
        guard let src = source[index].mData, let dst = destination[index].mData,
          source[index].mDataByteSize <= destination[index].mDataByteSize
        else { return }
        memcpy(dst, src, Int(source[index].mDataByteSize))
      }
      let capturedAt = ProcessInfo.processInfo.systemUptime

      enqueued = true
      self.audioProcessingQueue.async {
        defer {
          self.lock.lock()
          self.queuedBuffers -= 1
          self.lock.unlock()
        }
        self.lock.lock()
        let current = self.bufferEpoch == epoch
        self.lock.unlock()
        guard current else { return }
        self.processIncomingBufferOnQueue(
          bufferCopy, generation: generation, capturedAt: capturedAt, healthDelivery: healthDelivery
        )
      }
    }
  }

  // A configuration notification can arrive before the replacement format is usable.
  // Recovery preserves run intent and retries the complete tap/converter setup.
  private func handleConfigurationChange() {
    lifecycle.configurationChanged()
  }

  // INPUT_DEVICE=auto. Inspect on the hardware queue; only change a different device.
  // Defer until the turn ends while recording, since rebuilding would drop buffers.
  func reselectForLidState() {
    lifecycle.queue.async { [self] in reselectOnHardwareQueue() }
  }

  private func reselectOnHardwareQueue() {
    guard autoInput else { return }
    let devices = InputDeviceCatalog.inputDevices()
    guard let target = targetInput(in: devices), let unit = audioEngine.inputNode.audioUnit,
      activeDevice(of: unit) != target.id
    else { return }

    lock.lock()
    let recording = isRecording
    lock.unlock()
    if recording {
      pendingReselect = true
      return
    }
    pendingReselect = false
    lifecycle.configurationChanged()
  }

  // Main-thread-only, called after each turn settles.
  func applyPendingReselect() {
    lifecycle.queue.async { [self] in
      if pendingReselect { reselectOnHardwareQueue() }
    }
  }

  private func interruptCapture(_ reason: String) {
    lock.lock()
    let notify = isRecording && !interruptionNotified
    if isRecording {
      turnInterrupted = true
      interruptionNotified = true
    }
    lock.unlock()
    if notify { onCaptureInterrupted?(reason) }
  }

  private func stopHardware() {
    audioEngine.stop()
    if tapInstalled {
      audioEngine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
    audioProcessingQueue.sync {
      lock.lock()
      bufferEpoch &+= 1
      preRollRingBuffer.removeAll(keepingCapacity: true)
      lock.unlock()
      audioConverter = nil
    }
  }

  private func rebuildHardware() -> Bool {
    let inputNode = audioEngine.inputNode
    applyInputDeviceSelection()
    let inputFormat = inputNode.outputFormat(forBus: 0)
    guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
      inputFormat.channelCount > 0,
      let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
    else {
      Log.warn("MIC", "Microphone format unavailable; recovery will retry.")
      return false
    }
    audioProcessingQueue.sync { self.audioConverter = converter }
    installTap(on: inputNode, format: inputFormat)
    tapInstalled = true
    audioEngine.prepare()
    do {
      try audioEngine.start()
      return true
    } catch {
      Log.warn("MIC", "Microphone start failed; recovery will retry.")
      return false
    }
  }

  private func targetInput(in devices: [InputDeviceCatalog.Device]) -> InputDeviceCatalog.Device? {
    if autoInput {
      return InputDeviceCatalog.autoSelection(
        in: devices, lidClosed: InputDeviceCatalog.lidClosed() ?? false)
    }
    return InputDeviceCatalog.match(preferredInputDevice, in: devices)
  }

  var currentInputLabel: String {
    guard let d = currentInput else { return "unknown input" }
    return d.label + (d.isDefault ? " (system default)" : "")
  }

  // Pins the AUHAL behind inputNode to the configured device (the property must be set
  // before the engine initializes the unit, which prepare()/start() does), then records
  // whichever device the unit ended up on - pinned, or the default when nothing matched.
  private func applyInputDeviceSelection() {
    let devices = InputDeviceCatalog.inputDevices()
    let unit = audioEngine.inputNode.audioUnit

    if !preferredInputDevice.isEmpty {
      if let match = targetInput(in: devices) {
        // Skip the write when already on the device: on a configuration change the
        // unit is initialized and the property write would fail, but the pin holds.
        if let unit = unit, activeDevice(of: unit) != match.id {
          var deviceID = match.id
          let status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
            &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
          if status != noErr {
            Log.warn(
              "MIC",
              "Could not pin input to \(match.label) (OSStatus \(status)) - using whatever the engine has."
            )
          }
        }
      } else if !autoInput {
        let available = devices.map { $0.name }.joined(separator: ", ")
        Log.warn(
          "MIC",
          "INPUT_DEVICE \"\(preferredInputDevice)\" matched no input device - using the system default. Available: \(available)"
        )
      }
    }

    let selectedInput: InputDeviceCatalog.Device?
    if let unit = unit, let activeID = activeDevice(of: unit) {
      selectedInput =
        devices.first(where: { $0.id == activeID })
        ?? InputDeviceCatalog.describe(
          activeID, isDefault: activeID == InputDeviceCatalog.defaultInputDevice())
    } else {
      selectedInput = devices.first(where: { $0.isDefault })
    }
    lock.lock()
    inputSnapshot = selectedInput
    lock.unlock()
  }

  private func activeDevice(of unit: AudioUnit) -> AudioDeviceID? {
    var activeID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    let status = AudioUnitGetProperty(
      unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &activeID, &size)
    guard status == noErr, activeID != 0 else { return nil }
    return activeID
  }

  func suspendEngine(completion: @escaping () -> Void = {}) {
    lock.lock()
    let recording = isRecording
    lock.unlock()
    guard !recording else { return }
    lifecycle.suspend(completion: completion)
  }

  func ensureReady(completion: @escaping (Bool) -> Void) {
    lifecycle.ensureReady(completion)
  }

  func prepareInput(completion: @escaping (MicrophonePreparationMeasurement) -> Void) {
    lifecycle.queue.async { [self] in
      let start = ProcessInfo.processInfo.systemUptime
      let node = audioEngine.inputNode
      var running: UInt32 = 0
      var size = UInt32(MemoryLayout<UInt32>.size)
      let status =
        node.audioUnit.map {
          AudioUnitGetProperty(
            $0, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &running, &size)
        } ?? kAudio_ParamError
      let measurement = MicrophonePreparationMeasurement(
        milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000,
        engineRunning: audioEngine.isRunning, audioUnitStatus: status, audioUnitRunning: running)
      DispatchQueue.main.async { completion(measurement) }
    }
  }

  func cancelPendingReadiness() { lifecycle.cancelPendingReadiness() }

  private func processIncomingBufferOnQueue(
    _ inputBuffer: AVAudioPCMBuffer, generation: UInt64, capturedAt: TimeInterval,
    healthDelivery: QueueDelivery<(UInt64, TimeInterval)>
  ) {
    guard let converter = audioConverter, inputBuffer.format == converter.inputFormat,
      inputBuffer.format.sampleRate.isFinite, inputBuffer.format.sampleRate > 0
    else {
      discardFailedBuffer()
      return
    }

    let ratio = 16000.0 / inputBuffer.format.sampleRate
    let outCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 64)
    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity)
    else {
      discardFailedBuffer()
      return
    }

    var error: NSError?
    var consumed = false

    let status = converter.convert(to: outputBuffer, error: &error) { _, outStatus in
      if !consumed {
        consumed = true
        outStatus.pointee = .haveData
        return inputBuffer
      } else {
        outStatus.pointee = .noDataNow
        return nil
      }
    }

    guard status != .error, error == nil else {
      discardFailedBuffer()
      return
    }
    if outputBuffer.frameLength > 0, let int16Pointer = outputBuffer.int16ChannelData?[0] {
      let byteCount = Int(outputBuffer.frameLength) * 2
      let chunkData = Data(bytes: int16Pointer, count: byteCount)
      healthDelivery.submit((generation, capturedAt))

      lock.lock()
      if turnInterrupted && isRecording {
        lock.unlock()
        return
      }
      let currentlyRecording = isRecording

      if !currentlyRecording {
        // Maintain 250ms pre-roll circular buffer while idle
        preRollRingBuffer.append(chunkData)
        if preRollRingBuffer.count > maxPreRollBytes {
          preRollRingBuffer.removeFirst(preRollRingBuffer.count - maxPreRollBytes)
        }
        lock.unlock()
        return
      }

      recordedPCMData.append(chunkData)
      pendingChunkBuffer.append(chunkData)
      chunkCount += 1
      accumulateStats(samples: int16Pointer, count: Int(outputBuffer.frameLength))

      // 10Hz meter throttle decision must happen under the lock since it mutates
      // lastMeterUpdateTime; only snapshot the meter's inputs when actually needed.
      let now = ProcessInfo.processInfo.systemUptime
      var shouldUpdateMeter = false
      var elapsed: Double = 0
      var kbStreamed: Double = 0
      var chunkCountSnapshot = 0
      if (now - lastMeterUpdateTime) > 0.10 {
        lastMeterUpdateTime = now
        shouldUpdateMeter = true
        elapsed = now - recordingStartTime
        kbStreamed = Double(recordedPCMData.count) / 1024.0
        chunkCountSnapshot = chunkCount
      }

      // Coalesce audio into ~150ms frames before dispatching to WebSocket
      var toStream: Data? = nil
      if pendingChunkBuffer.count >= streamingChunkTargetBytes {
        toStream = pendingChunkBuffer
        pendingChunkBuffer.removeAll(keepingCapacity: true)
      }
      lock.unlock()

      // Audio delivery leads everything else on this queue: stdout is unbuffered and the
      // meter write below is a synchronous flush, so a slow or blocked terminal must
      // never sit between a finished chunk and its trip to the WebSocket.
      if let toStream = toStream {
        onAudioChunk?(toStream)
      }

      // RMS math runs for every buffer while recording (not just the meter's 10Hz
      // throttle) so stopRecording's adaptive trailing-capture poll always sees a fresh
      // level. int16Pointer is still valid here - it points into outputBuffer, a local
      // var alive for this call. Meter rendering and the onAudioLevel callback stay
      // gated by shouldUpdateMeter as before.
      var sumSquare: Double = 0.0
      let sampleCount = Int(outputBuffer.frameLength)
      for i in 0..<sampleCount {
        let sample = Double(int16Pointer[i])
        sumSquare += sample * sample
      }
      let rms = sqrt(sumSquare / Double(max(sampleCount, 1)))
      let db = 20.0 * log10(max(rms, 1.0) / 32768.0)

      lock.lock()
      lastLevelDb = db
      lastLevelTime = ProcessInfo.processInfo.systemUptime
      lock.unlock()

      // HUD level first, terminal meter last - the print is the only call here that can
      // block on an external consumer.
      if shouldUpdateMeter {
        onAudioLevel?(db)
        let meterBars = renderVolumeMeter(db: db)
        Log.meter(
          "🎙️  RECORDING [\(meterBars)] \(String(format: "%5.1f", db)) dB | \(String(format: "%.2fs", elapsed)) | \(String(format: "%.1f", kbStreamed)) KB streamed (#\(chunkCountSnapshot))"
        )
      }
    }
  }

  // A single conversion failure loses speech even when the following buffer is healthy.
  func discardFailedBuffer() {
    lock.lock()
    if isRecording { turnInterrupted = true }
    let epoch = bufferEpoch
    lock.unlock()
    overloadDelivery.submit(epoch)
  }

  private func renderVolumeMeter(db: Double) -> String {
    let normalized = max(0.0, min(1.0, (db + 50.0) / 50.0))
    let totalBlocks = 12
    let filledBlocks = Int(round(normalized * Double(totalBlocks)))
    let emptyBlocks = totalBlocks - filledBlocks

    let filledStr = String(repeating: "█", count: filledBlocks)
    let emptyStr = String(repeating: "░", count: emptyBlocks)
    return "\(filledStr)\(emptyStr)"
  }

  // Assumes `lock` is held. Streams samples into the peak + 20ms-frame RMS accumulators.
  // Pure math - no I/O or callbacks under the lock.
  private func accumulateStats(samples: UnsafePointer<Int16>, count: Int) {
    for i in 0..<count {
      let s = Int32(samples[i])
      let a = abs(s)
      if a > turnMaxAbsSample { turnMaxAbsSample = a }
      let norm = Double(s) / 32768.0
      frameSumSquares += norm * norm
      frameSampleCount += 1
      if frameSampleCount == Self.speechFrameSamples {
        let rms = (frameSumSquares / Double(Self.speechFrameSamples)).squareRoot()
        frameDbValues.append(20 * log10(max(rms, 1e-9)))
        frameSumSquares = 0
        frameSampleCount = 0
      }
    }
    statSampleCount += count
  }

  // Assumes `lock` is held. Byte-pair assembly because Data's storage isn't guaranteed
  // 2-byte aligned; only used for the pre-roll (≤400ms), live audio feeds the pointer
  // variant directly.
  private func accumulateStats(data: Data) {
    let sampleCount = data.count / 2
    guard sampleCount > 0 else { return }
    var samples = [Int16](repeating: 0, count: sampleCount)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for i in 0..<sampleCount {
        samples[i] = Int16(bitPattern: UInt16(raw[2 * i]) | (UInt16(raw[2 * i + 1]) << 8))
      }
    }
    samples.withUnsafeBufferPointer { buf in
      accumulateStats(samples: buf.baseAddress!, count: buf.count)
    }
  }

  @discardableResult func startRecording() -> Bool {
    guard isEngineRunning else { return false }
    audioProcessingQueue.sync { startRecordingOnQueue() }
    return true
  }

  private func startRecordingOnQueue() {
    lock.lock()
    turnInterrupted = false
    interruptionNotified = false
    recordedPCMData.removeAll(keepingCapacity: true)
    pendingChunkBuffer.removeAll(keepingCapacity: true)
    turnMaxAbsSample = 0
    frameSumSquares = 0
    frameSampleCount = 0
    frameDbValues.removeAll(keepingCapacity: true)
    statSampleCount = 0

    // Prepend rolling pre-roll buffer to prevent clipped first syllable
    preRollBytesInTurn = 0
    preRollFrameCountInTurn = 0
    var immediatePreRollChunk: Data? = nil
    if !preRollRingBuffer.isEmpty {
      preRollBytesInTurn = preRollRingBuffer.count
      recordedPCMData.append(preRollRingBuffer)
      immediatePreRollChunk = preRollRingBuffer
      // Pre-roll bytes bypass the live accumulation below (they were captured while
      // idle), so their stats are folded in once here - a ≤400ms scan, off the key-up
      // path entirely.
      accumulateStats(data: preRollRingBuffer)
      // Frames the pre-roll completed; onset_db (item AB) starts reading after this many.
      preRollFrameCountInTurn = frameDbValues.count
      preRollRingBuffer.removeAll(keepingCapacity: true)
    }

    chunkCount = 0
    recordingStartTime = ProcessInfo.processInfo.systemUptime
    lastMeterUpdateTime = 0
    isRecording = true
    lock.unlock()

    // Immediately dispatch pre-roll audio to WebSocket so speech model receives head-start
    // audio - split into streaming-target-sized frames rather than one oversized payload
    // (the whole pre-roll still goes out right now; only the framing changes).
    if let chunk = immediatePreRollChunk {
      var offset = chunk.startIndex
      while offset < chunk.endIndex {
        let end =
          chunk.index(offset, offsetBy: streamingChunkTargetBytes, limitedBy: chunk.endIndex)
          ?? chunk.endIndex
        onAudioChunk?(chunk.subdata(in: offset..<end))
        offset = end
      }
    }
  }

  /// How long the post-roll wait should sleep before it looks at the microphone again.
  /// Zero means every condition is already met and the wait may end now.
  ///
  /// The grace window can still be pushed out by new speech, so while it is open the wait
  /// polls. The minTrailSec floor cannot move, so once grace is satisfied the wait sleeps
  /// straight to the floor instead of stepping toward it in poll-sized hops. That is what
  /// removes the quantization: a turn that banked its quiet before key-up used to leave at
  /// three 25ms polls (about 75ms) against a 60ms floor, and now leaves at the floor.
  /// The semantics of graceSec, minTrailSec and maxTrailSec are unchanged; only the instant
  /// the loop notices they are met moves. minTrailSec still exists so that even a fully
  /// banked window keeps a sliver of post-release capture: a soft final fricative can sit
  /// under the threshold and a hardware buffer's worth of it may still be in flight at
  /// key-up.
  static func postRollWakeDelay(
    now: TimeInterval, entryTime: TimeInterval, quietStart: TimeInterval?, graceSec: Double,
    minTrailSec: Double, maxTrailSec: Double, pollSec: Double = AudioCaptureEngine.postRollPollSec
  ) -> TimeInterval {
    let capRemaining = entryTime + maxTrailSec - now
    if capRemaining <= 0 { return 0 }
    // Speaking: only the hard cap can end the wait, so poll for the next quiet frame.
    guard let quietStart = quietStart else { return min(pollSec, capRemaining) }
    if quietStart + graceSec - now > 0 { return min(pollSec, capRemaining) }
    let floorRemaining = entryTime + minTrailSec - now
    if floorRemaining <= 0 { return 0 }
    return min(floorRemaining, capRemaining)
  }

  func stopRecording(gracePeriodMs: Int, maxTrailMs: Int, silenceThresholdDb: Double) -> (
    pcmData: Data, duration: Double, chunkCount: Int, capturedBytes: Int, peakDb: Double?,
    speechFrames: Int, interrupted: Bool, finalize: CaptureFinalizeStats
  ) {
    // True hold duration is measured at entry, BEFORE the post-roll wait - otherwise the
    // grace period pads every tap past the caller's micro-click duration threshold.
    let stopRequestTime = ProcessInfo.processInfo.systemUptime

    // Item C: capture finalization diagnostics for whichever branch below runs. All default
    // to the "no wait happened" values; the adaptive branch is the only one that overwrites
    // drainMs/bankedQuietMs/quietResets/trailPeakDb, matching CaptureFinalizeStats' own
    // "0/nil when that branch never ran" contract.
    var finalizeExit = "none"
    var finalizeDrainMs = 0.0
    var bankedQuietMs = 0.0
    var quietResets = 0
    var trailPeakDb: Double? = nil

    // 1. Trailing capture: keep streaming while speech energy persists. gracePeriodMs is the
    // required continuous-quiet window; maxTrailMs the hard cap. maxTrailMs <= gracePeriodMs
    // degenerates to the old fixed post-roll. A stale level reading (engine stall) counts as
    // quiet so a wedged tap can never hold the turn to the cap.
    if gracePeriodMs <= 0 {
      // Adaptation and fixed post-roll both disabled - no wait.
      finalizeExit = "none"
    } else if maxTrailMs <= gracePeriodMs {
      usleep(useconds_t(gracePeriodMs * 1000))
      finalizeExit = "fixed"
    } else {
      let graceSec = Double(gracePeriodMs) / 1000.0
      let maxTrailSec = Double(maxTrailMs) / 1000.0
      // Quiet banked BEFORE the release counts toward the window: most releases come
      // after the speaker has already finished, and the old floor of a full window
      // after key-up was ~250ms of pure wait on those turns (history p50 capture
      // finalize 290ms, min 283ms). The trailing sub-threshold 20ms frames give the
      // banked quiet without timestamps, PROVIDED the stats are current: drain the
      // processing queue first, or a backlog (blocked meter write) would leave loud
      // buffers unaccounted for while their frames get credited as quiet. After the
      // drain the only lag is the in-flight hardware buffer, which under-credits.
      let drainStart = ProcessInfo.processInfo.systemUptime
      audioProcessingQueue.sync {}
      finalizeDrainMs = (ProcessInfo.processInfo.systemUptime - drainStart) * 1000.0
      lock.lock()
      var quietFrames = 0
      for db in frameDbValues.reversed() {
        if db > silenceThresholdDb { break }
        quietFrames += 1
      }
      lock.unlock()
      bankedQuietMs = Double(quietFrames) * 20.0
      var quietStart: CFAbsoluteTime? =
        quietFrames > 0 ? stopRequestTime - Double(quietFrames) * 0.02 : nil
      // Item C: whether the iteration that will end up satisfying "quiet" was a stale level
      // reading, tracked as the loop runs so the classification below needs no re-derivation.
      var lastIterationStale = false
      while true {
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        let levelDb = lastLevelDb
        let levelTime = lastLevelTime
        lock.unlock()

        trailPeakDb = trailPeakDb.map { max($0, levelDb) } ?? levelDb
        let stale = (now - levelTime) > 0.30
        lastIterationStale = stale
        let speaking = !stale && levelDb >= silenceThresholdDb
        if speaking {
          if quietStart != nil { quietResets += 1 }
          quietStart = nil
        } else if quietStart == nil {
          quietStart = now
        }

        let delay = Self.postRollWakeDelay(
          now: now, entryTime: stopRequestTime, quietStart: quietStart, graceSec: graceSec,
          minTrailSec: Self.minTrailSec, maxTrailSec: maxTrailSec)
        if delay <= 0 {
          finalizeExit = Self.trailExitReason(
            now: now, entryTime: stopRequestTime, quietStart: quietStart, graceSec: graceSec,
            minTrailSec: Self.minTrailSec, maxTrailSec: maxTrailSec,
            quietIsStale: lastIterationStale)
          break
        }
        // Round up so a sub-microsecond remainder cannot spin the loop.
        usleep(useconds_t(max(1.0, (delay * 1_000_000).rounded(.up))))
      }

      let totalWaitMs = (ProcessInfo.processInfo.systemUptime - stopRequestTime) * 1000.0
      if totalWaitMs > Double(gracePeriodMs) + 1.0 {
        Log.debug(
          "AUDIO",
          "Trailing speech captured: +\(Int(totalWaitMs - Double(gracePeriodMs)))ms past post-roll")
      } else if totalWaitMs < Double(gracePeriodMs) - 1.0 {
        Log.debug(
          "AUDIO",
          "Post-roll shortened to \(Int(totalWaitMs))ms (\(quietFrames * 20)ms quiet banked before release)"
        )
      }
    }

    let trailWaitMs = (ProcessInfo.processInfo.systemUptime - stopRequestTime) * 1000.0

    return audioProcessingQueue.sync {
      finishRecording(
        stopRequestTime: stopRequestTime, silenceThresholdDb: silenceThresholdDb,
        finalizeExit: finalizeExit, finalizeDrainMs: finalizeDrainMs, trailWaitMs: trailWaitMs,
        bankedQuietMs: bankedQuietMs, quietResets: quietResets, trailPeakDb: trailPeakDb)
    }
  }

  private func finishRecording(
    stopRequestTime: CFAbsoluteTime, silenceThresholdDb: Double, finalizeExit: String,
    finalizeDrainMs: Double, trailWaitMs: Double, bankedQuietMs: Double, quietResets: Int,
    trailPeakDb: Double?
  ) -> (
    pcmData: Data, duration: Double, chunkCount: Int, capturedBytes: Int, peakDb: Double?,
    speechFrames: Int, interrupted: Bool, finalize: CaptureFinalizeStats
  ) {
    // The gate and final chunk delivery share the capture queue. A new hardware buffer
    // cannot send later audio ahead of the pre-roll or after the end-of-turn signal.
    lock.lock()
    isRecording = false

    // 3. Real captured byte count: taken before the silence flush below is appended, and
    // excluding the prepended pre-roll, so callers see genuine key-held speech audio only.
    let interrupted = turnInterrupted
    let capturedBytes = max(0, recordedPCMData.count - preRollBytesInTurn)

    // 4. Collect any trailing pending chunk; fired via onAudioChunk after the lock is released
    var trailingChunk: Data? = nil
    if !pendingChunkBuffer.isEmpty {
      trailingChunk = pendingChunkBuffer
      pendingChunkBuffer.removeAll(keepingCapacity: true)
    }

    // 5. Append the acoustic lookahead silence flush (SILENCE_FLUSH_MS; default 700ms =
    // 22,400 bytes @ 16kHz 16-bit mono). This satisfies the lookahead window speech
    // encoders need to finalize trailing words; appended AFTER stat accumulation stopped,
    // so the silence gate never sees it regardless of duration.
    let silenceData = Data(count: silenceFlushBytes)
    if !silenceData.isEmpty {
      recordedPCMData.append(silenceData)
    }

    let data = recordedPCMData
    let duration = stopRequestTime - recordingStartTime
    let chunks = chunkCount

    // 6. Silence-gate stats from the running accumulators - no rescan of the clip. The
    // silence flush above was appended AFTER accumulation stopped, so it can never mask
    // genuine silence; nil peak means zero real (pre-roll + key-held) samples, which
    // callers treat as "not silent", matching the old too-short-clip behavior.
    let peakDb: Double? =
      statSampleCount > 0 ? 20 * log10(max(Double(turnMaxAbsSample), 1.0) / 32768.0) : nil
    var speechFrames = 0
    for db in frameDbValues where db > silenceThresholdDb { speechFrames += 1 }
    // Item C: whole-clip noise floor, from the same frameDbValues population speechFrames
    // just counted from - still under `lock`, still pure math on the accumulator.
    let noiseFloorDb = Self.noiseFloorDb(frames: frameDbValues)
    lock.unlock()

    let finalize = CaptureFinalizeStats(
      exit: finalizeExit, drainMs: finalizeDrainMs, trailWaitMs: trailWaitMs,
      bankedQuietMs: bankedQuietMs, quietResets: quietResets, trailPeakDb: trailPeakDb,
      noiseFloorDb: noiseFloorDb)

    // 7. Fire chunk callbacks outside the lock. Ordering preserved: trailing real audio first, then silence.

    if !interrupted, let trailing = trailingChunk {
      onAudioChunk?(trailing)
    }
    if !interrupted, !silenceData.isEmpty {
      onAudioChunk?(silenceData)
    }

    Log.endMeter()
    return (data, duration, chunks, capturedBytes, peakDb, speechFrames, interrupted, finalize)
  }

  func stopEngine() {
    // Keep the AVAudioEngine owner alive until queued hardware shutdown completes.
    lifecycle.suspend { [self] in withExtendedLifetime(self) {} }
  }
}
