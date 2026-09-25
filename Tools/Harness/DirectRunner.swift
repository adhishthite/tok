import Foundation

// The Live client is internal to TokEngine. This Debug-only tool reaches it the same way
// LiveIntegrationTests does, instead of widening the engine's public API for measurement.
@testable import TokEngine

/// Streams clip audio straight into GeminiLiveClient, bypassing speakers and microphone,
/// so many turns run at once. Measures what happens after capture: the end signal,
/// commit-to-result round trip, and transcript accuracy by accent and language. It says
/// nothing about capture start or the capture tail; the acoustic runner covers those.
///
/// Each worker holds one persistent socket per arm, as the app holds one, and runs every
/// clip on every arm back to back in a rotating order, so network contention falls on
/// all arms alike. Audio is paced in real time, chunk by chunk, like the capture engine.
final class DirectRunner {
  private let options: HarnessOptions
  private let clips: [HarnessClip]
  private let arms: [HarnessArm]
  private let configurations: [String: EngineConfiguration]
  private let clipDirectory: URL
  let runId: String
  private let rows: FileHandle
  private let lock = NSLock()
  private var queue: [(index: Int, clip: HarnessClip, repeatIndex: Int)] = []
  private var written = 0
  private var stopRequested = false

  private static let readyTimeout: TimeInterval = 20
  private static let resultTimeout: TimeInterval = 20
  /// After the last word the capture engine keeps recording until the room is quiet;
  /// real turns finish that in about 60 to 90 ms (capture_finalize_ms in history.db).
  private static let postRollMs = 80.0

  init(
    options: HarnessOptions, clips: [HarnessClip], owner: [String: String], apiKey: String,
    vocabulary: String?, buildId: String
  ) throws {
    self.options = options
    self.clips = clips
    self.arms = options.arms.compactMap(HarnessArm.named)
    var configurations: [String: EngineConfiguration] = [:]
    for arm in arms {
      configurations[arm.name] = HarnessSettings.configuration(
        arm: arm, owner: owner, apiKey: apiKey, historyPath: "", buildId: buildId,
        vocabulary: vocabulary)
    }
    self.configurations = configurations
    clipDirectory = options.root.appendingPathComponent("build/harness/clips")
    let runs = options.root.appendingPathComponent("build/harness/runs")
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    runId = "direct-" + formatter.string(from: Date())
    let rowsURL = runs.appendingPathComponent("\(runId).jsonl")
    FileManager.default.createFile(atPath: rowsURL.path, contents: nil)
    rows = try FileHandle(forWritingTo: rowsURL)
    var rng = SeededGenerator(seed: options.seed)
    var items: [(index: Int, clip: HarnessClip, repeatIndex: Int)] = []
    for repeatIndex in 0..<options.repeats {
      for clip in clips.shuffled(using: &rng) {
        items.append((items.count, clip, repeatIndex))
      }
    }
    queue = items.reversed()
  }

  func requestStop() {
    lock.lock()
    stopRequested = true
    lock.unlock()
  }

  private func next() -> (index: Int, clip: HarnessClip, repeatIndex: Int)? {
    lock.lock()
    defer { lock.unlock() }
    return stopRequested ? nil : queue.popLast()
  }

  func run() -> Int32 {
    let total = queue.count
    print(
      "run \(runId): \(total) clips x \(arms.count) arms (\(arms.map(\.name).joined(separator: ", "))), \(options.workers) workers"
    )
    fflush(stdout)
    let group = DispatchGroup()
    for worker in 0..<options.workers {
      group.enter()
      Thread.detachNewThread { [self] in
        work(worker: worker, total: total)
        group.leave()
      }
    }
    group.wait()
    try? rows.close()
    print("finished: \(written) turns")
    return 0
  }

  // MARK: - Worker

  private func work(worker: Int, total: Int) {
    var clients: [String: GeminiLiveClient] = [:]
    for arm in arms {
      guard let config = configurations[arm.name] else { continue }
      let client = GeminiLiveClient(
        apiKey: config.geminiApiKey, model: config.geminiLiveModel,
        smartTranscription: config.smartTranscription, languageCodes: config.languageCodes,
        customVocabulary: config.recognitionVocabulary, vadMode: config.vadMode,
        vadSilenceMs: config.vadSilenceMs, endpointAligned: config.wsEndpointAligned)
      client.connect(reason: "startup")
      clients[arm.name] = client
    }
    defer { for client in clients.values { client.shutdown() } }
    var rng = SeededGenerator(seed: options.seed &+ UInt64(worker) &* 7919)
    while let item = next() {
      guard let speech = try? DirectAudio.speech(url: url(for: item.clip)) else {
        report("[\(item.clip.clipId)] cannot read clip audio")
        continue
      }
      let lead = Double.random(in: 150...450, using: &rng)
      let offset = item.index % arms.count
      for arm in Array(arms[offset...] + arms[..<offset]) {
        guard let client = clients[arm.name], let config = configurations[arm.name] else {
          continue
        }
        var turnRng = SeededGenerator(seed: UInt64(item.index) &* 104_729 &+ 17)
        let row = turn(
          client: client, config: config, arm: arm, item: item, speech: speech, leadMs: lead,
          rng: &turnRng)
        write(row, total: total)
      }
    }
  }

  private func url(for clip: HarnessClip) -> URL {
    clipDirectory.appendingPathComponent("\(clip.clipId).wav")
  }

