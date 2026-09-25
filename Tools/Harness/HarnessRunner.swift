import Foundation
import TokEngine

/// Drives real engine turns from a background thread. Each round draws a block of clips
/// and timings, then runs that same block once per arm, in an order that rotates each
/// round, so every arm hears the same audio at the same gaps. An arm block is one engine
/// instance, because the compared settings are fixed at engine init.
final class HarnessRunner {
  private let options: HarnessOptions
  private let clips: [HarnessClip]
  private let arms: [HarnessArm]
  private let owner: [String: String]
  private let apiKey: String
  private let vocabulary: String?
  private let buildId: String
  private let clipDirectory: URL
  private let historyPath: String
  let runId: String
  private let rows: FileHandle
  private let log: FileHandle
  private let logLock = NSLock()
  private let stopLock = NSLock()
  private var stopRequested = false
  private var rng: SeededGenerator
  private var deck: [HarnessClip] = []
  private var turnIndex = 0
  private let player: ClipPlayer
  private var ambientDb: Double?

  /// Consecutive turns with no usable result before the run stops: the microphone is
  /// probably not hearing the speakers.
  private static let maxConsecutiveBad = 4
  private static let recordTimeout: TimeInterval = 25
  /// The room must sit this far below TRAIL_SILENCE_DB before a block starts. Nearer the
  /// threshold, room tone keeps resetting the capture's quiet window, and the tail runs
  /// to POST_ROLL_MAX_MS on most turns.
  private static let ambientMarginDb = 5.0
  /// Audio kept after the last word by Scripts/harness_clips.py (TRIM_TAIL_S).
  private static let clipTrailS = 0.12

  struct PlannedTurn {
    let clip: HarnessClip
    let gapS: Double
    let leadMs: Double
    let tailMs: Double
  }

  init(
    options: HarnessOptions, clips: [HarnessClip], owner: [String: String], apiKey: String,
    vocabulary: String?, buildId: String
  ) throws {
    self.options = options
    self.clips = clips
    self.arms = options.arms.compactMap(HarnessArm.named)
    self.owner = owner
    self.apiKey = apiKey
    self.vocabulary = vocabulary
    self.buildId = buildId
    self.rng = SeededGenerator(seed: options.seed)
    clipDirectory = options.root.appendingPathComponent("build/harness/clips")
    let runs = options.root.appendingPathComponent("build/harness/runs")
    try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    runId = formatter.string(from: Date())
    historyPath = options.root.appendingPathComponent("build/harness/history.db").path
    let rowsURL = runs.appendingPathComponent("\(runId).jsonl")
    let logURL = runs.appendingPathComponent("\(runId).log")
    FileManager.default.createFile(atPath: rowsURL.path, contents: nil)
    FileManager.default.createFile(atPath: logURL.path, contents: nil)
    rows = try FileHandle(forWritingTo: rowsURL)
    log = try FileHandle(forWritingTo: logURL)
    let directory = clipDirectory
    let urls = clips.map { directory.appendingPathComponent("\($0.clipId).wav") }
    let format = try ClipPlayer.format(of: urls[0])
    for url in urls where try ClipPlayer.format(of: url) != format {
      throw HarnessError.setup("\(url.lastPathComponent) differs in format; regenerate the bank")
    }
    player = try ClipPlayer(format: format)
  }

  func requestStop() {
    stopLock.lock()
    stopRequested = true
    stopLock.unlock()
  }

  private var shouldStop: Bool {
    stopLock.lock()
    defer { stopLock.unlock() }
    return stopRequested
  }

  func writeLog(_ line: String) {
    logLock.lock()
    log.write(Data("\(ISO8601DateFormatter().string(from: Date())) \(line)\n".utf8))
    logLock.unlock()
  }

  private func say(_ line: String) {
    print(line)
    fflush(stdout)
    writeLog("[harness] \(line)")
  }

