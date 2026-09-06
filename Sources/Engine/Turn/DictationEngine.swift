import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

// MARK: - Orchestrator (Core State Machine)

public final class DictationEngine {
  // Main-thread-only gate for the setup shortcut test.
  public var acceptsNewCaptures = true
  private var stopping = false
  private var isStopping: Bool {
    processingLock.lock()
    defer { processingLock.unlock() }
    return stopping
  }
  private let feedback = EngineFeedback()
  public weak var delegate: DictationEngineDelegate? {
    didSet {
      feedback.delegate = delegate
      Log.configure(
        delegate: delegate, apiKey: config.geminiApiKey, privacyMode: config.privacyMode)
    }
  }
  let config: EngineConfiguration
  let audioCapture: AudioCaptureEngine
  private var liveClient: GeminiLiveClient?
  private var hotkeyManager: HotkeyManager?
  let history: HistoryStore?
  private var correctionWatcher: CorrectionWatcher?

  // Cross-thread "is a turn active" flag - read synchronously from the event-tap thread in
  // handleKeyDown (must stay fast/non-blocking), written only from sessionQueue-executed code.
  var isProcessing: Bool = false
  let processingLock = NSLock()

  // Main-thread-only: true iff the LAST key-down actually started a capture. A key-down
  // refused by a gate (isProcessing, secure input, offline) still delivers its matching
  // key-up, and stopRecording without a matching start would resurrect the PREVIOUS
  // turn's buffer - re-billing the API and re-pasting a stale transcript.
  private var captureActive: Bool = false
  private var capturePending = false
  private var captureGeneration: UInt64 = 0

  // Main-thread-only hold-to-lock state. turnLocked: the hold outlasted HOLD_TO_LOCK, so
  // the physical release is a non-event and the NEXT key-down finishes the turn.
  // lockWorkItem fires the lock; lockLimitWorkItem finishes a locked turn nobody came back
  // for. Any key-up that really finishes the turn cancels both, and the lock item re-checks
  // captureActive so a release a few ms before it fires can never lock a turn that ended.
  private var turnLocked: Bool = false
  private var lockWorkItem: DispatchWorkItem?
  private var lockLimitWorkItem: DispatchWorkItem?
  // How the current turn's hold ended (finish_mode in history): written on main in
  // handleKeyUp before the pipeline is dispatched, read on sessionQueue like the
  // turnFrontmost* fields.
  private var turnFinishMode: String?

  // sessionQueue-only: consecutive turns that ended with no speech detected. Three in a row
  // is the signature of a dead input (mic permission revoked, wrong device) - worth a hint.
  private var consecutiveNoSpeechTurns = 0

  // Peak level, in dBFS, below which a captured clip is treated as room tone rather than
  // speech - below this peak no speech exists in the clip, so don't bill an API call for it.
  private let silentClipPeakDb: Double = -55.0

  // Peak alone can't catch silence: the physical hotkey click sits inside every capture's
  // pre-roll and spikes the peak above silentClipPeakDb. A click is a 1-2 frame transient,
  // while even the shortest word sustains 100ms+ of energy, so a clip with at most this many
  // 20ms frames above TRAIL_SILENCE_DB is also gated as silent.
  private let silentClipMaxSpeechFrames = 2

  // When the live STT model reports "no speech recognized" AND the clip has fewer speech-energy
  // frames than this, that verdict is trusted as an authoritative empty turn - the REST fallback
  // is suppressed (flash-lite hallucinates plausible greetings when handed room tone). With
  // this many frames or more, the fallback still runs: a stalled-but-connected WS must not be
  // able to drop a real dictation.
  private let wsNoSpeechTrustFrames = 5

  // Frontmost app snapshotted at key-down (main thread); compared again right before paste
  // so a focus change mid-turn downgrades to clipboard-only instead of pasting into the wrong app.
  private var turnFrontmostPID: pid_t?
  private var turnFrontmostName: String?
  private var turnFrontmostBundleId: String?
  // Capture device at key-down (main-thread read of the engine's current input), stamped on
  // the row so a bad transcript can be traced to the display mic vs the built-in one.
  private var turnInputDevice: String?
  private var turnInputTransport: String?

  // sessionQueue-only, set once per turn: the clip's silence-gate evidence (from
  // stopRecording's accumulators) and, for WS turns, which settlement rule fired -
  // stamped onto this turn's history rows so the A/B knobs can be tuned from real data.
  private var turnPeakDb: Double?
  private var turnSpeechFrames: Int?
  private var turnSettlePath: String?

  // Serial queue that owns all turn lifecycle state below. Both the WS commit completion and
  // the REST fallback timer used to race directly against a captured `var didFallback` bool
  // with no synchronization, so a slow-arriving WS result and a just-fired fallback timer could
  // both call handleTranscribedText and paste the turn twice. Funneling every route through
  // this serial queue makes turn settlement a single-writer state machine.
  let sessionQueue = DispatchQueue(
    label: "com.adhishthite.tok.session", qos: .userInteractive)
  private var currentTurnId: UInt64 = 0
  var turnSettled: Bool = false
  private var pendingFallbackTimer: DispatchWorkItem?
  private var pendingTurnDeadline: DispatchWorkItem?
  lazy var postProcessingStage = PostProcessingStage(queue: sessionQueue)
  var pendingRestRequest: CancellableRequest?
  var restAttemptStart: TimeInterval?
  private var turnEventQueueMs: Double = 0
  private var turnReleaseTime: TimeInterval = 0
  private var turnCaptureFinalizeMs: Double = 0

  // Main-thread-only: pending mic release for MIC_IDLE_TIMEOUT. Cancelled on every key-down,
  // re-armed whenever a turn finishes.
  var micIdleWorkItem: DispatchWorkItem?
  var scheduleRejectedTurnUI: (@escaping () -> Void) -> Void = { action in
    DispatchQueue.main.async(execute: action)
  }

  // Main-thread-only: the delayed duck for the current turn. Ducking waits ~350ms so the
  // begin earcon plays at full volume (an immediate duck swallowed it - "my sounds
  // disappeared"); the item itself checks captureActive so a micro-click turn that already
  // restored can never leave the output stuck ducked.
  private var pendingDuckItem: DispatchWorkItem?