  private func turn(
    client: GeminiLiveClient, config: EngineConfiguration, arm: HarnessArm,
    item: (index: Int, clip: HarnessClip, repeatIndex: Int), speech: [Float], leadMs: Double,
    rng: inout SeededGenerator
  ) -> HarnessTurnRow {
    let clip = item.clip
    var row = HarnessTurnRow(
      runId: runId, startedAt: ISO8601DateFormatter().string(from: Date()), round: item.index,
      arm: arm.name, turnIndex: item.index, turnInBlock: item.repeatIndex, clipId: clip.clipId,
      phraseId: clip.phraseId, ttsModel: clip.ttsModel, voice: clip.voice, accent: clip.accent,
      style: clip.style, language: clip.language ?? "en", codeSwitch: clip.codeSwitch,
      clipSpeechS: clip.speechOffsetS - clip.speechOnsetS, plannedGapS: 0, actualGapS: 0,
      leadMs: leadMs, tailMs: Self.postRollMs, captureStarted: true, failures: [],
      keepMicWarm: config.keepMicrophoneWarm, micIdleTimeoutS: config.micIdleTimeoutSec,
      endpointAligned: config.wsEndpointAligned, silenceFlushMs: config.silenceFlushMs,
      ambientDb: DirectAudio.noiseDbfs, reference: clip.text)
    row.mode = "direct"

    let readyBy = ProcessInfo.processInfo.systemUptime + Self.readyTimeout
    if !client.isReady { client.connect(onlyWhenIdle: true, reason: "reconnect") }
    while !client.isReady, ProcessInfo.processInfo.systemUptime < readyBy {
      Thread.sleep(forTimeInterval: 0.05)
    }
    guard client.isReady else {
      row.outcome = "not_ready"
      return row
    }
    row.socketStateAtKeydown = "ready"

    // Pre-roll arrives at once, as the capture engine's ring buffer does; the rest is
    // paced in real time: lead-in, speech over room tone, then the post-roll.
    var speechWithTone = speech
    DirectAudio.addNoise(to: &speechWithTone, using: &rng)
    let preRoll = DirectAudio.noise(milliseconds: Double(config.preRollMs), using: &rng)
    let paced =
      DirectAudio.noise(milliseconds: leadMs, using: &rng) + speechWithTone
      + DirectAudio.noise(milliseconds: Self.postRollMs, using: &rng)
    client.startNewTurn()
    client.sendAudioChunk(DirectAudio.pcm16(preRoll))
    let chunk = max(1, Int(Double(config.chunkMs) * DirectAudio.sampleRate / 1000))
    let started = ProcessInfo.processInfo.systemUptime
    var position = 0
    while position < paced.count {
      let end = min(paced.count, position + chunk)
      let due = Double(end) / DirectAudio.sampleRate
      let wait = due - (ProcessInfo.processInfo.systemUptime - started)
      if wait > 0 { Thread.sleep(forTimeInterval: wait) }
      client.sendAudioChunk(DirectAudio.pcm16(Array(paced[position..<end])))
      position = end
    }
    // The synthetic silence flush is digital zeros, as AudioCaptureEngine appends.
    // With a zero flush the capture engine appends nothing, so nothing is sent.
    if config.silenceFlushMs > 0 { client.sendAudioChunk(Data(count: config.silenceFlushMs * 32)) }
    guard client.canCommitTurn else {
      client.abandonTurn()
      row.outcome = "not_committable"
      return row
    }

    let done = DispatchSemaphore(value: 0)
    let resultLock = NSLock()
    var result: Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>?
    let commitAt = ProcessInfo.processInfo.systemUptime
    var settledAt = commitAt
    client.commitTurn { outcome in
      resultLock.lock()
      result = outcome
      settledAt = ProcessInfo.processInfo.systemUptime
      resultLock.unlock()
      done.signal()
    }
    guard done.wait(timeout: .now() + Self.resultTimeout) == .success else {
      client.abandonTurn()
      row.outcome = "timeout"
      return row
    }
    resultLock.lock()
    let outcome = result
    let roundtrip = (settledAt - commitAt) * 1000
    resultLock.unlock()
    row.settlePath = client.lastSettlePath
    let split = client.lastRoundTrip
    row.commitToFinalMs = split.finalMs
    row.commitToTurnCompleteMs = split.turnCompleteMs
    switch outcome {
    case .success(let payload):
      let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
      row.outcome = text.isEmpty ? "empty" : "success"
      row.roundtripMs = roundtrip
      row.hypothesis = text
      row.accuracy = WordAccuracy(reference: clip.text, hypothesis: text)
    case .failure(let error):
      row.outcome = "error"
      row.roundtripMs = roundtrip
      row.hypothesis = nil
      row.failures = [(error as NSError).localizedDescription]
    case nil:
      row.outcome = "timeout"
    }
    return row
  }

  // MARK: - Output

  private func write(_ row: HarnessTurnRow, total: Int) {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(row) else { return }
    lock.lock()
    rows.write(data + Data("\n".utf8))
    written += 1
    let count = written
    lock.unlock()
    if count % 25 == 0 || count == total * arms.count {
      report("\(count)/\(total * arms.count) turns")
    }
    if row.outcome != "success" {
      report(
        "[\(row.arm)] \(row.clipId) \(row.outcome ?? "-") \(row.failures.joined(separator: "; "))")
    }
  }

  private func report(_ line: String) {
    lock.lock()
    print(line)
    fflush(stdout)
    lock.unlock()
  }
}