  /// Returns the process exit status: 0 done or stopped, 2 aborted by a setup problem.
  func run() -> Int32 {
    say(
      "run \(runId): arms \(arms.map(\.name).joined(separator: ", ")), \(options.turnsPerArm) turns per arm"
    )
    for arm in arms {
      let values = HarnessSettings.values(arm: arm, owner: owner)
      let summary = HarnessSettings.reportedKeys.map { "\($0)=\(values[$0] ?? "default")" }
      writeLog("[settings] \(arm.name): \(summary.joined(separator: " "))")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + options.maxMinutes * 60
    var counts: [String: Int] = [:]
    var round = 0
    while !shouldStop, arms.contains(where: { counts[$0.name, default: 0] < options.turnsPerArm }) {
      let block = (0..<options.blockSize).map { _ in plan() }
      let offset = round % arms.count
      for arm in Array(arms[offset...] + arms[..<offset]) {
        let remaining = options.turnsPerArm - counts[arm.name, default: 0]
        guard remaining > 0 else { continue }
        switch runBlock(arm: arm, turns: Array(block.prefix(remaining)), round: round) {
        case .completed(let done): counts[arm.name, default: 0] += done
        case .aborted(let reason):
          say("ABORT: \(reason)")
          return 2
        }
        if shouldStop { break }
        if ProcessInfo.processInfo.systemUptime > deadline {
          say("max-minutes reached; stopping")
          requestStop()
          break
        }
      }
      round += 1
    }
    say(
      "finished: " + arms.map { "\($0.name)=\(counts[$0.name, default: 0])" }.joined(separator: " ")
    )
    player.shutdown()
    try? rows.close()
    try? log.close()
    return 0
  }

  // MARK: - Planning

  /// Idle gaps follow the owner's measured mix (about 40% under 30 s, 17% between 30 and
  /// 90 s, 43% longer). Longer gaps are drawn from 95 to 110 s: past the 90 s release window
  /// every gap leaves the microphone in the same cold state, so waiting longer adds nothing.
  private func plan() -> PlannedTurn {
    if deck.isEmpty { deck = clips.shuffled(using: &rng) }
    let clip = deck.removeLast()
    let bucket = Double.random(in: 0..<1, using: &rng)
    let gap: Double
    if bucket < 0.40 {
      gap = Double.random(in: 3...30, using: &rng)
    } else if bucket < 0.57 {
      gap = Double.random(in: 30...88, using: &rng)
    } else {
      gap = Double.random(in: 95...110, using: &rng)
    }
    return PlannedTurn(
      clip: clip, gapS: gap * options.gapScale,
      leadMs: Double.random(in: 150...450, using: &rng),
      tailMs: Double.random(in: 100...500, using: &rng))
  }

  // MARK: - Blocks

  private enum BlockResult {
    case completed(Int)
    case aborted(String)
  }

  private func runBlock(arm: HarnessArm, turns: [PlannedTurn], round: Int) -> BlockResult {
    guard waitForQuietRoom() else { return .completed(0) }
    let observer = HarnessObserver { [weak self] line in self?.writeLog("[\(arm.name)] \(line)") }
    let configuration = HarnessSettings.configuration(
      arm: arm, owner: owner, apiKey: apiKey, historyPath: historyPath, buildId: buildId,
      vocabulary: vocabulary)
    var engine: DictationEngine?
    var started = false
    DispatchQueue.main.sync {
      let instance = DictationEngine(config: configuration, delivery: .sink { _ in })
      instance.delegate = observer
      started = instance.startHeadless()
      engine = instance
    }
    guard let engine, started else {
      return .aborted("engine did not start: microphone not authorized or API key missing")
    }
    defer {
      DispatchQueue.main.sync { engine.stop() }
      // stop() retires the turn and closes history on the session queue.
      Thread.sleep(forTimeInterval: 2)
    }
    let readyBy = ProcessInfo.processInfo.systemUptime + 20
    while !engine.isLiveReady, ProcessInfo.processInfo.systemUptime < readyBy {
      Thread.sleep(forTimeInterval: 0.1)
    }
    if !engine.isLiveReady { writeLog("[\(arm.name)] Live not ready after 20 s; running anyway") }

    var done = 0
    var consecutiveBad = 0
    var previousEnd = ProcessInfo.processInfo.systemUptime
    for (position, turn) in turns.enumerated() {
      guard waitUntil(previousEnd + turn.gapS), waitForSpeakers() else { break }
      let actualGap = ProcessInfo.processInfo.systemUptime - previousEnd
      guard
        let row = runTurn(
          engine: engine, observer: observer, arm: arm, configuration: configuration, turn: turn,
          round: round, position: position, actualGap: actualGap)
      else { return .aborted("could not play clip \(turn.clip.clipId)") }
      previousEnd = ProcessInfo.processInfo.systemUptime
      done += 1
      let usable = row.outcome == "success" && (row.accuracy?.hypothesisWords ?? 0) > 0
      consecutiveBad = usable ? 0 : consecutiveBad + 1
      if consecutiveBad >= Self.maxConsecutiveBad {
        return .aborted(
          "\(consecutiveBad) turns in a row without a transcript. Check that the lid is open, "
            + "the speakers are on and audible, and nothing else is using the microphone.")
      }
      if shouldStop { break }
    }
    return .completed(done)
  }

  // MARK: - Turns

  private func runTurn(
    engine: DictationEngine, observer: HarnessObserver, arm: HarnessArm,
    configuration: EngineConfiguration, turn: PlannedTurn, round: Int, position: Int,
    actualGap: Double
  ) -> HarnessTurnRow? {
    let clip = turn.clip
    observer.reset()
    let startedAt = ISO8601DateFormatter().string(from: Date())

    // All three instants are on the host clock. Speech reaches the air leadMs after the
    // press, as a person starts talking after pressing, and the release comes tailMs after
    // the last word leaves the speaker.
    let keyDown = ClipPlayer.now + 0.25
    let speechStart = keyDown + turn.leadMs / 1000
    let keyUp = speechStart + (clip.speechOffsetS - clip.speechOnsetS) + turn.tailMs / 1000
    let expectedEnd: TimeInterval
    do {
      expectedEnd = try player.play(
        url: clipDirectory.appendingPathComponent("\(clip.clipId).wav"),
        at: speechStart - clip.speechOnsetS)
    } catch {
      writeLog("[harness] \(clip.clipId): \(error)")
      return nil
    }
    waitUntilHost(keyDown)
    DispatchQueue.main.async { engine.harnessKeyDown() }
    waitUntilHost(keyUp)
    // Starting a cold microphone can stall the built-in output for a moment, so the clip
    // may still be playing. Then the release waits for the real end of speech: the clip
    // ends TRIM_TAIL (0.12 s) after its last word, and the planned tail follows that word.
    var playbackDelayMs: Double?
    if let finished = player.playedBack(timeout: 0) {
      playbackDelayMs = (finished - expectedEnd) * 1000
    } else if let finished = player.playedBack(timeout: 15) {
      playbackDelayMs = (finished - expectedEnd) * 1000
      waitUntilHost(finished - Self.clipTrailS + turn.tailMs / 1000)
    }
    DispatchQueue.main.async { engine.harnessKeyUp() }
    let record = observer.waitForRecord(timeout: Self.recordTimeout)
    player.stopClip()
    if record == nil, observer.captureStarted {
      // A timed-out turn may still be finishing; let it end before the next press.
      Thread.sleep(forTimeInterval: 5)
    }

    turnIndex += 1
    var row = HarnessTurnRow(
      runId: runId, startedAt: startedAt, round: round, arm: arm.name, turnIndex: turnIndex,
      turnInBlock: position, clipId: clip.clipId, phraseId: clip.phraseId,
      ttsModel: clip.ttsModel, voice: clip.voice, accent: clip.accent, style: clip.style,
      language: clip.language ?? "en", codeSwitch: clip.codeSwitch,
      clipSpeechS: clip.speechOffsetS - clip.speechOnsetS,
      plannedGapS: turn.gapS, actualGapS: actualGap, leadMs: turn.leadMs, tailMs: turn.tailMs,
      captureStarted: observer.captureStarted, failures: observer.failureMessages,
      keepMicWarm: configuration.keepMicrophoneWarm,
      micIdleTimeoutS: configuration.micIdleTimeoutSec,
      endpointAligned: configuration.wsEndpointAligned,
      silenceFlushMs: configuration.silenceFlushMs, ambientDb: ambientDb, reference: clip.text)
    row.playbackDelayMs = playbackDelayMs
    if let record { row.apply(record) } else { row.outcome = "no_record" }
    write(row)

    let fmt = { (value: Double?) in value.map { String(format: "%.0f", $0) } ?? "-" }
    say(
      "[\(turnIndex)] \(arm.name) \(clip.clipId) gap=\(fmt(actualGap))s "
        + "\(row.micStateAtKeydown ?? "-") start=\(fmt(row.captureStartMs)) "
        + "total=\(fmt(row.totalMs)) \(row.outcome ?? "-") "
        + "wer=\(row.accuracy.map { String(format: "%.2f", $0.wer) } ?? "-") "
        + "playback_delay=\(fmt(playbackDelayMs))")
    return row
  }

  private func write(_ row: HarnessTurnRow) {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(row) else { return }
    rows.write(data + Data("\n".utf8))
  }

  // MARK: - Waiting

  /// Sleeps until an uptime instant. Returns false when a stop was requested first.
  @discardableResult
  private func waitUntil(_ instant: TimeInterval, interruptible: Bool = true) -> Bool {
    while true {
      if interruptible, shouldStop { return false }
      let remaining = instant - ProcessInfo.processInfo.systemUptime
      if remaining <= 0 { return true }
      Thread.sleep(forTimeInterval: min(remaining, interruptible ? 0.5 : remaining))
    }
  }

  /// Busy-waits the last few milliseconds so a press lands within about 1 ms of `instant`.
  private func waitUntilHost(_ instant: TimeInterval) {
    while true {
      let remaining = instant - ClipPlayer.now
      if remaining <= 0 { return }
      if remaining > 0.005 { Thread.sleep(forTimeInterval: remaining - 0.004) }
    }
  }

  /// Blocks until the room is quiet enough for the capture tail to behave as in real use.
  /// Measured with no engine running and nothing playing. Returns false on stop.
  private func waitForQuietRoom() -> Bool {
    let values = HarnessSettings.values(
      arm: HarnessArm(name: "probe", overrides: [:]), owner: owner)
    let limit = (Double(values["TRAIL_SILENCE_DB"] ?? "") ?? -40) - Self.ambientMarginDb
    var paused = false
    while true {
      ambientDb = AmbientProbe.medianLevel()
      guard let level = ambientDb else {
        say("ambient probe could not open the microphone; continuing without the gate")
        return true
      }
      writeLog(String(format: "[harness] ambient %.1f dBFS (limit %.1f)", level, limit))
      if options.allowNoisy || level <= limit {
        if paused { say(String(format: "resumed: room at %.1f dBFS", level)) }
        return true
      }
      if !paused {
        say(
          String(
            format:
              "paused: room at %.1f dBFS, above the %.1f dBFS limit. Rechecking every minute.",
            level, limit))
        paused = true
      }
      guard waitUntil(ProcessInfo.processInfo.systemUptime + 60) else { return false }
    }
  }

  /// Blocks while the output route cannot reach the microphone. Returns false on stop.
  private func waitForSpeakers() -> Bool {
    var reported: String?
    while true {
      let route = AudioRoute.current()
      guard let problem = route == nil ? "no output device" : route?.problem else { break }
      if problem != reported {
        say("paused: \(problem). Resumes when the built-in speakers are back.")
        reported = problem
      }
      guard waitUntil(ProcessInfo.processInfo.systemUptime + 10) else { return false }
    }
    if reported != nil { say("resumed") }
    return true
  }
}