  /// Main-thread-only. Schedules the mic to be released after the configured idle window so
  /// the macOS mic indicator turns off between dictation sessions; 0 disables the timeout.
  private func scheduleMicIdleRelease() {
    guard !captureActive, !capturePending else { return }
    processingLock.lock()
    let busy = isProcessing
    processingLock.unlock()
    guard !busy else { return }
    // Every turn ends here on main - the spot to apply a lid flip that arrived mid-turn.
    TextInjector.discardPreparedClipboard()
    audioCapture.applyPendingReselect()
    micIdleWorkItem?.cancel()
    micIdleWorkItem = nil
    if !config.keepMicrophoneWarm {
      audioCapture.suspendEngine()
      return
    }
    guard config.micIdleTimeoutSec > 0 else { return }

    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.micIdleWorkItem = nil
      self.audioCapture.suspendEngine { [weak self] in
        guard let self, !self.capturePending, !self.captureActive, !self.isStopping else { return }
        self.feedback.micReleased()
        Log.info("MIC", "Microphone released after inactivity.")
      }
    }
    micIdleWorkItem = item
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Double(config.micIdleTimeoutSec), execute: item)
  }

  public init(config: EngineConfiguration) {
    self.config = config
    self.audioCapture = AudioCaptureEngine(
      preRollMs: config.preRollMs, chunkMs: config.chunkMs, silenceFlushMs: config.silenceFlushMs,
      inputDevice: config.inputDevice)
    if config.enableLiveWebSocket && !config.geminiApiKey.isEmpty {
      self.liveClient = GeminiLiveClient(
        apiKey: config.geminiApiKey,
        model: config.geminiLiveModel,
        smartTranscription: config.smartTranscription,
        languageCodes: config.languageCodes,
        customVocabulary: config.customVocabulary,
        vadMode: config.vadMode,
        vadSilenceMs: config.vadSilenceMs,
        endpointAligned: config.wsEndpointAligned
      )
    }
    self.history = config.historyEnabled ? HistoryStore(config: config) : nil
    if config.learnCorrections {
      self.correctionWatcher = CorrectionWatcher(config: config, history: self.history)
      if !config.historyEnabled {
        Log.warn(
          "LEARN",
          "LEARN_CORRECTIONS is on but HISTORY=false - observed corrections will be printed but not stored for `make analyze`."
        )
      }
    }
  }

  public func start() {
    SoundManager.prepare()
    // Connectivity truth for the key-down offline gate.
    NetworkMonitor.shared.start()

    guard PermissionChecker.verifyAll().accessibility,
      PermissionChecker.verifyAll().microphone, CGPreflightListenEventAccess()
    else {
      feedback.showError(
        message: "Grant microphone, Accessibility, and Input Monitoring access in Tok.")
      return
    }
    guard !config.geminiApiKey.isEmpty else {
      feedback.showError(message: "Add a Gemini API key to start dictating.")
      return
    }
    // 3. Initialize Audio Capture Engine
    audioCapture.onCaptureInterrupted = { [weak self] _ in
      guard let self = self, self.captureActive else { return }
      self.turnLocked = false
      self.handleKeyUp(finish: "input_interrupted")
    }
    if !audioCapture.setup(startImmediately: config.keepMicrophoneWarm) {
      Log.warn("MIC", "Microphone unavailable; recovery will retry.")
    }
    if !config.keepMicrophoneWarm {
      // Construct the input node ahead of the first shortcut without starting audio I/O.
      audioCapture.prepareInput { _ in }
    }

    // The mic idle countdown starts at launch: no dictation for the configured window
    // releases the mic until the next key-down.
    scheduleMicIdleRelease()

    // Wire audio chunks to Gemini Live WebSocket streaming
    audioCapture.onAudioChunk = { [weak self] chunk in
      self?.liveClient?.sendAudioChunk(chunk)
    }

    // Wire audio level (dB) to Floating HUD
    let levelDelivery = MainQueueDelivery<Double> { [weak self] db in
      self?.feedback.updateAudioLevel(db: db)
    }
    audioCapture.onAudioLevel = { db in levelDelivery.submit(db) }

    // 4. Pre-warm Gemini Live WebSocket & wire streaming text to HUD
    if config.enableLiveWebSocket {
      let textDelivery = MainQueueDelivery<String> { [weak self] text in
        self?.feedback.updateLiveText(text)
      }
      liveClient?.onLiveTextUpdate = { text in textDelivery.submit(text) }
      liveClient?.connect()
    }

    // Pre-warm the REST fallback route's connection (DNS + TCP + TLS handshake) so that if
    // the REST fallback is ever needed, it isn't paying cold-connection cost on the critical
    // path. Uses URLSession.shared, the same pool GeminiRestClient makes its calls from.
    if !config.geminiApiKey.isEmpty {
      let prewarmStart = ProcessInfo.processInfo.systemUptime
      if let prewarmUrl = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")
      {
        var prewarmRequest = URLRequest(url: prewarmUrl)
        prewarmRequest.timeoutInterval = 10.0
        prewarmRequest.setValue(config.geminiApiKey, forHTTPHeaderField: "x-goog-api-key")
        URLSession.shared.dataTask(with: prewarmRequest) { _, response, _ in
          let elapsedMs = (ProcessInfo.processInfo.systemUptime - prewarmStart) * 1000.0
          let status = (response as? HTTPURLResponse)?.statusCode ?? -1
          Log.debug(
            "REST", "Connection pre-warmed (\(String(format: "%.0f", elapsedMs))ms, HTTP \(status))"
          )
        }.resume()
      }
    }

    // 5. Setup Hotkey Listener
    let binding = HotkeyManager.KeyBinding.from(string: config.hotkey)
    let hotkey = HotkeyManager(binding: binding, mode: config.hotkeyMode)

    hotkey.onKeyDown = { [weak self] in
      self?.handleKeyDown()
    }

    hotkey.onKeyUp = { [weak self, weak hotkey] in
      self?.handleKeyUp(eventTime: hotkey?.lastEventUptime)
    }

    // Sleep/wake hygiene: release the mic before sleep (suspendEngine refuses mid-dictation),
    // and force a fresh WS connection on wake - the socket often survives sleep in a
    // half-dead state where sends succeed but no server responses ever arrive.
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.audioCapture.suspendEngine()
      Log.info("POWER", "System sleeping - mic released.")
    }
    NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      Log.info("POWER", "System woke - refreshing Live WebSocket connection.")
      if self.config.enableLiveWebSocket {
        self.liveClient?.disconnect()
        self.liveClient?.connect()
      }
    }

    guard hotkey.start() else {
      Log.error(
        "HOTKEY",
        "Could not detect the shortcut. Enable Input Monitoring and Accessibility for Tok."
      )
      feedback.showError(message: "Enable Input Monitoring and Accessibility for Tok.")
      return
    }
    self.hotkeyManager = hotkey

    feedback.ready()
  }

  private func recordTurn(_ record: TurnRecord) {
    history?.record(record)
    delegate?.engineDidEmit(.turnSettled(record))
  }

  public func stop() {
    processingLock.lock()
    stopping = true
    processingLock.unlock()
    capturePending = false
    captureGeneration &+= 1
    captureActive = false
    turnLocked = false
    lockWorkItem?.cancel()
    lockLimitWorkItem?.cancel()
    micIdleWorkItem?.cancel()
    pendingDuckItem?.cancel()
    correctionWatcher?.cancelPending()
    hotkeyManager?.stop()
    audioCapture.stopEngine()
    AudioDucker.shared.restore()
    sessionQueue.async { [self] in
      self.currentTurnId &+= 1
      self.turnSettled = true
      self.pendingRestRequest?.cancel()
      self.postProcessingStage.cancel()
      self.pendingFallbackTimer?.cancel()
      self.pendingTurnDeadline?.cancel()
      self.liveClient?.shutdown()
      self.history?.close()
    }
  }

  // Hold length that locks a turn, or nil when the feature is off. Toggle mode already
  // maps press/press to start/stop, so a lock would only swallow its own stop press.
  private var holdToLockInterval: TimeInterval? {
    guard config.holdToLockSec > 0, config.hotkeyMode != "toggle" else { return nil }
    return config.holdToLockSec
  }

  private func handleKeyDown() {
    guard !isStopping else { return }
    defer {
      if !captureActive && !capturePending { hotkeyManager?.resetToggle() }
    }
    // A press while locked is the finish gesture, standing in for the release that was
    // ignored. The physical key-up that follows finds captureActive false and is dropped.
    if turnLocked {
      turnLocked = false
      handleKeyUp(finish: "lock_press")
      return
    }

    processingLock.lock()
    // Protect re-entrancy / double-tap race
    guard !isProcessing else {
      processingLock.unlock()
      feedback.showBusy()
      return
    }
    processingLock.unlock()
    guard acceptsNewCaptures, !capturePending, !captureActive else { return }

    // Refuse to start a turn while secure input is held (password field, Terminal's Secure
    // Keyboard Entry, ...) - synthesized keystrokes and clipboard pastes into it can fail or
    // leak. Checked here, not just at paste time, so we never spin up the mic for a turn
    // that can only end in copy-only.
    if SecureInputMonitor.isActive {
      let holder = SecureInputMonitor.holderName()
      Log.warn(
        "SECURE",
        "Secure input is held by \(holder ?? "another app") - dictation blocked (password field?)")
      if config.soundFeedback {
        SoundManager.playErrorSound()
      }
      feedback.showError(message: "Secure input active  -  dictation blocked")
      return
    }

    // Offline fast-fail: say so in 0ms instead of recording a clip whose WS and REST
    // routes will both time out ~10s later.
    if !NetworkMonitor.shared.isOnline {
      Log.warn("NET", "No internet connection - dictation blocked.")
      if config.soundFeedback {
        SoundManager.playErrorSound()
      }
      feedback.showError(message: "No internet connection")
      return
    }

    // Frontmost app at key-down, compared again right before paste in handleTranscribedText.
    let front = NSWorkspace.shared.frontmostApplication
    turnFrontmostPID = front?.processIdentifier
    turnFrontmostName = front?.localizedName
    turnFrontmostBundleId = front?.bundleIdentifier
    turnInputDevice = audioCapture.currentInput?.name
    turnInputTransport = audioCapture.currentInput?.transport

    micIdleWorkItem?.cancel()
    micIdleWorkItem = nil

    capturePending = true
    captureGeneration &+= 1
    let generation = captureGeneration
    if !audioCapture.isEngineRunning { feedback.showStarting() }
    audioCapture.ensureReady { [weak self] ready in
      guard let self = self, self.capturePending, self.captureGeneration == generation else {
        return
      }
      self.capturePending = false
      guard ready else {
        self.hotkeyManager?.resetToggle()
        self.feedback.showError(message: "Microphone unavailable. Try again.")
        if self.config.soundFeedback { SoundManager.playErrorSound() }
        self.scheduleMicIdleRelease()
        return
      }
      self.beginCapture(generation: generation)
    }
  }

  private func beginCapture(generation: UInt64) {
    defer { if !captureActive { hotkeyManager?.resetToggle() } }
    guard !SecureInputMonitor.isActive, NetworkMonitor.shared.isOnline else {
      feedback.showError(message: "Dictation unavailable. Check input and connection.")
      scheduleMicIdleRelease()
      return
    }
    // A startup wait must not silently change the intended destination.
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == turnFrontmostPID else {
      feedback.showError(message: "Focus changed. Press again to dictate.")
      scheduleMicIdleRelease()
      return
    }
    correctionWatcher?.cancelPending()
    liveClient?.startNewTurn()
    guard audioCapture.startRecording() else {
      liveClient?.abandonTurn()
      feedback.showError(message: "Microphone unavailable. Try again.")
      scheduleMicIdleRelease()
      return
    }
    captureActive = true
    turnInputDevice = audioCapture.currentInput?.name
    turnInputTransport = audioCapture.currentInput?.transport
    if config.soundFeedback { SoundManager.playStartSound() }
    feedback.showListening(lockAfter: holdToLockInterval)
    feedback.captureStarted(pid: turnFrontmostPID, followFocus: config.hudFollowFocus)
    if config.restoreClipboard { TextInjector.prepareClipboard() }
    armHoldToLock()

    // Duck AFTER the begin earcon has played, not with it - Talkify's ordering. The
    // 350ms delay covers the cue; captureActive gates the item so it can't fire after
    // a short turn has already restored.
    if config.duckAudio {
      let duckItem = DispatchWorkItem { [weak self] in
        guard let self = self, self.captureActive else { return }
        self.pendingDuckItem = nil
        AudioDucker.shared.duck(toFraction: Float(self.config.duckFraction))
      }
      pendingDuckItem = duckItem
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: duckItem)
    }
  }

  private func handleKeyUp(finish: String = "release", eventTime: TimeInterval? = nil) {
    hotkeyManager?.resetToggle()
    // Capture the physical release instant before anything else - this becomes the true
    // start of "Total Key-Up -> Paste" latency measurement.
    let handlerTime = ProcessInfo.processInfo.systemUptime
    let keyUpTime = eventTime.flatMap { $0 > 0 && $0 <= handlerTime ? $0 : nil } ?? handlerTime

    if capturePending {
      capturePending = false
      captureGeneration &+= 1
      audioCapture.cancelPendingReadiness()
      feedback.hide()
      scheduleMicIdleRelease()
      return
    }

    // A release whose press never started a capture (refused by a key-down gate) must
    // not run the pipeline - there is nothing to stop, only stale state to misread.
    guard captureActive else { return }
    // Locked: letting go is the whole point. Nothing happens until the next press.
    if turnLocked { return }
    captureActive = false
    turnFinishMode = finish
    turnEventQueueMs = (handlerTime - keyUpTime) * 1000
    lockWorkItem?.cancel()
    lockWorkItem = nil
    lockLimitWorkItem?.cancel()
    lockLimitWorkItem = nil

    // Release acknowledged, before the settle race: on a slow REST fallback there are
    // otherwise seconds of silence between letting go and the commit earcon. While the
    // output is ducked the cue's own volume is boosted to compensate.
    if config.soundFeedback && config.releaseSound {
      let scale: Float =
        AudioDucker.shared.isDucked ? Float(1.0 / max(0.15, config.duckFraction)) : 1.0
      SoundManager.playReleaseSound(volumeScale: scale)
    }

    // The turn is busy from this instant, not from when the pipeline finishes draining:
    // stopRecording blocks sessionQueue for up to POST_ROLL_MAX_MS, and a re-press inside
    // that window must be refused by handleKeyDown's isProcessing guard, or it would
    // clear/reuse the very buffers being finalized. Every pipeline exit path clears this.
    processingLock.lock()
    isProcessing = true
    processingLock.unlock()

    // Flip the HUD to "processing" immediately on the main queue. The tap thread must not
    // block on stopRecording's post-roll sleep + queue drain, so the rest of the turn is
    // handed off to sessionQueue right away.
    DispatchQueue.main.async { [weak self] in
      self?.feedback.showProcessing()
    }

    sessionQueue.async { [weak self] in
      self?.runTurnPipeline(keyUpTime: keyUpTime)
    }
  }

  // Main thread. Scheduled at key-down; a normal release cancels it. Firing means the user
  // is still holding HOLD_TO_LOCK seconds in: lock the turn so they can let go.
  private func armHoldToLock() {
    lockWorkItem?.cancel()
    lockWorkItem = nil
    guard let lockAfter = holdToLockInterval else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self = self, self.captureActive, !self.turnLocked else { return }
      self.lockWorkItem = nil
      self.turnLocked = true
      Log.info(
        "LOCK",
        "Turn locked after \(String(format: "%g", lockAfter))s hold - release the key; press it again to finish."
      )
      if self.config.soundFeedback {
        let scale: Float =
          AudioDucker.shared.isDucked ? Float(1.0 / max(0.15, self.config.duckFraction)) : 1.0
        SoundManager.playLockSound(volumeScale: scale)
      }
      self.feedback.showLocked()
      self.scheduleLockLimit()
    }
    lockWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + lockAfter, execute: item)
  }

  // Main thread. A locked turn with nobody coming back to finish it is an open mic billing
  // audio tokens; LOCK_LIMIT finishes it the way the next press would have.
  private func scheduleLockLimit() {
    lockLimitWorkItem?.cancel()
    lockLimitWorkItem = nil
    guard config.lockLimitSec > 0 else { return }
    let item = DispatchWorkItem { [weak self] in
      guard let self = self, self.turnLocked else { return }
      self.lockLimitWorkItem = nil
      Log.warn(
        "LOCK",
        "Locked turn reached LOCK_LIMIT (\(String(format: "%g", self.config.lockLimitSec))s) - finishing it now."
      )
      self.turnLocked = false
      self.handleKeyUp(finish: "lock_limit")
    }
    lockLimitWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + config.lockLimitSec, execute: item)
  }

  /// Runs entirely on sessionQueue: finalizes the capture, arbitrates the WS-vs-REST turn
  /// lifecycle, and is the only place that mutates currentTurnId / turnSettled / pendingFallbackTimer.

  func runTurnPipeline(keyUpTime: CFAbsoluteTime) {
    guard !isStopping else { return }
    let pipelineStartTime = ProcessInfo.processInfo.systemUptime
    turnReleaseTime = keyUpTime
    let (pcmData, duration, chunks, capturedBytes, peakDb, speechFrames, interrupted) =
      audioCapture.stopRecording(
        gracePeriodMs: config.postRollMs, maxTrailMs: config.postRollMaxMs,
        silenceThresholdDb: config.trailSilenceDb)
    if !config.keepMicrophoneWarm {
      DispatchQueue.main.async { [weak self] in self?.audioCapture.suspendEngine() }
    }
    // Mic capture for this turn is over and every pipeline exit path passes this point -
    // one restore site instead of one per abandoned-turn/settle branch. The pending-duck
    // cancel hops to main (its owning thread); the item's captureActive guard covers the
    // window until the hop lands.
    if config.duckAudio {
      DispatchQueue.main.async { [weak self] in
        self?.pendingDuckItem?.cancel()
        self?.pendingDuckItem = nil
      }
      AudioDucker.shared.restore()
    }
    turnPeakDb = peakDb
    turnSpeechFrames = speechFrames
    turnSettlePath = nil
    turnCaptureFinalizeMs = (ProcessInfo.processInfo.systemUptime - pipelineStartTime) * 1000
    if interrupted {
      currentTurnId &+= 1
      turnSettled = false
      settle(
        turnId: currentTurnId, route: "microphone",
        outcome: .failure(
          NSError(
            domain: "JustSpeak.Microphone", code: 1,
            userInfo: [
              NSLocalizedDescriptionKey: "Microphone interrupted. Nothing pasted. Try again."
            ])))
      return
    }

    // Discard accidental micro-clicks (< 150ms or < 2KB of real captured audio, ignoring
    // the fixed pre-roll/silence-flush padding that stopRecording always appends).
    // isProcessing was set at key-up, so every abandoned-turn exit clears it.
    guard duration >= 0.15 && capturedBytes > 2000 else {
      liveClient?.abandonTurn()
      Log.warn(
        "INPUT",
        "Ignored short click (\(String(format: "%.0f", duration * 1000.0))ms). Hold key while speaking."
      )
      processingLock.lock()
      isProcessing = false
      processingLock.unlock()
      scheduleRejectedTurnUI { [weak self] in
        self?.feedback.hide()
        self?.scheduleMicIdleRelease()
      }
      return
    }

    // Silent-clip gate: judge the captured audio before spending an API call on it, so
    // room tone never leaves the machine. peakDb/speechFrames were accumulated inline
    // during capture (peak = dead-room test; speech-frame count = room tone whose peak is
    // spiked by the hotkey's own click) - nothing rescans the clip on this critical path.
    // Abandons the turn the same way the micro-click guard above does (isProcessing
    // cleared, the WS turn never committed). nil peak = no real audio = "not silent".
    if let peakDb = peakDb, peakDb < silentClipPeakDb || speechFrames <= silentClipMaxSpeechFrames {
      Log.warn(
        "INPUT",
        "No speech detected in clip (peak \(String(format: "%.1f", peakDb)) dBFS, \(speechFrames) speech frames) - skipping API call."
      )
      liveClient?.abandonTurn()
      noteNoSpeechTurn()
      recordTurn(
        TurnRecord(
          outcome: "empty",
          text: nil,
          charCount: 0,
          wordCount: 0,
          transport: nil,
          model: nil,
          isLiveRoute: nil,
          fallbackReason: nil,
          audioSeconds: duration,
          firstTokenMs: nil,
          roundtripMs: nil,
          captureFinalizeMs: nil,
          injectMs: nil,
          totalMs: nil,
          injected: nil,
          inputTokens: nil,
          outputTokens: nil,
          tokensMetered: nil,
          costUSD: nil,
          languageCodes: config.languageCodes.joined(separator: ","),
          smartMode: config.smartTranscription,
          vadMode: config.vadMode,
          error: nil,
          appBundleId: turnFrontmostBundleId,
          appName: turnFrontmostName,
          inputDevice: turnInputDevice,
          inputTransport: turnInputTransport,
          peakDb: peakDb,
          speechFrames: speechFrames,
          finishMode: turnFinishMode,
          eventQueueMs: turnEventQueueMs
        ))
      processingLock.lock()
      isProcessing = false
      processingLock.unlock()
      scheduleRejectedTurnUI { [weak self] in
        self?.feedback.showError(message: "No speech detected")
        self?.scheduleMicIdleRelease()
      }
      return
    }

    // isProcessing was already set at key-up (before the post-roll drain, so a re-press
    // during the drain can't start a capture over these buffers).
    currentTurnId += 1
    let turnId = currentTurnId
    turnSettled = false
    restAttemptStart = nil
    let budget = TurnDeadline.budget(fallbackTimeout: config.restFallbackTimeout)
    let deadline = DispatchWorkItem { [weak self] in
      self?.settle(
        turnId: turnId, route: "deadline",
        outcome: .failure(
          NSError(
            domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "Dictation deadline exceeded; nothing pasted."])))
    }
    pendingTurnDeadline = deadline
    sessionQueue.asyncAfter(
      deadline: .now()
        + TurnDeadline.remaining(
          budget: budget, elapsed: ProcessInfo.processInfo.systemUptime - keyUpTime),
      execute: deadline)

    Log.info(
      "AUDIO",
      "Captured \(String(format: "%.2fs", duration)) audio (\(chunks) chunks, \(String(format: "%.1f", Double(pcmData.count)/1024.0)) KB). Committing turn..."
    )

    let commitDispatchTime = ProcessInfo.processInfo.systemUptime
    let captureFinalizeMs = (commitDispatchTime - pipelineStartTime) * 1000.0

    // Strategy: Try Live WebSocket first; if not ready or on error, fallback seamlessly to REST
    if config.enableLiveWebSocket, let liveClient = self.liveClient, liveClient.canCommitTurn {
      let commitStartTime = commitDispatchTime
      let dynamicTimeout = max(0.1, config.restFallbackTimeout)

      let fallbackTimer = DispatchWorkItem { [weak self] in
        guard let self = self else { return }
        guard self.currentTurnId == turnId, !self.turnSettled else { return }
        self.pendingFallbackTimer = nil
        let reason = "WebSocket Settlement Timeout (> \(String(format: "%.1f", dynamicTimeout))s)"
        Log.warn("WS", "\(reason); executing REST fallback (hedge - WS may still land first)...")
        self.executeRestFallback(
          turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime,
          captureFinalizeMs: captureFinalizeMs, reason: reason)
      }
      pendingFallbackTimer = fallbackTimer
      sessionQueue.asyncAfter(deadline: .now() + dynamicTimeout, execute: fallbackTimer)

      liveClient.commitTurn { [weak self] result in
        guard let self = self else { return }
        self.sessionQueue.async {
          guard self.currentTurnId == turnId, !self.turnSettled else { return }
          switch result {
          case .success(let payload):
            let roundtripMs = (ProcessInfo.processInfo.systemUptime - commitStartTime) * 1000.0
            let usage = self.liveClient?.lastTurnUsage
            self.turnSettlePath = self.liveClient?.lastSettlePath
            self.settle(
              turnId: turnId, route: "WS",
              outcome: .success(
                text: payload.text,
                transport: "Live WebSocket (\(self.config.geminiLiveModel))",
                firstTokenMs: payload.firstTokenMs,
                roundtripMs: roundtripMs,
                audioDuration: duration,
                keyUpTime: keyUpTime,
                captureFinalizeMs: captureFinalizeMs,
                fallbackReason: nil,
                isLiveRoute: true,
                inputTokens: usage?.inputTokens,
                outputTokens: usage?.outputTokens
              ))

          case .failure(let error):
            guard self.currentTurnId == turnId, !self.turnSettled else { return }
            // If the hedge timer already fired, a REST call for this turn is in flight
            // (pendingFallbackTimer was nilled when it ran) - don't launch a duplicate.
            guard self.pendingFallbackTimer != nil else {
              Log.debug("SESSION", "WS failed for turn #\(turnId); hedge REST already in flight.")
              return
            }
            // "No speech recognized" (code -2) is not a transport failure: the live
            // STT model processed the whole clip (manual VAD) and heard nothing. When
            // the clip's own energy profile agrees, settle empty instead of handing
            // room tone to the REST model, which hallucinates text from silence.
            let nsError = error as NSError
            if nsError.domain == "JustSpeak", nsError.code == -2,
              speechFrames < self.wsNoSpeechTrustFrames
            {
              Log.warn(
                "WS",
                "No speech recognized (\(speechFrames) speech frames in clip); settling empty - REST fallback suppressed."
              )
              self.turnSettlePath = self.liveClient?.lastSettlePath
              self.settle(turnId: turnId, route: "WS", outcome: .empty(audioDuration: duration))
              return
            }
            // WS gave a definitive answer (an error); the hedge timer no longer needs
            // to fire a second, redundant REST call.
            self.pendingFallbackTimer?.cancel()
            self.pendingFallbackTimer = nil
            let reason = "WebSocket Disconnected / Error (\(error.localizedDescription))"
            Log.warn("WS", "\(reason). Falling back to REST...")
            self.executeRestFallback(
              turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime,
              captureFinalizeMs: captureFinalizeMs, reason: reason)
          }
        }
      }
    } else {
      // Direct REST
      let reason =
        !config.enableLiveWebSocket
        ? "Live WebSockets Disabled in EngineConfiguration"
        : "Live connection not ready or recording incomplete"
      executeRestFallback(
        turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime,
        captureFinalizeMs: captureFinalizeMs, reason: reason)
    }
  }

  /// Result of a settled turn, handed to settle(). Success carries every field the latency
  /// diagnostic printout needs; failure is the REST-fallback-failed error path.

  // Session-wide usage accumulators, printed on Ctrl+C exit. Guarded by statsLock: written
  // on sessionQueue per turn, read from the main-queue signal handler.
  private let statsLock = NSLock()
  private var sessionTurns = 0
  private var sessionInputTokens = 0
  private var sessionOutputTokens = 0
  private var sessionCostUSD = 0.0
  private var sessionUnknownUsageTurns = 0
  private var sessionUnpricedCleanupCount = 0

  func printSessionUsageSummary() {
    statsLock.lock()
    let turns = sessionTurns
    let inTok = sessionInputTokens
    let outTok = sessionOutputTokens
    let cost = sessionCostUSD
    let unknownUsage = sessionUnknownUsageTurns
    let unpricedCleanup = sessionUnpricedCleanupCount
    statsLock.unlock()
    guard turns > 0 else { return }
    Log.info(
      "USAGE",
      "turns=\(turns) reported_input_tokens=\(inTok) reported_output_tokens=\(outTok) unknown_usage_turns=\(unknownUsage) estimated_known_cost_usd=\(String(format: "%.6f", cost)) unpriced_cleanup_count=\(unpricedCleanup)"
    )
  }

  /// Launches the REST fallback for turnId. Does NOT settle the turn by itself - WS and REST
  /// race, and whichever result reaches settle() first for a still-live turnId wins.
  ///
  /// isRetry marks the one allowed re-send after an empty transcript (model nondeterminism,
  /// not silence - the silent-clip gate already filtered room tone before any call was made).
  private func executeRestFallback(
    turnId: UInt64, pcmData: Data, duration: Double, keyUpTime: CFAbsoluteTime,
    captureFinalizeMs: Double, reason: String, isRetry: Bool = false
  ) {
    guard currentTurnId == turnId, !turnSettled else { return }
    if restAttemptStart == nil { restAttemptStart = ProcessInfo.processInfo.systemUptime }
    let restStartTime = restAttemptStart!
    pendingRestRequest = GeminiRestClient.transcribe(
      pcmData: pcmData,
      apiKey: config.geminiApiKey,
      model: config.geminiModel,
      languageCodes: config.languageCodes,
      customVocabulary: config.customVocabulary
    ) { [weak self] result in
      guard let self = self else { return }
      self.sessionQueue.async {
        switch result {
        case .success(let payload):
          let trimmedText = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
          if trimmedText.isEmpty, duration >= 0.6, !isRetry {
            // Re-check turn liveness before spending a second call - a turn that
            // already settled (or was superseded) must not fire a redundant re-send.
            guard self.currentTurnId == turnId, !self.turnSettled else { return }
            Log.warn(
              "REST",
              "Empty transcript for \(String(format: "%.1f", duration))s of audio - re-sending once (model nondeterminism)."
            )
            self.executeRestFallback(
              turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime,
              captureFinalizeMs: captureFinalizeMs, reason: reason, isRetry: true)
            return
          }
          let roundtripMs = (ProcessInfo.processInfo.systemUptime - restStartTime) * 1000.0
          self.settle(
            turnId: turnId, route: "REST",
            outcome: .success(
              text: payload.text,
              transport: "REST API (\(self.config.geminiModel))",
              firstTokenMs: 0,
              roundtripMs: roundtripMs,
              audioDuration: duration,
              keyUpTime: keyUpTime,
              captureFinalizeMs: captureFinalizeMs,
              fallbackReason: reason,
              isLiveRoute: false,
              inputTokens: payload.inputTokens,
              outputTokens: payload.outputTokens
            ))

        case .failure(let error):
          self.settle(turnId: turnId, route: "REST", outcome: .failure(error))
        }
      }
    }
  }

  /// sessionQueue-only. Tracks consecutive no-speech turns; three in a row with the mic
  /// permission missing is a revoked-permission signature, not a quiet room.
  private func noteNoSpeechTurn() {
    consecutiveNoSpeechTurns += 1
    guard consecutiveNoSpeechTurns == 3 else { return }
    if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
      Log.error(
        "MIC",
        "Microphone access is unavailable. Enable Tok in System Settings > Privacy & Security > Microphone."
      )
      DispatchQueue.main.async { [weak self] in
        self?.feedback.showError(message: "Microphone access lost  -  check System Settings")
      }
    } else {
      Log.warn(
        "MIC",
        "3 consecutive no-speech turns - if you were speaking, check the selected input device (System Settings > Sound > Input)."
      )
    }
  }

  /// Short, human error text for the HUD; falls back to nil for errors with no better
  /// wording than their own description.
  private static func friendlyFailureMessage(_ error: Error) -> String? {
    let ns = error as NSError
    if ns.domain == NSURLErrorDomain {
      switch ns.code {
      case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
        NSURLErrorDataNotAllowed:
        return "No internet connection  -  nothing pasted"
      case NSURLErrorTimedOut:
        return "Network timeout  -  nothing pasted"
      case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
        return "Can't reach Gemini  -  nothing pasted"
      case NSURLErrorSecureConnectionFailed:
        return "Secure connection failed  -  nothing pasted"
      default:
        return nil
      }
    }
    if ns.domain == "GeminiAPI" {
      // RESTResponse constructs these descriptions without remote response text.
      return ns.localizedDescription
    }
    return nil
  }

  /// The sole place a live turn's result reaches handleTranscribedText or the error path.
  /// Runs only on sessionQueue. A result for a turnId that isn't current, or one that arrives
  /// after the turn already settled, is a loser of the WS/REST hedge race and is dropped.
  func settle(turnId: UInt64, route: String, outcome: TurnOutcome) {
    guard !isStopping else { return }
    guard turnId == currentTurnId, !turnSettled else {
      Log.debug("SESSION", "Stale result for turn #\(turnId) ignored (\(route))")
      return
    }
    turnSettled = true
    pendingTurnDeadline?.cancel()
    pendingTurnDeadline = nil
    pendingRestRequest?.cancel()
    pendingRestRequest = nil
    if route != "WS" { liveClient?.abandonTurn() }
    pendingFallbackTimer?.cancel()
    pendingFallbackTimer = nil

    switch outcome {
    case .success(
      let text, let transport, let firstTokenMs, let roundtripMs, let audioDuration, let keyUpTime,
      let captureFinalizeMs, let fallbackReason, let isLiveRoute, let inputTokens, let outputTokens):
      consecutiveNoSpeechTurns = 0
      postProcessingStage.process(
        text: text, configuration: config, appName: turnFrontmostName,
        appBundleId: turnFrontmostBundleId
      ) { [weak self] processed in
        guard let self, !self.isStopping, turnId == self.currentTurnId else { return }
        self.handleTranscribedText(
          processed.text, transport: transport, firstTokenMs: firstTokenMs,
          roundtripMs: roundtripMs, audioDuration: audioDuration, totalStartTime: keyUpTime,
          captureFinalizeMs: captureFinalizeMs, fallbackReason: fallbackReason,
          isLiveRoute: isLiveRoute, inputTokens: inputTokens, outputTokens: outputTokens,
          postProcessing: processed.metrics)
      }
      return

    case .empty(let audioDuration):
      noteNoSpeechTurn()
      DispatchQueue.main.async { [weak self] in
        self?.feedback.showError(message: "No speech detected")
      }
      recordTurn(
        TurnRecord(
          outcome: "empty",
          text: nil,
          charCount: 0,
          wordCount: 0,
          transport: route,
          model: nil,
          isLiveRoute: nil,
          fallbackReason: nil,
          audioSeconds: audioDuration,
          firstTokenMs: nil,
          roundtripMs: nil,
          captureFinalizeMs: turnCaptureFinalizeMs,
          injectMs: nil,
          totalMs: (ProcessInfo.processInfo.systemUptime - turnReleaseTime) * 1000,
          injected: nil,
          inputTokens: nil,
          outputTokens: nil,
          tokensMetered: nil,
          costUSD: nil,
          languageCodes: config.languageCodes.joined(separator: ","),
          smartMode: config.smartTranscription,
          vadMode: config.vadMode,
          error: nil,
          appBundleId: turnFrontmostBundleId,
          appName: turnFrontmostName,
          inputDevice: turnInputDevice,
          inputTransport: turnInputTransport,
          peakDb: turnPeakDb,
          speechFrames: turnSpeechFrames,
          settlePath: turnSettlePath,
          finishMode: turnFinishMode,
          eventQueueMs: turnEventQueueMs
        ))
      processingLock.lock()
      isProcessing = false
      processingLock.unlock()

    case .failure(let error):
      Log.error(
        route == "microphone" ? "MIC" : "TRANSCRIBE", "Turn failed: \(error.localizedDescription)")
      if config.soundFeedback { SoundManager.playErrorSound() }
      let hudMessage =
        (error as NSError).domain == "JustSpeak.Microphone"
        ? "Microphone interrupted. Try again."
        : Self.friendlyFailureMessage(error) ?? "Transcription failed  -  nothing pasted"
      DispatchQueue.main.async { [weak self] in
        self?.feedback.showError(message: hudMessage)
      }
      recordTurn(
        TurnRecord(
          outcome: "error",
          text: nil,
          charCount: 0,
          wordCount: 0,
          transport: route,
          model: nil,
          isLiveRoute: nil,
          fallbackReason: nil,
          audioSeconds: nil,
          firstTokenMs: nil,
          roundtripMs: nil,
          captureFinalizeMs: turnCaptureFinalizeMs,
          injectMs: nil,
          totalMs: (ProcessInfo.processInfo.systemUptime - turnReleaseTime) * 1000,
          injected: nil,
          inputTokens: nil,
          outputTokens: nil,
          tokensMetered: nil,
          costUSD: nil,
          languageCodes: config.languageCodes.joined(separator: ","),
          smartMode: config.smartTranscription,
          vadMode: config.vadMode,
          error: error.localizedDescription,
          appBundleId: turnFrontmostBundleId,
          appName: turnFrontmostName,
          inputDevice: turnInputDevice,
          inputTransport: turnInputTransport,
          peakDb: turnPeakDb,
          speechFrames: turnSpeechFrames,
          settlePath: turnSettlePath,
          finishMode: turnFinishMode,
          eventQueueMs: turnEventQueueMs
        ))
      processingLock.lock()
      isProcessing = false
      processingLock.unlock()
    }

    // Turn finished either way: start the mic idle countdown.
    DispatchQueue.main.async { [weak self] in
      self?.scheduleMicIdleRelease()
    }
  }

  /// Runs on sessionQueue (called only from settle). isProcessing is cleared here at the end,
  /// which is now a sessionQueue-only write.
  private func handleTranscribedText(
    _ rawText: String,
    transport: String,
    firstTokenMs: Double,
    roundtripMs: Double,
    audioDuration: Double,
    totalStartTime: CFAbsoluteTime,
    captureFinalizeMs: Double,
    fallbackReason: String? = nil,
    isLiveRoute: Bool = true,
    inputTokens: Int? = nil,
    outputTokens: Int? = nil,
    clipboardPrepared: Bool = false,
    postProcessing: PostProcessingMetrics = .off
  ) {
    guard !isStopping else { return }
    var canPrepareClipboard = false
    if config.restoreClipboard, !clipboardPrepared, !SecureInputMonitor.isActive,
      AXIsProcessTrusted()
    {
      DispatchQueue.main.sync {
        canPrepareClipboard =
          NSWorkspace.shared.frontmostApplication?.processIdentifier == turnFrontmostPID
      }
    }
    if canPrepareClipboard {
      TextInjector.awaitPreparedClipboard { [weak self] _ in
        guard let self = self else { return }
        self.sessionQueue.async {
          self.handleTranscribedText(
            rawText, transport: transport,
            firstTokenMs: firstTokenMs, roundtripMs: roundtripMs,
            audioDuration: audioDuration, totalStartTime: totalStartTime,
            captureFinalizeMs: captureFinalizeMs, fallbackReason: fallbackReason,
            isLiveRoute: isLiveRoute, inputTokens: inputTokens, outputTokens: outputTokens,
            clipboardPrepared: true, postProcessing: postProcessing)
        }
      }
      return
    }
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      Log.warn("AI", "Received empty transcription from Gemini.")
      DispatchQueue.main.async { [weak self] in
        self?.feedback.showError(message: "No speech detected")
      }
      recordTurn(
        TurnRecord(
          outcome: "empty",
          text: nil,
          charCount: 0,
          wordCount: 0,
          transport: transport,
          model: isLiveRoute ? config.geminiLiveModel : config.geminiModel,
          isLiveRoute: isLiveRoute,
          fallbackReason: fallbackReason,
          audioSeconds: audioDuration,
          firstTokenMs: firstTokenMs > 0 ? firstTokenMs : nil,
          roundtripMs: roundtripMs,
          captureFinalizeMs: captureFinalizeMs,
          injectMs: nil,
          totalMs: nil,
          injected: nil,
          inputTokens: nil,
          outputTokens: nil,
          tokensMetered: nil,
          costUSD: nil,
          languageCodes: config.languageCodes.joined(separator: ","),
          smartMode: config.smartTranscription,
          vadMode: config.vadMode,
          error: nil,
          appBundleId: turnFrontmostBundleId,
          appName: turnFrontmostName,
          inputDevice: turnInputDevice,
          inputTransport: turnInputTransport,
          peakDb: turnPeakDb,
          speechFrames: turnSpeechFrames,
          settlePath: turnSettlePath,
          finishMode: turnFinishMode,
          eventQueueMs: turnEventQueueMs
        ))
      processingLock.lock()
      isProcessing = false
      processingLock.unlock()
      DispatchQueue.main.async { [weak self] in self?.scheduleMicIdleRelease() }
      return
    }

    // Deterministic wrong->right enforcement (client-side guarantee on top of boost bias).
    let text: String
    var replacementRejected = false
    do {
      text = try ReplacementEngine.apply(trimmed, compiled: config.compiledReplacementRules)
    } catch {
      text = trimmed
      replacementRejected = true
    }

    // Active Window Injection: paste, unless secure input is held or the frontmost app
    // changed mid-turn - both downgrade to clipboard-only delivery instead of synthesizing
    // a paste into the wrong (or a password) field. Auto-restores the previous clipboard
    // after ~1s on the normal paste path.
    let injected: Bool
    let injectMs: Double
    var deliveryError: String?
    // set on downgrade; drives the log message, HUD text and status label
    var copyOnlyReason: String?

    if replacementRejected {
      injected = false
      injectMs = 0
      deliveryError =
        config.historyEnabled
        ? "Vocabulary replacements exceeded safe limits. Original text saved in History."
        : "Vocabulary replacements exceeded safe limits. Nothing pasted. Review Vocabulary."
      Log.warn("VOCAB", "Replacement budget exceeded; no text was pasted.")
    } else if SecureInputMonitor.isActive {
      let copyStart = ProcessInfo.processInfo.systemUptime
      if !TextInjector.copyOnly(text: text, appendSpace: config.trailingSpace) {
        deliveryError = "Clipboard write failed. Text not copied."
      }
      injectMs = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000.0
      injected = false
      let holder = SecureInputMonitor.holderName()
      Log.warn("INJECT", "Secure input is held by \(holder ?? "another app") - copied, not pasted.")
      copyOnlyReason = "secure input"
    } else if !AXIsProcessTrusted() {
      // Accessibility revoked while running: the synthesized Cmd+V would be silently
      // dropped by the system, losing the dictation. Copy instead and say why.
      let copyStart = ProcessInfo.processInfo.systemUptime
      if !TextInjector.copyOnly(text: text, appendSpace: config.trailingSpace) {
        deliveryError = "Clipboard write failed. Text not copied."
      }
      injectMs = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000.0
      injected = false
      Log.warn(
        "INJECT",
        "Accessibility access is unavailable. Text was copied. Enable Tok in System Settings > Privacy & Security > Accessibility."
      )
      copyOnlyReason = "accessibility revoked"
    } else {
      var frontNow: NSRunningApplication?
      DispatchQueue.main.sync { frontNow = NSWorkspace.shared.frontmostApplication }

      if let priorPid = turnFrontmostPID, let nowPid = frontNow?.processIdentifier,
        priorPid != nowPid
      {
        let copyStart = ProcessInfo.processInfo.systemUptime
        if !TextInjector.copyOnly(text: text, appendSpace: config.trailingSpace) {
          deliveryError = "Clipboard write failed. Text not copied."
        }
        injectMs = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000.0
        injected = false
        Log.warn(
          "INJECT",
          "Focus moved from \(turnFrontmostName ?? "?") to \(frontNow?.localizedName ?? "?") mid-turn - text copied, not pasted."
        )
        copyOnlyReason = "focus changed"
      } else {
        let result = TextInjector.inject(
          text: text, restorePreviousClipboard: config.restoreClipboard,
          completionSound: config.soundFeedback, appendSpace: config.trailingSpace,
          shouldDispatch: {
            guard !self.isStopping, !SecureInputMonitor.isActive, AXIsProcessTrusted() else {
              return false
            }
            var sameTarget = false
            DispatchQueue.main.sync {
              sameTarget =
                NSWorkspace.shared.frontmostApplication?.processIdentifier == self.turnFrontmostPID
            }
            return sameTarget
          })
        injected = result.outcome == .dispatched
        injectMs = result.latencyMs
        switch result.outcome {
        case .dispatched: break
        case .clipboardUnavailable:
          deliveryError =
            config.historyEnabled
            ? "Clipboard busy. Text saved in history." : "Clipboard busy. Text not pasted."
        case .dispatchCancelled: deliveryError = "Destination changed. Text not pasted."
        case .failed: deliveryError = "Paste failed. Text not pasted."
        }
        // Arm the typed-correction read-back only on a real paste into a verified
        // frontmost app; copy-only downgrades never observe anything.
        if injected, config.learnCorrections,
          let pid = frontNow?.processIdentifier ?? turnFrontmostPID
        {
          let appName = frontNow?.localizedName ?? turnFrontmostName ?? ""
          DispatchQueue.main.async { [weak self] in
            self?.correctionWatcher?.arm(pastedText: text, targetPid: pid, appName: appName)
          }
        }
      }
    }

    if copyOnlyReason != nil, deliveryError == nil, config.soundFeedback {
      // Text still landed - on the clipboard - so this is a commit, not an error sound.
      SoundManager.playCommitSound()
    }

    let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStartTime) * 1000.0

    let feedbackGeneration = captureGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.captureGeneration == feedbackGeneration else { return }
      if let message = deliveryError {
        self.feedback.showError(message: message)
      } else if let reason = copyOnlyReason {
        let message: String
        switch reason {
        case "secure input":
          message = "Secure input active  -  copied, press ⌘V after leaving the password field"
        case "accessibility revoked": message = "Accessibility revoked  -  copied, press ⌘V"
        default: message = "Focus changed  -  copied, press ⌘V"
        }
        self.feedback.showError(message: message)
      } else {
        self.feedback.showSuccess(text: text)
      }
    }

    // Token usage & cost. API-metered when the server reported usageMetadata; otherwise a
    // deterministic estimate from the documented rates (25 audio tokens/sec + ~1s of
    // pre/post-roll & silence padding also billed; output ~4 chars/token).
    let usageMetered = (inputTokens != nil || outputTokens != nil)
    let effectiveInputTokens = inputTokens ?? Int((audioDuration + 1.0) * 25.0)
    let effectiveOutputTokens = outputTokens ?? max(1, text.count / 4)
    let inputPrice = isLiveRoute ? config.liveInputPricePer1M : config.restInputPricePer1M
    let outputPrice = isLiveRoute ? config.liveOutputPricePer1M : config.restOutputPricePer1M
    let turnCostUSD =
      Double(effectiveInputTokens) / 1_000_000.0 * inputPrice
      + Double(effectiveOutputTokens) / 1_000_000.0 * outputPrice
    statsLock.lock()
    sessionTurns += 1
    sessionInputTokens += (inputTokens ?? 0) + (postProcessing.inputTokens ?? 0)
    sessionOutputTokens +=
      (outputTokens ?? 0) + (postProcessing.outputTokens ?? 0)
      + (postProcessing.thinkingTokens ?? 0)
    let cleanupAttempted =
      !["off", "skipped"].contains(postProcessing.status)
      && postProcessing.errorCode != "invalid_configuration"
    if inputTokens == nil || outputTokens == nil
      || (cleanupAttempted
        && (postProcessing.inputTokens == nil || postProcessing.outputTokens == nil))
    {
      sessionUnknownUsageTurns += 1
    }
    if cleanupAttempted && postProcessing.costUSD == nil { sessionUnpricedCleanupCount += 1 }
    sessionCostUSD += turnCostUSD + (postProcessing.costUSD ?? 0)
    statsLock.unlock()

    var record = TurnRecord(
      outcome: deliveryError == nil ? "success" : "delivery_failed",
      text: text,
      charCount: text.count,
      wordCount: text.split { $0.isWhitespace }.count,
      transport: transport,
      model: isLiveRoute ? config.geminiLiveModel : config.geminiModel,
      isLiveRoute: isLiveRoute,
      fallbackReason: fallbackReason,
      audioSeconds: audioDuration,
      firstTokenMs: firstTokenMs > 0 ? firstTokenMs : nil,
      roundtripMs: roundtripMs,
      captureFinalizeMs: captureFinalizeMs,
      injectMs: injectMs,
      totalMs: totalElapsedMs,
      injected: injected,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      tokensMetered: usageMetered,
      costUSD: postProcessing.costUSD.map { turnCostUSD + $0 },
      languageCodes: config.languageCodes.joined(separator: ","),
      smartMode: config.smartTranscription,
      vadMode: config.vadMode,
      error: deliveryError,
      appBundleId: turnFrontmostBundleId,
      appName: turnFrontmostName,
      inputDevice: turnInputDevice,
      inputTransport: turnInputTransport,
      peakDb: turnPeakDb,
      speechFrames: turnSpeechFrames,
      settlePath: turnSettlePath,
      finishMode: turnFinishMode,
      eventQueueMs: turnEventQueueMs,
      deliveryOutcome: injected ? "dispatched" : (deliveryError == nil ? "copied" : "failed")
    )

    record.postProcessing = postProcessing
    record.transcriptionCostUSD = turnCostUSD
    if postProcessing.status != "off" {
      let message =
        "status=\(postProcessing.status) code=\(postProcessing.errorCode ?? "none") original_used=\(postProcessing.status != "completed")"
      if postProcessing.status == "completed" {
        Log.debug("CLEANUP", message)
      } else {
        Log.warn("CLEANUP", message)
      }
    }
    processingLock.lock()
    isProcessing = false
    processingLock.unlock()
    let readyMs = (ProcessInfo.processInfo.systemUptime - totalStartTime) * 1000
    record.readyMs = readyMs
    recordTurn(record)
    Log.debug("LATENCY", "Key-up to next-turn readiness: \(String(format: "%.1f", readyMs))ms")
    DispatchQueue.main.async { [weak self] in self?.scheduleMicIdleRelease() }
  }

}
