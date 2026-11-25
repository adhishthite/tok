// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class GeminiLiveClient: NSObject, URLSessionWebSocketDelegate {
  let apiKey: String
  private let model: String
  var webSocketTask: URLSessionWebSocketTask?
  var urlSession: URLSession!

  let lock = NSLock()
  private var connectedState = false
  var readyState = false
  var connectionID: UInt64 = 0
  var turnID: UInt64 = 0
  var turnOpen = false
  var turnHasAudioGap = false
  var rotateWhenIdle = false
  private var reconnectEnabled = true
  let sendQueue = DispatchQueue(label: "com.adhishthite.tok.send", qos: .userInitiated)
  private var turnWrites = DispatchGroup()

  var pendingWrites: [PendingWrite] = []
  private var pendingWriteBytes = 0
  private var nextWriteID: UInt64 = 0
  var writeTransport: (URLSessionWebSocketTask, String, @escaping (Error?) -> Void) -> Void = {
    task, text, completion in
    task.send(.string(text), completionHandler: completion)
  }
  private var writeInFlight = false
  private var turnSentAnyMessage = false
  var writeDeadline: DispatchWorkItem?
  /// Test seam: when set, connect() hands the new task and its epoch here instead of
  /// resuming the task, sending setup, and listening, so a connect opens no socket.
  var connectTransport: ((URLSessionWebSocketTask, UInt64) -> Void)?
  private static let maxPendingWriteBytes = 256 * 1024
  private static let maxPendingWriteAge = 3.0
  /// The documented maximum for one live transcription session.
  static let sessionLimitSeconds = 600.0
  /// Age at which an idle session is replaced so a turn never starts near the limit.
  static let sessionRotationSeconds = 480.0
  private var sessionEstablishedAt: TimeInterval = 0
  private var sessionRotationWorkItem: DispatchWorkItem?
  /// Why the in-flight connect attempt was started (startup, rotation, reconnect, wake,
  /// turn_reset).
  /// Read back once the handshake completes so the single "session ready" line can name
  /// it, instead of a separate "connecting" line logged per attempt.
  var pendingConnectReason = "startup"
  var isConnected: Bool {
    lock.lock()
    defer { lock.unlock() }
    return connectedState
  }
  var isReady: Bool {
    lock.lock()
    defer { lock.unlock() }
    return readyState
  }
  /// Connection readiness and session age at the instant of a key-down: "ready" with the
  /// socket's age when a session is established, "connecting" while a handshake is in
  /// flight, "closed" otherwise. A brief lock scope; callers on main must never do more.
  var socketStateAtKeydown: (state: String, ageMs: Double?) {
    lock.lock()
    defer { lock.unlock() }
    if readyState {
      return ("ready", (ProcessInfo.processInfo.systemUptime - sessionEstablishedAt) * 1000.0)
    }
    return (webSocketTask != nil ? "connecting" : "closed", nil)
  }
  // Whether the socket identity changed (a new connection was established) or was lost
  // while the current turn was open. Reset in startNewTurn; set in connect() and
  // connectionFailed(), both already under `lock`. Read via lastConnectionChangedDuringTurn
  // after settle, the same pattern as lastSettlePath.
  private var turnConnectionChanged = false
  var lastConnectionChangedDuringTurn: Bool {
    lock.lock()
    defer { lock.unlock() }
    return turnConnectionChanged
  }
  // Round-trip split from commit to each network milestone the turn passes, all ms. Each is
  // set at most once per turn, at the moment the event lands, under `lock`; startNewTurn
  // resets them. Read via lastRoundTrip after settle, the same pattern as lastSettlePath.
  private var commitToLastSendMs: Double?
  private var commitToFirstMsgMs: Double?
  private var commitToFinalMs: Double?
  private var commitToTurnCompleteMs: Double?
  var lastRoundTrip:
    (lastSendMs: Double?, firstMsgMs: Double?, finalMs: Double?, turnCompleteMs: Double?)
  {
    lock.lock()
    defer { lock.unlock() }
    return (commitToLastSendMs, commitToFirstMsgMs, commitToFinalMs, commitToTurnCompleteMs)
  }
  /// Seconds left before the current session reaches the documented limit, or nil when
  /// no session is established.
  var sessionRemainingSeconds: Double? {
    lock.lock()
    defer { lock.unlock() }
    guard readyState, sessionEstablishedAt > 0 else { return nil }
    return Self.sessionLimitSeconds - (ProcessInfo.processInfo.systemUptime - sessionEstablishedAt)
  }
  var canCommitTurn: Bool {
    lock.lock()
    defer { lock.unlock() }
    return readyState && turnOpen && !turnHasAudioGap
  }

  // SMART transcription keeps text context across the turns of one session: every finalized
  // transcription restates the whole session so far, not only the current turn, and only a
  // new connection clears it. These three track that context per connection, under `lock`,
  // and matter only when usesSmartSessionContext is true.
  /// True once a SMART turn has used the current connection: a write of that turn's audio
  /// or activity reached this socket, or the socket delivered a non-empty finalized
  /// transcription, whether or not a turn was open to consume it. Either way the server may
  /// now hold text it would restate in the next turn's finals.
  var sessionUsedBySmartTurn = false
  /// The server's cumulative text as of the last turn that completed on this connection.
  var sessionCommittedTranscript = ""
  /// The last finalized text of the current turn as the server sent it, trimmed, before any
  /// earlier-turn prefix is removed.
  var turnLastCumulativeServerFinal: String?

  var currentTurnText: String = ""
  // Multi-segment transcript accumulator. The server's VAD closes a speech segment at every
  // pause: the finished segment arrives as a finalized transcription, then the NEXT segment's
  // interim text starts empty - so treating any single message as "the whole turn so far"
  // wipes every earlier segment (pause mid-utterance -> first sentence lost). Finalized
  // segments accumulate in committedTranscript; interimTranscript holds only the in-progress
  // segment; currentTurnText is always their merge.
  var committedTranscript: String = ""
  var interimTranscript: String = ""
  private var firstTokenLatencyMs: Double = 0
  var turnCommitTime: CFAbsoluteTime = 0
  // When the turn's audio window opened, which is also when the manual activityStart goes
  // out. firstTokenLatencyMs is measured from COMMIT and stays 0 whenever text arrived
  // during the hold, so it cannot answer how fast the service started transcribing.
  private var turnStartTime: CFAbsoluteTime = 0
  private var firstInterimLatencyMs: Double = 0
  private var completedFirstInterimMs: Double?
  private var lastTokenReceivedTime: CFAbsoluteTime = 0
  private var lastPostCommitTokenTime: CFAbsoluteTime? = nil
  // Set when a FINAL transcription arrives post-commit; cleared if a later interim shows
  // more content is still streaming in.
  private var lastPostCommitFinalTime: CFAbsoluteTime? = nil

  // API-metered token usage. Server messages carry cumulative usageMetadata for the session,
  // so per-turn usage is the delta from the counts snapshotted at startNewTurn. All under `lock`.
  var lastSeenPromptTokens: Int = 0
  var lastSeenResponseTokens: Int = 0
  private var turnBaselinePromptTokens: Int = 0
  private var turnBaselineResponseTokens: Int = 0
  private var completedUsage: (inputTokens: Int, outputTokens: Int)?
  // Set once a reported count comes back smaller than the previous one. A cumulative
  // counter never shrinks, so from that point the reported value IS the turn's usage and
  // the baseline diff would under-report it.
  private var usageCountsArePerTurn = false

  /// API-reported usage for the current/most recent turn, or nil if the server reported
  /// nothing new this turn (caller falls back to a duration-based estimate).
  var lastTurnUsage: (inputTokens: Int, outputTokens: Int)? {
    lock.lock()
    defer { lock.unlock() }
    if hasFiredTurnCompletion { return completedUsage }
    return usageSnapshot()
  }

  /// Milliseconds from turn start to the first transcript text of any kind, or nil when the
  /// service sent none. Read after the turn completes, the same way as lastTurnUsage.
  var lastTurnFirstInterimMs: Double? {
    lock.lock()
    defer { lock.unlock() }
    if hasFiredTurnCompletion { return completedFirstInterimMs }
    return firstInterimLatencyMs > 0 ? firstInterimLatencyMs : nil
  }

  private func usageSnapshot() -> (inputTokens: Int, outputTokens: Int)? {
    if usageCountsArePerTurn {
      guard lastSeenPromptTokens > 0 || lastSeenResponseTokens > 0 else { return nil }
      return (max(0, lastSeenPromptTokens), max(0, lastSeenResponseTokens))
    }
    let dp = lastSeenPromptTokens - turnBaselinePromptTokens
    let dr = lastSeenResponseTokens - turnBaselineResponseTokens
    guard dp > 0 || dr > 0 else { return nil }
    return (max(0, dp), max(0, dr))
  }

  /// Records the latest reported counts. Caller holds `lock`.
  private func applyUsageLocked(promptTokens: Int?, responseTokens: Int?) {
    if let prompt = promptTokens {
      if prompt < lastSeenPromptTokens { usageCountsArePerTurn = true }
      lastSeenPromptTokens = prompt
    }
    if let response = responseTokens {
      if response < lastSeenResponseTokens { usageCountsArePerTurn = true }
      lastSeenResponseTokens = response
    }
    // Usage can trail the turn it belongs to. While the completed turn is still the latest
    // one, refresh its record so a late message is not thrown away.
    if hasFiredTurnCompletion, let refreshed = usageSnapshot() { completedUsage = refreshed }
  }
  // Which settlement rule ended the last turn - the mechanism WS_ENDPOINT_ALIGNED changes,
  // recorded per turn in history. Under `lock`; read via lastSettlePath after completion
  // (same pattern as lastTurnUsage).
  private var settlePathValue: String?
  var lastSettlePath: String? {
    lock.lock()
    defer { lock.unlock() }
    return settlePathValue
  }
  var commitWritesComplete = false
  var commitWritesCompletedAt: Double = 0
  private var serverCompletionReceived = false
  var isCommitting: Bool = false
  var hasFiredTurnCompletion: Bool = false
  var turnCompletion:
    ((Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void)?
  var onLiveTextUpdate: ((String) -> Void)?
  /// Called once when consecutive key rejections stop the reconnect loop.
  var onAuthRejected: (() -> Void)?
  /// Connection lifecycle telemetry: fired for a connect attempt, a lost
  /// connection, or an explicit close. Never called under `lock`. The receiver (History,
  /// through DictationEngine) writes asynchronously on its own queue, so this never blocks
  /// whichever thread the event happened on.
  var onConnectionEvent: ((_ kind: String, _ turnOpen: Bool, _ socketAgeS: Double?) -> Void)?
  private let smartTranscription: Bool
  let languageCodes: [String]
  private let customVocabulary: [String]
  private let vadMode: String
  private let vadSilenceMs: Int
  let endpointAligned: Bool

  // Conversational models always run with server VAD disabled (their setup hard-codes it);
  // transcribe models do so when VAD_MODE=manual. Either way the client must bracket each
  // turn with explicit activityStart/activityEnd signals.
  private var usesManualActivity: Bool {
    !model.contains("transcribe") || vadMode == "manual"
  }

  // Only the transcribe model in SMART mode carries text from one turn into the next.
  // VERBATIM finals cover the current segment alone, so those sessions are reused as before.
  private var usesSmartSessionContext: Bool {
    model.contains("transcribe") && smartTranscription
  }

  // Event-driven settlement timers for transcribe-model turn completion (see commitTurn/attemptSettle).

  private static let settleMinPostCommitWait: Double = 0.35
  private static let settleQuietWindow: Double = 0.25
  // With manual activity signaling the server owes an authoritative FINAL inputTranscription
  // after activityEnd. Interims are documented as "speculative partial hypotheses", so in
  // manual mode the interim-quiet fallback waits longer (don't paste speculation while the
  // final is still processing), and an observed final settles after only a short grace in
  // case a second segment's final is right behind it.
  private static let settleFinalGrace: Double = 0.15
  private static let settleInterimQuietManual: Double = 0.60
  private static let settleInitialWaitWithoutTokens: Double = 0.90
  private static let settleMaxWait: Double = 2.20
  // Settlement and deadlines use monotonic time; keep the existing scheduling allowance.
  private static let settleTimerCushion: Double = 0.01
  let settleQueue = DispatchQueue(label: "com.adhishthite.tok.settle")
  // reschedulable: initial-wait-without-tokens, then quiet-window checks
  private var settleWorkItem: DispatchWorkItem?
  private var settleMaxWorkItem: DispatchWorkItem?  // fixed hard ceiling check
  private var reconnectWorkItem: DispatchWorkItem?
  private var reconnectAttempts: Int = 0
  // An idle socket can be dropped by an intermediary without a close frame, and only a wake
  // or the eight-minute rotation used to notice. A ping every minute proves the path while
  // the app is idle, so a dead socket becomes a reconnect before the next key press needs it.
  private static let keepaliveIntervalSeconds = 60.0
  var keepaliveWorkItem: DispatchWorkItem?
  // A rejected key fails every attempt the same way, so retrying it forever only burns
  // battery. Count consecutive rejections and stop; an explicit connect() starts over.
  private static let maxAuthRejections = 3
  private var authRejectionCount = 0
  private var lastCloseIndicatedRejection = false
  /// Category of the current socket's close-frame reason, from closeReasonCategory. Nil
  /// until a close frame arrives. Guarded by `lock`.
  private var lastCloseReasonCategory: String?

  init(
    apiKey: String,
    model: String = "gemini-3.5-transcribe-live",
    smartTranscription: Bool = true,
    languageCodes: [String] = ["en-IN", "hi-IN", "mr-IN"],
    customVocabulary: [String] = [],
    vadMode: String = "manual",
    vadSilenceMs: Int = 1500,
    endpointAligned: Bool = true
  ) {
    self.apiKey = apiKey
    self.model = model
    self.smartTranscription = smartTranscription
    self.languageCodes = languageCodes
    self.customVocabulary = customVocabulary
    self.vadMode = vadMode
    self.vadSilenceMs = vadSilenceMs
    self.endpointAligned = endpointAligned
    super.init()
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = true
    config.timeoutIntervalForRequest = 10.0
    self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
  }

  func connect(
    onlyWhenIdle: Bool = false, expectedConnection: UInt64? = nil, reason: String = "reconnect"
  ) {
    guard !apiKey.isEmpty else { return }

    // A stale or deferred attempt is decided before any task exists, so it never allocates
    // one only to cancel it.
    lock.lock()
    let mayProceed = connectMayProceedLocked(
      onlyWhenIdle: onlyWhenIdle, expectedConnection: expectedConnection)
    lock.unlock()
    guard mayProceed else { return }

    let wsUrlString =
      "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    guard let url = URL(string: wsUrlString) else {
      Log.error("WS", "Invalid WebSocket URL.")
      return
    }

    var request = URLRequest(url: url)
    request.timeoutInterval = 10.0
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

    let task = urlSession.webSocketTask(with: request)
    lock.lock()
    // The task was built off the lock, and connect() runs on main, settleQueue, and the
    // URLSession delegate queue, so the same checks are repeated before any state changes.
    guard
      connectMayProceedLocked(onlyWhenIdle: onlyWhenIdle, expectedConnection: expectedConnection)
    else {
      lock.unlock()
      task.cancel(with: .goingAway, reason: nil)
      return
    }
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    sessionRotationWorkItem?.cancel()
    sessionRotationWorkItem = nil
    keepaliveWorkItem?.cancel()
    keepaliveWorkItem = nil
    sessionEstablishedAt = 0
    lastCloseIndicatedRejection = false
    lastCloseReasonCategory = nil
    // Only a caller-initiated connect clears the rejection streak. Clearing it on the
    // reconnect path too would make the three-strike stop unreachable.
    if expectedConnection == nil { authRejectionCount = 0 }
    reconnectEnabled = true
    connectionID &+= 1
    // Only a connect during an open turn counts. A heuristic finish closes its turn, then
    // retires the socket here before the engine reads the flag in settle().
    if turnOpen { turnConnectionChanged = true }
    let epoch = connectionID
    let old = webSocketTask
    self.webSocketTask = task
    readyState = false
    connectedState = false
    if turnOpen && turnSentAnyMessage {
      turnHasAudioGap = true
      discardPendingWritesLocked()
    }
    rotateWhenIdle = false
    resetSessionContextLocked()
    pendingConnectReason = reason
    let turnOpenAtConnect = turnOpen
    lock.unlock()
    old?.cancel(with: .goingAway, reason: nil)

    // No per-attempt "connecting" line: the single "session ready" line logged once the
    // handshake completes (below) names this attempt's reason, so a planned rotation
    // costs one persisted line instead of two.
    Log.debug("WS", "Connecting to Gemini Live WebSockets (\(model), reason=\(reason))...")
    if let transport = connectTransport {
      transport(task, epoch)
    } else {
      task.resume()
      sendSetupMessage(task: task, epoch: epoch)
      listenForMessages(task: task, epoch: epoch)
    }
    onConnectionEvent?(Self.connectionEventKind(forConnectReason: reason), turnOpenAtConnect, nil)
  }

  /// Whether a connect attempt goes ahead. Caller holds `lock`. A scheduled attempt whose
  /// connection was already replaced, or that arrives after reconnects were stopped, is
  /// dropped. An idle-only attempt that finds a healthy open turn is deferred until that
  /// turn completes, which is the only state this changes.
  private func connectMayProceedLocked(onlyWhenIdle: Bool, expectedConnection: UInt64?) -> Bool {
    if let expected = expectedConnection, expected != connectionID || !reconnectEnabled {
      return false
    }
    if onlyWhenIdle && turnOpen && readyState {
      rotateWhenIdle = true
      return false
    }
    return true
  }

  /// A new or closed connection has no server-side transcript yet. Caller holds `lock`.
  private func resetSessionContextLocked() {
    sessionUsedBySmartTurn = false
    sessionCommittedTranscript = ""
    turnLastCumulativeServerFinal = nil
  }

  /// Maps the free-form `reason` a connect attempt is tagged with to one of the fixed
  /// connection_events kinds. Every reason this client actually passes to connect()
  /// ("startup", "rotation", "wake", "turn_reset", and the default "reconnect") is named
  /// explicitly; anything else still gets a kind rather than being dropped. "turn_reset"
  /// is the planned replacement of a session after a turn used it, kept apart from
  /// "reconnect" so those planned resets do not read as recoveries.
  private static func connectionEventKind(forConnectReason reason: String) -> String {
    switch reason {
    case "startup": return "connect_startup"
    case "rotation": return "connect_rotation"
    case "wake": return "connect_wake"
    case "turn_reset": return "connect_turn_reset"
    default: return "connect_reconnect"
    }
  }

  private func sendSetupMessage(task: URLSessionWebSocketTask, epoch: UInt64) {
    let setupPayload: [String: Any]
    if model.contains("transcribe") {
      // Dedicated STT Live Streaming Model. Documented setup shape (live-transcribe guide):
      // transcription options live in top-level setup.inputAudioTranscription - NOT inside
      // generationConfig - so mode/languages/vocabulary are actually honored by the server.
      var transcriptionConfig: [String: Any] = [
        "mode": smartTranscription ? "SMART" : "VERBATIM"
      ]
      if !languageCodes.isEmpty {
        transcriptionConfig["languageCodes"] = languageCodes
      }
      if !customVocabulary.isEmpty {
        transcriptionConfig["customVocabulary"] = customVocabulary
      }

      var setup: [String: Any] = [
        "model": "models/\(model)",
        "generationConfig": [
          "responseModalities": ["TEXT"]
        ],
        "inputAudioTranscription": transcriptionConfig,
      ]

      // Push-to-talk owns the ground truth of when speech starts and ends (the key hold),
      // so the default is manual activity signaling: server VAD otherwise declares
      // end-of-speech at natural pauses and stops transcribing mid-hold.
      switch vadMode {
      case "manual":
        setup["realtimeInputConfig"] = [
          "automaticActivityDetection": ["disabled": true]
        ]
      case "tuned":
        // Server VAD stays on but is made maximally pause-tolerant. These generic Live
        // API fields are not documented for the transcribe model specifically; a setup
        // rejection is surfaced by the server-error log line - fall back to VAD_MODE=auto.
        setup["realtimeInputConfig"] = [
          "automaticActivityDetection": [
            "disabled": false,
            "startOfSpeechSensitivity": "START_SENSITIVITY_HIGH",
            "endOfSpeechSensitivity": "END_SENSITIVITY_LOW",
            "silenceDurationMs": vadSilenceMs,
          ],
          "turnCoverage": "TURN_INCLUDES_ALL_INPUT",
        ]
      default:
        // "auto": stock server-side VAD, no realtimeInputConfig sent.
        break
      }

      setupPayload = ["setup": setup]
    } else {
      // Multimodal Conversational Audio Model with manual activity detection
      var instruction = """
        You are an ultra-fast, high-precision voice dictation engine.
        Transcribe the user's spoken words verbatim and polish into clean written prose.
        Rules:
        1. Output ONLY the exact transcribed words with proper grammar, punctuation, and capitalization.
        2. Remove speech disfluencies (um, uh, like, you know, stuttering, repeated words).
        3. Never converse, reply to questions, add commentary, or say things like "I understand", "Sure", or "Here is...".
        4. Never wrap text in quotation marks or code fences unless explicitly dictating code.
        5. If the audio is silent or unintelligible, output nothing.
        """
      if !languageCodes.isEmpty {
        instruction += "\nTarget language(s): \(languageCodes.joined(separator: ", "))"
      }
      if !customVocabulary.isEmpty {
        instruction +=
          "\n\nCustom vocabulary and technical terms to recognize accurately: \(customVocabulary.joined(separator: ", "))"
      }

      setupPayload = [
        "setup": [
          "model": "models/\(model)",
          "generationConfig": [
            "responseModalities": ["AUDIO"],
            "thinkingConfig": [
              "thinkingLevel": "minimal"
            ],
          ],
          "realtimeInputConfig": [
            "automaticActivityDetection": [
              "disabled": true
            ]
          ],
          "inputAudioTranscription": [:],
          "outputAudioTranscription": [:],
          "systemInstruction": [
            "parts": [
              [
                "text": instruction
              ]
            ]
          ],
        ]
      ]
    }

    guard let jsonData = try? JSONSerialization.data(withJSONObject: setupPayload),
      let jsonString = String(data: jsonData, encoding: .utf8)
    else {
      Log.error("WS", "Failed to serialize setup message.")
      return
    }

    task.send(.string(jsonString)) { [weak self] error in
      if let error = error { self?.connectionFailed(epoch: epoch, error: error) }
    }
  }

  /// `reason` only picks the connection_events kind this reports: a failed idle keepalive
  /// ping ("keepalive") and the deliberate retirement of a SMART session that mixed earlier
  /// turns into its text ("context_mismatch") are kept apart from every other cause, so a
  /// planned retirement does not read as a lost connection. It changes no reconnect behavior.
  func connectionFailed(epoch: UInt64, error: Error, reason: String = "error") {
    lock.lock()
    guard epoch == connectionID else {
      lock.unlock()
      return
    }
    let turnOpenAtFailure = turnOpen
    let socketAgeS =
      sessionEstablishedAt > 0 ? ProcessInfo.processInfo.systemUptime - sessionEstablishedAt : nil
    turnConnectionChanged = true
    readyState = false
    connectedState = false
    if turnOpen && turnSentAnyMessage {
      turnHasAudioGap = true
      discardPendingWritesLocked()
    }
    let completion = hasFiredTurnCompletion ? nil : turnCompletion
    turnCompletion = nil
    if completion != nil {
      hasFiredTurnCompletion = true
      isCommitting = false
    }
    keepaliveWorkItem?.cancel()
    keepaliveWorkItem = nil
    // An invalid key fails the upgrade with 400/401/403, or the server closes the socket and
    // names the key. A successful upgrade (101) proves the key and clears the streak; a
    // transport failure with no response leaves the streak alone.
    let status = (webSocketTask?.response as? HTTPURLResponse)?.statusCode
    let closeCode = webSocketTask?.closeCode.rawValue ?? 0
    let closeCategory = lastCloseReasonCategory
    if Self.isAuthRejection(status: status) || lastCloseIndicatedRejection {
      authRejectionCount += 1
    } else if status != nil {
      authRejectionCount = 0
    }
    let stopReconnecting = authRejectionCount >= Self.maxAuthRejections
    if stopReconnecting { reconnectEnabled = false }
    lock.unlock()
    let kind = Self.lossEventKind(forFailureReason: reason)
    Log.info(
      "WS",
      Self.lossDescription(
        kind: kind, closeCode: closeCode, closeCategory: closeCategory, error: error,
        socketAgeS: socketAgeS))
    onConnectionEvent?(kind, turnOpenAtFailure, socketAgeS)
    completion?(.failure(error))
    if stopReconnecting {
      Log.error("WS", "API key rejected; not reconnecting.")
      onAuthRejected?()
      return
    }
    scheduleReconnect(epoch: epoch)
  }

  /// Maps a connectionFailed `reason` to its connection_events kind.
  private static func lossEventKind(forFailureReason reason: String) -> String {
    switch reason {
    case "keepalive": return "lost_keepalive"
    case "context_mismatch": return "lost_context_mismatch"
    default: return "lost_error"
    }
  }

  /// One diagnostics line per lost connection: the close code (0 when no close frame came),
  /// the close reason's category, and the error's domain and number. Never the reason or
  /// error text, which can quote request details.
  static func lossDescription(
    kind: String, closeCode: Int, closeCategory: String?, error: Error, socketAgeS: Double?
  ) -> String {
    let nsError = error as NSError
    let age = socketAgeS.map { String(format: "%.1fs", $0) } ?? "-"
    return "connection lost kind=\(kind) close=\(closeCode) "
      + "closeReason=\(closeCategory ?? "-") error=\(nsError.domain)/\(nsError.code) age=\(age)"
  }

  /// A fixed category for a close-frame reason, so the text itself is never logged.
  static func closeReasonCategory(_ reason: String) -> String {
    let lowered = reason.lowercased()
    if lowered.isEmpty { return "none" }
    if mentionsKeyRejection(lowered) { return "key" }
    if ["quota", "rate limit", "resource_exhausted", "resource exhausted"].contains(where: {
      lowered.contains($0)
    }) {
      return "quota"
    }
    if ["deadline", "timeout", "timed out", "idle"].contains(where: { lowered.contains($0) }) {
      return "timeout"
    }
    return "other"
  }

  private static func isAuthRejection(status: Int?) -> Bool {
    guard let status else { return false }
    return status == 400 || status == 401 || status == 403
  }

  /// The server can also refuse the key after the upgrade succeeds, with a close frame.
  /// Record what it indicated; connectionFailed decides what to do about it. The code and
  /// the reason's category are logged; the reason text never is.
  func urlSession(
    _ session: URLSession, webSocketTask: URLSessionWebSocketTask,
    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?
  ) {
    let text = reason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
    // Close code 1008 alone is not a key verdict: services use it for quota and rate limits
    // too. Only a reason that names the key or authentication counts.
    let rejected = Self.mentionsKeyRejection(text)
    let category = Self.closeReasonCategory(text)
    lock.lock()
    let current = webSocketTask === self.webSocketTask
    if current {
      lastCloseIndicatedRejection = rejected
      lastCloseReasonCategory = category
    }
    lock.unlock()
    if current { Log.info("WS", "close frame code=\(closeCode.rawValue) reason=\(category)") }
  }

  private static func mentionsKeyRejection(_ reason: String) -> Bool {
    let lowered = reason.lowercased()
    return lowered.contains("api key") || lowered.contains("api_key")
      || lowered.contains("unauthenticated")
  }

  private func listenForMessages(task: URLSessionWebSocketTask, epoch: UInt64) {
    task.receive { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success(let message):
        self.handleIncomingMessage(message, epoch: epoch)
        self.lock.lock()
        let current = self.connectionID == epoch
        self.lock.unlock()
        if current { self.listenForMessages(task: task, epoch: epoch) }
      case .failure(let error): self.connectionFailed(epoch: epoch, error: error)
      }
    }
  }

  func handleIncomingMessage(_ message: URLSessionWebSocketTask.Message, epoch: UInt64) {
    var rawData: Data?
    switch message {
    case .string(let str):
      rawData = str.data(using: .utf8)
    case .data(let data):
      rawData = data
    @unknown default:
      break
    }

    guard let data = rawData,
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      return
    }

    // Actions to perform once the lock is released: logging, meter text, and callbacks
    // must never run while `lock` is held.
    var serverErrorMessage: String? = nil
    var didCompleteSetup = false
    var connectReasonForLog = ""
    var shouldScheduleReconnect = false
    var liveTextUpdate: (label: String, elapsedMs: Double, fullText: String, textCopy: String)? =
      nil
    var shouldCompleteServerTurn = false
    // Set when a post-commit token arrives while committing: elapsed time since turnCommitTime,
    // used after unlock to (re)schedule the settle check. Finals get the short authoritative
    // grace; interims get the (mode-aware) quiet window.
    var quietRescheduleElapsedSinceCommit: Double? = nil
    var quietRescheduleIsFinal = false
    var messageTurn: UInt64 = 0
    // Set when a reused SMART session returned text this turn cannot be separated from.
    var sessionContextMismatch = false
    var usageTrace:
      (keys: String, prompt: Int?, response: Int?, afterTurnComplete: Bool, perTurn: Bool)? = nil

    lock.lock()

    guard epoch == connectionID else {
      lock.unlock()
      return
    }

    messageTurn = turnID

    // Round-trip split: the first server message of any kind after this turn's
    // commit, whatever it carries.
    if isCommitting, commitToFirstMsgMs == nil {
      commitToFirstMsgMs = (ProcessInfo.processInfo.systemUptime - turnCommitTime) * 1000.0
    }

    // 0. Server error handling
    if let errorObj = json["error"] as? [String: Any] {
      serverErrorMessage = (errorObj["message"] as? String) ?? "Unknown server error"
    }

    // 0b. Usage metadata can accompany any server message; keep the latest counts.
    if let usage = json["usageMetadata"] as? [String: Any] {
      let prompt = usage["promptTokenCount"] as? Int
      // Live and REST have used different names for the output count. Read both so a
      // rename does not silently zero the metered total.
      let response =
        (usage["responseTokenCount"] as? Int) ?? (usage["candidatesTokenCount"] as? Int)
      applyUsageLocked(promptTokens: prompt, responseTokens: response)
      // Field names and counts only, never transcript text. This line answers whether usage
      // arrives before or after turnComplete, which decides whether the settle-time read
      // can see it at all.
      usageTrace = (
        keys: usage.keys.sorted().joined(separator: ","), prompt: prompt, response: response,
        afterTurnComplete: serverCompletionReceived || hasFiredTurnCompletion,
        perTurn: usageCountsArePerTurn
      )
    }

    // 0c. Finalized text advances the server's SMART session context whether or not a turn
    // is open to consume it. Anything from an earlier connection was dropped by the epoch
    // guard above, so this only ever describes the current socket.
    if usesSmartSessionContext, let content = json["serverContent"] as? [String: Any],
      Self.transcription(in: content, key: "inputTranscription") != nil
        || Self.transcription(in: content, key: "inputAudioTranscription") != nil
    {
      sessionUsedBySmartTurn = true
    }

    // 1. Handshake confirmation
    if json["setupComplete"] != nil {
      self.connectedState = true
      self.readyState = true
      self.reconnectAttempts = 0
      didCompleteSetup = true
      connectReasonForLog = pendingConnectReason
      self.sessionEstablishedAt = ProcessInfo.processInfo.systemUptime
      scheduleSessionRotationLocked(epoch: epoch)
      scheduleKeepaliveLocked(epoch: epoch)
      // The handshake completed, so this key works.
      self.authRejectionCount = 0
      self.lastCloseIndicatedRejection = false
      self.lastCloseReasonCategory = nil
      // Fresh session: server-side cumulative token counters restart from zero.
      self.lastSeenPromptTokens = 0
      self.lastSeenResponseTokens = 0
      self.turnBaselinePromptTokens = 0
      self.turnBaselineResponseTokens = 0
      // Fresh session: the server holds no transcript from earlier turns.
      resetSessionContextLocked()
    }
    // 2. Server goAway notification (Server scheduled disconnect)
    else if json["goAway"] != nil {
      rotateWhenIdle = true
      shouldScheduleReconnect = !turnOpen
    }
    // 3. Server content (transcription streaming)
    else if turnOpen, let serverContent = json["serverContent"] as? [String: Any] {
      var updatedText: String? = nil
      var isUserSpeech = false
      var isFinalTranscription = false

      // A whitespace-only payload counts as absent, so the next form in priority order is
      // read instead. Non-empty text reaches the accumulator exactly as sent: its joins
      // depend on the server's own spacing and line breaks.
      // PRIORITY 1: Finalized inputTranscription (e.g. gemini-3.5-transcribe-live) -
      // closes the current speech segment; earlier segments must be preserved.
      let primaryFinal = Self.transcription(in: serverContent, key: "inputTranscription")
      // PRIORITY 2: Progressive Interim Transcription - rewrites only the live segment.
      let interim =
        primaryFinal == nil
        ? Self.transcription(in: serverContent, key: "interimInputTranscription") : nil
      // PRIORITY 3: Alternative inputAudioTranscription (finalized form)
      let alternateFinal =
        primaryFinal == nil && interim == nil
        ? Self.transcription(in: serverContent, key: "inputAudioTranscription") : nil

      if let finalText = primaryFinal ?? alternateFinal {
        let outcome = consumeFinalTranscriptionLocked(finalText)
        if outcome.applied {
          updatedText = mergedTranscript()
          isUserSpeech = true
          isFinalTranscription = true
        }
        if outcome.contextMismatch {
          // The same route a broken audio stream takes: the turn can no longer commit or
          // complete on this socket, and connectionFailed (below, off the lock) reports it.
          turnHasAudioGap = true
          discardPendingWritesLocked()
          sessionContextMismatch = true
        }
      } else if let text = interim {
        applyInterimTranscription(text.raw)
        updatedText = mergedTranscript()
        isUserSpeech = true
      }
      // PRIORITY 4: Multimodal text delta from modelTurn (raw append, no segmentation)
      else if let modelTurn = serverContent["modelTurn"] as? [String: Any],
        let parts = modelTurn["parts"] as? [[String: Any]]
      {
        var delta = ""
        for part in parts {
          if let text = part["text"] as? String {
            delta += text
          }
        }
        if !delta.isEmpty {
          committedTranscript += delta
          updatedText = mergedTranscript()
        }
      } else if let outputTranscription = serverContent["outputTranscription"] as? [String: Any],
        let text = outputTranscription["text"] as? String, !text.isEmpty
      {
        committedTranscript += text
        updatedText = mergedTranscript()
      }

      if let newText = updatedText {
        let now = ProcessInfo.processInfo.systemUptime
        self.lastTokenReceivedTime = now
        if self.isCommitting {
          self.lastPostCommitTokenTime = now
          // Round-trip split: commit_to_final_ms is defined as the last
          // transcription message received before settle, so this is overwritten on every
          // post-commit update rather than latched on the first one.
          self.commitToFinalMs = (now - self.turnCommitTime) * 1000.0
          if isFinalTranscription {
            self.lastPostCommitFinalTime = now
          } else if isUserSpeech {
            // A speculative interim after a final means more content is still
            // streaming - the final we saw wasn't the last one.
            self.lastPostCommitFinalTime = nil
          }
          quietRescheduleElapsedSinceCommit = now - self.turnCommitTime
          quietRescheduleIsFinal = isFinalTranscription
        }
        if currentTurnText.isEmpty && firstTokenLatencyMs == 0 && turnCommitTime > 0 {
          firstTokenLatencyMs = (now - turnCommitTime) * 1000.0
        }
        // Separate measurement: how long the service took to produce anything at all,
        // counted from the turn's activityStart rather than from the key release.
        if firstInterimLatencyMs == 0 && turnStartTime > 0 {
          firstInterimLatencyMs = (now - turnStartTime) * 1000.0
        }
        currentTurnText = newText
        let textCopy = currentTurnText
        let elapsedMs = turnCommitTime > 0 ? (now - turnCommitTime) * 1000.0 : 0
        let label = isUserSpeech ? "⚡ DICTATING" : "⚡ STREAMING"
        liveTextUpdate = (
          label: label, elapsedMs: elapsedMs, fullText: currentTurnText, textCopy: textCopy
        )
      }

      // Explicit turn completion / generation completion
      let isTurnComplete =
        (serverContent["turnComplete"] as? Bool) ?? (serverContent["turnComplete"] != nil)
      let isGenComplete =
        (serverContent["generationComplete"] as? Bool)
        ?? (serverContent["generationComplete"] != nil)

      if (isTurnComplete || isGenComplete) && isCommitting && !turnHasAudioGap
        && !hasFiredTurnCompletion
      {
        serverCompletionReceived = true
        commitToTurnCompleteMs = (ProcessInfo.processInfo.systemUptime - turnCommitTime) * 1000.0
      }
      shouldCompleteServerTurn = serverCompletionReceived && commitWritesComplete

    }

    lock.unlock()

    // Logging & callbacks all run off the lock, in the same relative order as before.
    if let trace = usageTrace {
      Log.debug(
        "WS",
        "usageMetadata keys=[\(trace.keys)] prompt=\(trace.prompt.map(String.init) ?? "none") "
          + "response=\(trace.response.map(String.init) ?? "none") "
          + "afterTurnComplete=\(trace.afterTurnComplete) perTurnCounts=\(trace.perTurn)")
    }
    if let msg = serverErrorMessage {
      _ = msg
      connectionFailed(
        epoch: epoch,
        error: NSError(
          domain: "Tok", code: -3,
          userInfo: [NSLocalizedDescriptionKey: "Live API rejected the request."]))
    }
    if sessionContextMismatch {
      // The reason only, never the text. Failing the live turn hands it to the backup
      // route (a pending commit gets this error; a turn still recording stops being
      // committable), and connectionFailed retires the socket that carried the stale text.
      Log.warn(
        "WS",
        "Reused SMART session returned text that does not extend its earlier turns; "
          + "failing the live turn so the backup route transcribes it.")
      connectionFailed(
        epoch: epoch,
        error: NSError(
          domain: "Tok", code: -4,
          userInfo: [
            NSLocalizedDescriptionKey: "Live session mixed in text from an earlier turn."
          ]),
        reason: "context_mismatch")
    }
    if didCompleteSetup {
      pumpWrites()
      // One line per connection, covering both the attempt and its outcome, at the same
      // info level the old two-line (connecting + established) pair used, so a normal
      // (non-verbose) diagnostics log still shows every connect and which model it used.
      Log.info("WS", "Live session ready (\(connectReasonForLog), \(model))")
    }
    if shouldScheduleReconnect {
      Log.warn("WS", "Server sent goAway signal. Preemptively scheduling reconnect...")
      self.scheduleReconnect(epoch: epoch, onlyWhenIdle: true)
    }
    // Callbacks fire before any terminal write: stdout is unbuffered and a slow consumer
    // must never delay the HUD update or the turn's completion. The completion is invoked
    // directly - its only consumer immediately hops onto the app's sessionQueue, so the
    // old DispatchQueue.global() bounce added a scheduling hop for nothing.
    if let update = liveTextUpdate {
      onLiveTextUpdate?(update.textCopy)
      Log.meter(
        "[STREAM] \(update.fullText.count) characters received in \(String(format: "%.0f", update.elapsedMs)) ms"
      )
    }
    if shouldCompleteServerTurn { completeServerTurnIfReady(turn: messageTurn) }
    // A post-commit token arrived: (re)schedule the quiet-window settle check, never
    // earlier than minPostCommitWait after commit. Scheduling happens off-lock; the
    // pointer swap that replaces the previous pending item is its own short lock scope.
    if let elapsedSinceCommit = quietRescheduleElapsedSinceCommit {
      lock.lock()
      let expectedTurn = messageTurn
      let shouldSchedule = turnID == messageTurn && isCommitting && !hasFiredTurnCompletion
      lock.unlock()
      guard shouldSchedule else { return }
      let delay: Double
      if quietRescheduleIsFinal {
        delay = Self.settleFinalGrace + Self.settleTimerCushion
      } else {
        let quiet = usesManualActivity ? Self.settleInterimQuietManual : Self.settleQuietWindow
        delay =
          max(quiet, Self.settleMinPostCommitWait - elapsedSinceCommit) + Self.settleTimerCushion
      }
      let item = DispatchWorkItem { [weak self] in self?.attemptSettle(turn: expectedTurn) }
      lock.lock()
      guard turnID == expectedTurn, isCommitting, !hasFiredTurnCompletion else {
        lock.unlock()
        return
      }
      settleWorkItem?.cancel()
      settleWorkItem = item
      lock.unlock()
      settleQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }
  }

  // MARK: SMART session context

  /// One transcription field of a serverContent payload: the text as sent, and the same
  /// text trimmed. Nil when the field is absent or holds only whitespace.
  private static func transcription(in serverContent: [String: Any], key: String)
    -> (raw: String, trimmed: String)?
  {
    guard let field = serverContent[key] as? [String: Any], let raw = field["text"] as? String
    else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : (raw, trimmed)
  }

  /// Routes one finalized transcription into the open turn. Caller holds `lock`. The
  /// trimmed text decides session context; the accumulator gets the raw text, except on a
  /// reused SMART session, where it gets what remains once earlier turns are removed.
  /// `applied` is true when the turn's transcript took the text. `contextMismatch` is true
  /// when a reused SMART session returned text that does not extend what it had already
  /// committed, so this turn's words cannot be told apart from earlier ones and the caller
  /// must fail the live turn.
  private func consumeFinalTranscriptionLocked(_ finalText: (raw: String, trimmed: String)) -> (
    applied: Bool, contextMismatch: Bool
  ) {
    guard usesSmartSessionContext else {
      applyFinalTranscription(finalText.raw)
      return (true, false)
    }
    // No turn has completed on this connection, so the text is this turn's alone.
    guard !sessionCommittedTranscript.isEmpty else {
      turnLastCumulativeServerFinal = finalText.trimmed
      applySmartFinalTranscriptionLocked(finalText.raw)
      return (true, false)
    }
    // A turn that already failed on this socket takes no more finals, so one mismatch is
    // reported once however many finals follow it.
    guard !turnHasAudioGap else { return (false, false) }
    turnLastCumulativeServerFinal = finalText.trimmed
    guard
      let remainder = Self.strippingSessionPrefix(
        finalText.trimmed, committed: sessionCommittedTranscript)
    else { return (false, true) }
    guard !remainder.isEmpty else {
      // A replay of earlier turns with no new speech. Nothing of it belongs to this turn,
      // and it must not count as this turn's final when the settle rules run.
      currentTurnText = ""
      committedTranscript = ""
      interimTranscript = ""
      lastPostCommitFinalTime = nil
      return (false, false)
    }
    applySmartFinalTranscriptionLocked(remainder)
    return (true, false)
  }

  /// A SMART final within one turn restates the turn so far, and may rewrite the
  /// punctuation where it joins new speech ("Hello world." then "Hello world, next
  /// sentence."). When the new final starts with everything already committed, under the
  /// session-prefix rules, it replaces the turn's text wholesale, which drops no words.
  /// Anything else keeps the ordinary segment rules, since a final that covers only its own
  /// segment would lose earlier speech if it replaced the turn's text. Caller holds `lock`.
  private func applySmartFinalTranscriptionLocked(_ text: String) {
    if !committedTranscript.isEmpty,
      Self.strippingSessionPrefix(text, committed: committedTranscript) != nil
    {
      committedTranscript = text
      interimTranscript = ""
    } else {
      applyFinalTranscription(text)
    }
  }

  /// Punctuation that can end, or be rewritten at, the join between two turns' text.
  private static let sessionBoundaryPunctuation: Set<Character> = [
    ".", "!", "?", ",", ";", ":", "\u{2026}", "\u{0964}",
  ]

  /// Removes the text earlier turns already committed on this session from a cumulative
  /// finalized transcription. Returns what is new (empty when `incoming` only replays
  /// `committed`), or nil when `incoming` does not start with `committed`.
  ///
  /// Runs of whitespace compare as equal, and the punctuation that ended `committed` may
  /// have been rewritten or dropped once more speech followed it. The match has to end at
  /// a word boundary: the end of the text, or optional boundary punctuation followed by
  /// whitespace. A dot followed directly by more text is part of a word, so "Google" does
  /// not match "Google.com".
  static func strippingSessionPrefix(_ incoming: String, committed: String) -> String? {
    let text = Array(incoming.trimmingCharacters(in: .whitespacesAndNewlines))
    var prior = Array(committed.trimmingCharacters(in: .whitespacesAndNewlines))
    while let last = prior.last, last.isWhitespace || sessionBoundaryPunctuation.contains(last) {
      prior.removeLast()
    }
    guard !prior.isEmpty else { return nil }

    var priorIndex = 0
    var index = 0
    while priorIndex < prior.count {
      guard index < text.count else { return nil }
      if prior[priorIndex].isWhitespace {
        guard text[index].isWhitespace else { return nil }
        while priorIndex < prior.count, prior[priorIndex].isWhitespace { priorIndex += 1 }
        while index < text.count, text[index].isWhitespace { index += 1 }
      } else {
        guard prior[priorIndex] == text[index] else { return nil }
        priorIndex += 1
        index += 1
      }
    }

    // Whatever replaced the old terminator, then the boundary itself.
    while index < text.count, sessionBoundaryPunctuation.contains(text[index]) { index += 1 }
    guard index < text.count else { return "" }
    guard text[index].isWhitespace else { return nil }

    // Skip the separator, and any punctuation left standing alone where the old
    // terminator was. Punctuation attached to a word (".swift") belongs to the new text.
    while index < text.count {
      if text[index].isWhitespace {
        index += 1
        continue
      }
      var end = index
      while end < text.count, sessionBoundaryPunctuation.contains(text[end]) { end += 1 }
      guard end > index, end == text.count || text[end].isWhitespace else { break }
      index = end
    }
    return String(text[index...])
  }

  // MARK: Segment transcript accumulator (all three helpers assume `lock` is held)

  private func mergedTranscript() -> String {
    if committedTranscript.isEmpty { return interimTranscript }
    if interimTranscript.isEmpty { return committedTranscript }
    let needsSpace =
      !(committedTranscript.hasSuffix(" ") || committedTranscript.hasSuffix("\n")
      || interimTranscript.hasPrefix(" "))
    return committedTranscript + (needsSpace ? " " : "") + interimTranscript
  }

  private func applyInterimTranscription(_ text: String) {
    // Some server variants stream the interim as the full turn so far. If it already
    // contains everything committed, only the suffix is the live segment - otherwise the
    // interim IS the live segment and replaces only the previous interim.
    if !committedTranscript.isEmpty && text.hasPrefix(committedTranscript) {
      interimTranscript = String(text.dropFirst(committedTranscript.count))
    } else {
      interimTranscript = text
    }
  }

  private func applyFinalTranscription(_ text: String) {
    if committedTranscript.isEmpty {
      committedTranscript = text
    } else if text.hasPrefix(committedTranscript) {
      // Cumulative final covering the whole turn - replace wholesale.
      committedTranscript = text
    } else if committedTranscript.hasSuffix(text) {
      // Duplicate re-send of the segment just committed - nothing new.
    } else {
      // A corrected final can restate the tail of what is already committed while matching
      // neither a prefix nor a suffix, and appending it whole repeats those words. Drop the
      // overlap and append only what is actually new.
      let overlap = Self.transcriptOverlapLength(committed: committedTranscript, incoming: text)
      let addition = String(text.dropFirst(overlap))
      guard !addition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        interimTranscript = ""
        return
      }
      let needsSpace =
        !(committedTranscript.hasSuffix(" ") || committedTranscript.hasSuffix("\n")
        || addition.hasPrefix(" "))
      committedTranscript += (needsSpace ? " " : "") + addition
    }
    interimTranscript = ""
  }

  /// Length, in characters, of the longest tail of `committed` that is also the head of
  /// `incoming`. Only whole-word overlaps count: trimming mid-word would splice two
  /// different words together, which is worse than leaving a repeat. The scan is capped so
  /// a long transcript cannot turn every final into quadratic work.
  static func transcriptOverlapLength(
    committed: String, incoming: String, limit: Int = 200
  ) -> Int {
    let tail = Array(committed.suffix(limit))
    let head = Array(incoming.prefix(limit))
    // Position 0 of the tail only starts a word when the tail is the whole committed text.
    let tailStartsAtWordBoundary = tail.count == committed.count
    var length = min(tail.count, head.count)
    while length > 0 {
      let start = tail.count - length
      if Array(tail.suffix(length)) == Array(head.prefix(length)),
        isWordStart(tail, index: start, includingZero: tailStartsAtWordBoundary),
        isWordEnd(head, index: length)
      {
        return length
      }
      length -= 1
    }
    return 0
  }

  /// True when `index` begins a word: a position right after whitespace, or the start of the
  /// scanned tail when that tail is the whole committed text.
  private static func isWordStart(
    _ characters: [Character], index: Int, includingZero: Bool
  ) -> Bool {
    index == 0 ? includingZero : characters[index - 1].isWhitespace
  }

  /// True when `index` ends a word: the end of the incoming head, a position followed by
  /// whitespace, or a position right after whitespace (the overlap ended with a space).
  private static func isWordEnd(_ characters: [Character], index: Int) -> Bool {
    if index == characters.count { return true }
    return characters[index].isWhitespace || characters[index - 1].isWhitespace
  }

  // Re-validates the settle rules against current authoritative state and, if any rule
  // holds, performs the once-only settle sequence. Safe to call redundantly from a stale
  // or overlapping timer: state (isCommitting/hasFiredTurnCompletion) is the source of
  // truth, not which timer fired.
  func attemptSettle(turn: UInt64) {
    lock.lock()
    guard turn == turnID, isCommitting, commitWritesComplete, !hasFiredTurnCompletion else {
      lock.unlock()
      return
    }

    if turnHasAudioGap {
      let epoch = connectionID
      lock.unlock()
      connectionFailed(
        epoch: epoch,
        error: NSError(
          domain: "Tok", code: -4,
          userInfo: [NSLocalizedDescriptionKey: "Live connection missed part of the recording."]))
      return
    }
    if serverCompletionReceived && !currentTurnText.isEmpty {
      lock.unlock()
      completeServerTurnIfReady(turn: turn)
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    let elapsedCommit = now - commitWritesCompletedAt
    let text = currentTurnText
    let postCommitTokenTime = lastPostCommitTokenTime
    let postCommitFinalTime = lastPostCommitFinalTime

    var settleWithText = false
    var firedRule = ""
    if let finalTime = postCommitFinalTime {
      // An authoritative final transcription landed: settle after only a short grace
      // (long enough for a trailing segment's final to displace this timer), with no
      // minimum-wait floor - waiting longer adds latency, not accuracy.
      settleWithText = !text.isEmpty && (now - finalTime) >= Self.settleFinalGrace
      firedRule = "final_grace"
    } else if let postTime = postCommitTokenTime {
      // Only speculative interims so far. In manual-activity mode a final is expected,
      // so wait longer before pasting speculation; otherwise use the tight quiet window.
      let quietWindow = usesManualActivity ? Self.settleInterimQuietManual : Self.settleQuietWindow
      let quietSincePostToken = now - postTime
      settleWithText =
        elapsedCommit >= Self.settleMinPostCommitWait && !text.isEmpty
        && quietSincePostToken >= quietWindow
      firedRule = "quiet_window"
    } else if !text.isEmpty && elapsedCommit >= Self.settleInitialWaitWithoutTokens {
      settleWithText = true
      firedRule = "initial_wait"
    }

    let timedOut = !settleWithText && elapsedCommit >= Self.settleMaxWait
    guard settleWithText || timedOut else {
      lock.unlock()
      return
    }

    completedUsage = usageSnapshot()
    completedFirstInterimMs = firstInterimLatencyMs > 0 ? firstInterimLatencyMs : nil
    hasFiredTurnCompletion = true
    isCommitting = false
    turnOpen = false
    discardPendingWritesLocked()
    settlePathValue = timedOut ? "timeout" : firedRule
    settleWorkItem?.cancel()
    settleWorkItem = nil
    settleMaxWorkItem?.cancel()
    settleMaxWorkItem = nil

    let totalLatencyMs = (now - turnCommitTime) * 1000.0
    if usesSmartSessionContext, !text.isEmpty, let cumulative = turnLastCumulativeServerFinal {
      sessionCommittedTranscript = cumulative
    }
    currentTurnText = ""
    committedTranscript = ""
    interimTranscript = ""
    let firstToken = firstTokenLatencyMs
    firstTokenLatencyMs = 0
    firstInterimLatencyMs = 0
    let cb = turnCompletion
    turnCompletion = nil
    let settledEpoch = connectionID
    lock.unlock()

    // A heuristic finish has no server boundary. Retire its socket before another turn
    // can accept delayed words from this one. Tagged as a planned reset, not a recovery.
    // The epoch makes connect() drop the reset if a disconnect() or the key-rejection stop
    // landed after the unlock, or another connect already replaced this socket.
    connect(expectedConnection: settledEpoch, reason: "turn_reset")

    // Completion before the terminal write, and directly on settleQueue - the consumer
    // re-dispatches onto sessionQueue itself, so the extra global-queue hop bought nothing.
    if !text.isEmpty {
      cb?(.success((text: text, firstTokenMs: firstToken, totalMs: totalLatencyMs)))
    } else {
      cb?(
        .failure(
          NSError(
            domain: "Tok", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "No speech recognized before timeout."])))
    }
    Log.endMeter()
  }

  func startNewTurn() {
    lock.lock()
    let abandoned = turnOpen
    lock.unlock()
    if abandoned { abandonTurn() }
    // A SMART session an earlier turn used (its audio reached the socket, or a final came
    // back) can restate that turn's text in this turn's transcript, even when the earlier
    // turn settled on interim text alone, so the turn starts on a new connection instead.
    // The turn is not open yet: nothing is flagged as an audio gap, and activityStart and
    // the audio queue until the handshake completes. Passing the epoch makes connect()
    // repeat this check under its own lock, so a disconnect() or the key-rejection stop
    // landing in between is never undone.
    lock.lock()
    let sessionEpoch = connectionID
    let resetSession = usesSmartSessionContext && sessionUsedBySmartTurn && reconnectEnabled
    lock.unlock()
    if resetSession { connect(expectedConnection: sessionEpoch, reason: "turn_reset") }
    lock.lock()
    let rotatedAtStart = resetSession && connectionID != sessionEpoch
    turnID &+= 1
    turnOpen = true
    discardPendingWritesLocked()
    turnHasAudioGap = false
    turnSentAnyMessage = false
    turnWrites = DispatchGroup()
    self.settleWorkItem?.cancel()
    self.settleWorkItem = nil
    self.settleMaxWorkItem?.cancel()
    self.settleMaxWorkItem = nil
    self.isCommitting = false
    commitWritesComplete = false
    serverCompletionReceived = false
    self.settlePathValue = nil
    self.currentTurnText = ""
    self.committedTranscript = ""
    self.interimTranscript = ""
    self.firstTokenLatencyMs = 0
    self.firstInterimLatencyMs = 0
    self.completedFirstInterimMs = nil
    self.turnStartTime = ProcessInfo.processInfo.systemUptime
    self.hasFiredTurnCompletion = false
    self.turnCommitTime = 0
    self.lastTokenReceivedTime = 0
    self.lastPostCommitTokenTime = nil
    self.lastPostCommitFinalTime = nil
    self.turnCompletion = nil
    self.completedUsage = nil
    // connect() only flags a change while a turn is open, and this one opened just after.
    self.turnConnectionChanged = rotatedAtStart
    self.turnLastCumulativeServerFinal = nil
    self.commitToLastSendMs = nil
    self.commitToFirstMsgMs = nil
    self.commitToFinalMs = nil
    self.commitToTurnCompleteMs = nil
    if usageCountsArePerTurn {
      // Per-turn counts do not carry over. Clearing them means a turn the server reports
      // no usage for records none instead of repeating the previous turn's numbers.
      self.lastSeenPromptTokens = 0
      self.lastSeenResponseTokens = 0
    }
    self.turnBaselinePromptTokens = self.lastSeenPromptTokens
    self.turnBaselineResponseTokens = self.lastSeenResponseTokens
    lock.unlock()

    // Dispatch manual activityStart: the key press IS the start of speech whenever
    // server VAD is disabled (conversational models always; transcribe in manual mode)
    if usesManualActivity {
      let startPayload: [String: Any] = [
        "realtimeInput": [
          "activityStart": [:]
        ]
      ]
      if let startJson = try? JSONSerialization.data(withJSONObject: startPayload),
        let startStr = String(data: startJson, encoding: .utf8)
      {
        sendTurnMessage(startStr)
      }
    }
  }

  // Base64's alphabet (A-Za-z0-9+/=) needs no JSON escaping, so the fixed-shape
  // envelope is built once and the payload is spliced in directly, skipping
  // JSONSerialization on the hot per-chunk (CHUNK_MS, ~100ms) path. The Live API
  // documents raw 16-bit 16 kHz PCM as its only input format, so live audio stays
  // uncompressed (decision record: adhishthite/tok#17).
  private static let audioChunkJSONPrefix =
    "{\"realtimeInput\":{\"audio\":{\"mimeType\":\"audio/pcm;rate=16000\",\"data\":\""
  private static let audioChunkJSONSuffix = "\"}}}"

  // Reservations include the in-flight write. Invalidating a turn releases them once;
  // late transport callbacks cannot release reservations belonging to the next turn.
  private func discardPendingWritesLocked() {
    writeDeadline?.cancel()
    writeDeadline = nil
    for write in pendingWrites { write.writes.leave() }
    pendingWrites.removeAll(keepingCapacity: true)
    pendingWriteBytes = 0
    writeInFlight = false
  }

  private func armWriteDeadlineLocked() {
    writeDeadline?.cancel()
    guard let first = pendingWrites.first else {
      writeDeadline = nil
      return
    }
    let turn = turnID
    let id = first.id
    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      guard self.turnID == turn, self.pendingWrites.first?.id == id else {
        self.lock.unlock()
        return
      }
      self.turnHasAudioGap = true
      self.discardPendingWritesLocked()
      let epoch = self.connectionID
      self.lock.unlock()
      self.connectionFailed(epoch: epoch, error: Self.writeBacklogError())
    }
    writeDeadline = item
    let remaining = max(
      0, first.admittedAt + Self.maxPendingWriteAge - ProcessInfo.processInfo.systemUptime)
    sendQueue.asyncAfter(deadline: .now() + remaining, execute: item)
  }

  private static func writeBacklogError() -> NSError {
    NSError(
      domain: "Tok", code: -4,
      userInfo: [NSLocalizedDescriptionKey: "Live audio delivery exceeded its queue budget."])
  }

  func sendTurnMessage(_ text: String) {
    lock.lock()
    guard turnOpen, !turnHasAudioGap else {
      lock.unlock()
      return
    }
    let now = ProcessInfo.processInfo.systemUptime
    if text.utf8.count > Self.maxPendingWriteBytes - pendingWriteBytes
      || pendingWrites.first.map({ now - $0.admittedAt >= Self.maxPendingWriteAge }) == true
    {
      turnHasAudioGap = true
      discardPendingWritesLocked()
      let epoch = connectionID
      lock.unlock()
      connectionFailed(epoch: epoch, error: Self.writeBacklogError())
      return
    }
    nextWriteID &+= 1
    turnWrites.enter()
    pendingWrites.append(
      PendingWrite(id: nextWriteID, text: text, admittedAt: now, writes: turnWrites))
    pendingWriteBytes += text.utf8.count
    if pendingWrites.count == 1 { armWriteDeadlineLocked() }
    lock.unlock()
    pumpWrites()
  }

  private func pumpWrites() {
    sendQueue.async { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      guard self.readyState, self.turnOpen, !self.turnHasAudioGap,
        !self.writeInFlight, let write = self.pendingWrites.first,
        let task = self.webSocketTask
      else {
        self.lock.unlock()
        return
      }
      self.writeInFlight = true
      self.turnSentAnyMessage = true
      // This turn's audio is about to reach the session, so in SMART mode the server may
      // keep its text whether or not a final ever arrives. The next turn starts on a new
      // connection unless this one has already been replaced.
      if self.usesSmartSessionContext { self.sessionUsedBySmartTurn = true }
      let epoch = self.connectionID
      let turn = self.turnID
      self.lock.unlock()
      self.writeTransport(task, write.text) { [weak self] error in
        guard let self = self else { return }
        self.lock.lock()
        guard self.turnID == turn, self.connectionID == epoch,
          self.pendingWrites.first?.id == write.id
        else {
          self.lock.unlock()
          return
        }
        if let error = error {
          self.turnHasAudioGap = true
          self.discardPendingWritesLocked()
          self.lock.unlock()
          self.connectionFailed(epoch: epoch, error: error)
          return
        }
        self.pendingWrites.removeFirst()
        self.pendingWriteBytes -= write.text.utf8.count
        self.writeInFlight = false
        write.writes.leave()
        self.armWriteDeadlineLocked()
        self.lock.unlock()
        self.pumpWrites()
      }
    }
  }

  static func audioChunkFrame(_ pcmChunk: Data) -> String {
    audioChunkJSONPrefix + pcmChunk.base64EncodedString() + audioChunkJSONSuffix
  }

  func sendAudioChunk(_ pcmChunk: Data) {
    sendTurnMessage(Self.audioChunkFrame(pcmChunk))
  }

  func commitTurn(
    completion:
      @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void
  ) {
    lock.lock()
    let writes = turnWrites
    let expectedTurn = turnID
    lock.unlock()
    writes.notify(queue: sendQueue) { [weak self] in
      self?.beginCommit(turn: expectedTurn, completion: completion)
    }
  }

  func beginCommit(
    turn expectedTurn: UInt64,
    completion:
      @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void
  ) {
    lock.lock()
    guard expectedTurn == turnID, turnOpen, readyState, !turnHasAudioGap else {
      lock.unlock()
      completion(
        .failure(
          NSError(
            domain: "Tok", code: -4,
            userInfo: [NSLocalizedDescriptionKey: "Live connection missed part of the recording."]))
      )
      return
    }
    self.turnCommitTime = ProcessInfo.processInfo.systemUptime
    self.isCommitting = true
    commitWritesComplete = false
    serverCompletionReceived = false
    self.lastPostCommitTokenTime = nil
    self.lastPostCommitFinalTime = nil
    self.turnCompletion = completion
    self.hasFiredTurnCompletion = false
    lock.unlock()

    // End-of-turn signaling. Legacy (shipped) behavior sends all three of audioStreamEnd,
    // activityEnd and clientContent.turnComplete. The dedicated transcribe docs show only
    // ONE terminator per VAD mode (manual -> activityEnd; auto/tuned -> audioStreamEnd)
    // and never clientContent.turnComplete - WS_ENDPOINT_ALIGNED opts into that shape for
    // A/B testing. Conversational models are never aligned: clientContent.turnComplete is
    // what triggers their generation.
    let aligned = endpointAligned && model.contains("transcribe")

    // 1. audioStreamEnd flushes the audio encoder pipeline (aligned manual mode omits it:
    // the docs' manual recipe ends with activityEnd alone).
    if !(aligned && usesManualActivity) {
      let endAudioPayload: [String: Any] = [
        "realtimeInput": [
          "audioStreamEnd": true
        ]
      ]
      if let endAudioJson = try? JSONSerialization.data(withJSONObject: endAudioPayload),
        let endAudioStr = String(data: endAudioJson, encoding: .utf8)
      {
        sendTurnMessage(endAudioStr)
      }
    }

    // 2. Dispatch manual activityEnd: the key release IS the end of speech whenever
    // server VAD is disabled (in legacy mode after audioStreamEnd, so all buffered audio
    // lands inside the activity window)
    if usesManualActivity {
      let endPayload: [String: Any] = [
        "realtimeInput": [
          "activityEnd": [:]
        ]
      ]
      if let endJson = try? JSONSerialization.data(withJSONObject: endPayload),
        let endStr = String(data: endJson, encoding: .utf8)
      {
        sendTurnMessage(endStr)
      }
    }

    // 3. Dispatch turnComplete signal to finalize transcript (legacy only). NOTE for the
    // A/B: the server may currently be echoing turnComplete back, which settles the turn
    // immediately in handleIncomingMessage - aligned mode shifts settlement onto the
    // attemptSettle timers, so compare latency in BOTH directions before adopting.
    if !aligned {
      let commitPayload: [String: Any] = [
        "clientContent": [
          "turnComplete": true
        ]
      ]

      guard let jsonData = try? JSONSerialization.data(withJSONObject: commitPayload),
        let jsonString = String(data: jsonData, encoding: .utf8)
      else {
        completion(
          .failure(
            NSError(
              domain: "Tok", code: -1,
              userInfo: [NSLocalizedDescriptionKey: "Failed to serialize commit payload."])))
        return
      }

      sendTurnMessage(jsonString)
    }

    lock.lock()
    let terminalWrites = turnWrites
    lock.unlock()
    terminalWrites.notify(queue: sendQueue) { [weak self] in
      self?.finishCommitWrites(turn: expectedTurn)
    }
  }

  private func finishCommitWrites(turn expectedTurn: UInt64) {
    lock.lock()
    guard turnID == expectedTurn, isCommitting, !hasFiredTurnCompletion,
      !turnHasAudioGap, readyState
    else {
      lock.unlock()
      return
    }
    commitWritesComplete = true
    commitWritesCompletedAt = ProcessInfo.processInfo.systemUptime
    // Round-trip split: the last audio frame and end-of-turn signals are on the
    // wire once every write this commit queued has been acknowledged by its completion
    // handler (or, for the manual/aligned path with no separate terminal message, once the
    // audio itself has drained) - exactly the instant this notify fires.
    commitToLastSendMs = (commitWritesCompletedAt - turnCommitTime) * 1000.0
    var initialDelay = Self.settleInitialWaitWithoutTokens
    if let final = lastPostCommitFinalTime {
      initialDelay = max(0, Self.settleFinalGrace - (commitWritesCompletedAt - final))
    } else if let token = lastPostCommitTokenTime {
      let quiet = usesManualActivity ? Self.settleInterimQuietManual : Self.settleQuietWindow
      initialDelay = max(Self.settleMinPostCommitWait, quiet - (commitWritesCompletedAt - token))
    }
    let initialItem = DispatchWorkItem { [weak self] in self?.attemptSettle(turn: expectedTurn) }
    let maxItem = DispatchWorkItem { [weak self] in self?.attemptSettle(turn: expectedTurn) }
    if model.contains("transcribe") {
      settleWorkItem?.cancel()
      settleMaxWorkItem?.cancel()
      settleWorkItem = initialItem
      settleMaxWorkItem = maxItem
    }
    lock.unlock()
    // Preserve finals and server completion received before the send callbacks drained.
    completeServerTurnIfReady(turn: expectedTurn)
    if model.contains("transcribe") {
      attemptSettle(turn: expectedTurn)
      settleQueue.asyncAfter(
        deadline: .now() + initialDelay + Self.settleTimerCushion, execute: initialItem)
      settleQueue.asyncAfter(
        deadline: .now() + Self.settleMaxWait + Self.settleTimerCushion, execute: maxItem)
    }
  }

  private func completeServerTurnIfReady(turn expectedTurn: UInt64) {
    lock.lock()
    guard turnID == expectedTurn, isCommitting, commitWritesComplete, serverCompletionReceived,
      !turnHasAudioGap, !currentTurnText.isEmpty, !hasFiredTurnCompletion
    else {
      lock.unlock()
      return
    }
    turnOpen = false
    completedUsage = usageSnapshot()
    completedFirstInterimMs = firstInterimLatencyMs > 0 ? firstInterimLatencyMs : nil
    hasFiredTurnCompletion = true
    isCommitting = false
    settlePathValue = "server_turn_complete"
    settleWorkItem?.cancel()
    settleWorkItem = nil
    settleMaxWorkItem?.cancel()
    settleMaxWorkItem = nil
    let elapsed = (ProcessInfo.processInfo.systemUptime - turnCommitTime) * 1000
    let text = currentTurnText
    if usesSmartSessionContext, let cumulative = turnLastCumulativeServerFinal {
      sessionCommittedTranscript = cumulative
    }
    currentTurnText = ""
    committedTranscript = ""
    interimTranscript = ""
    let first = firstTokenLatencyMs
    firstTokenLatencyMs = 0
    firstInterimLatencyMs = 0
    let callback = turnCompletion
    turnCompletion = nil
    let rotate = rotateWhenIdle
    let resetSession = usesSmartSessionContext && reconnectEnabled
    let epoch = connectionID
    lock.unlock()
    callback?(.success((text: text, firstTokenMs: first, totalMs: elapsed)))
    if resetSession {
      // The session now holds this turn's text, and only a new connection clears it. The
      // swap runs after the completion, off the paste path, and gives way to a turn that
      // is already open: connect() then leaves rotateWhenIdle set for that turn's end.
      settleQueue.async { [weak self] in
        self?.connect(onlyWhenIdle: true, expectedConnection: epoch, reason: "turn_reset")
      }
    } else if rotate {
      scheduleReconnect(epoch: epoch, onlyWhenIdle: true)
    }
    Log.endMeter()
  }

  var hasReceivedTokens: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !currentTurnText.isEmpty || firstTokenLatencyMs > 0
  }

  /// Sessions are capped at ten minutes by the service. Replacing an idle session at
  /// eight minutes means a turn never starts with only seconds left. A turn in progress
  /// defers the swap until it completes. Caller holds `lock`.
  private func scheduleSessionRotationLocked(epoch: UInt64) {
    sessionRotationWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.lock.lock()
      let current = self.connectionID == epoch && self.reconnectEnabled
      self.sessionRotationWorkItem = nil
      self.lock.unlock()
      guard current else { return }
      self.scheduleReconnect(epoch: epoch, onlyWhenIdle: true, reason: "rotation")
    }
    sessionRotationWorkItem = item
    settleQueue.asyncAfter(deadline: .now() + Self.sessionRotationSeconds, execute: item)
  }

  /// Arms the next idle keepalive ping. Caller holds `lock`.
  private func scheduleKeepaliveLocked(epoch: UInt64) {
    keepaliveWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in self?.sendKeepalivePing(epoch: epoch) }
    keepaliveWorkItem = item
    settleQueue.asyncAfter(deadline: .now() + Self.keepaliveIntervalSeconds, execute: item)
  }

  private func sendKeepalivePing(epoch: UInt64) {
    lock.lock()
    keepaliveWorkItem = nil
    guard epoch == connectionID, reconnectEnabled, readyState, let task = webSocketTask else {
      lock.unlock()
      return
    }
    // A turn in progress is its own proof of life, and an extra frame on that path buys
    // nothing. The timer is re-armed either way.
    let idle = !turnOpen && !isCommitting
    // Snapshotted under the lock we already hold, not a new one: this ping only ever
    // fires while idle (the guard below), so the failure line can say so plainly.
    let socketAgeSeconds = ProcessInfo.processInfo.systemUptime - sessionEstablishedAt
    scheduleKeepaliveLocked(epoch: epoch)
    lock.unlock()
    guard idle else { return }
    task.sendPing { [weak self] error in
      guard let self, let error else { return }
      // A failed ping means the socket is gone. Take the same path a receive error takes.
      Log.warn(
        "WS",
        "Keepalive ping failed; treating the live connection as lost (idle, socket age "
          + "\(String(format: "%.0f", socketAgeSeconds))s).")
      self.connectionFailed(epoch: epoch, error: error, reason: "keepalive")
    }
  }

  private func scheduleReconnect(
    epoch: UInt64, onlyWhenIdle: Bool = false, reason: String = "reconnect"
  ) {
    lock.lock()
    guard epoch == connectionID, reconnectEnabled, reconnectWorkItem == nil else {
      lock.unlock()
      return
    }
    reconnectAttempts += 1
    let delay = min(10.0, pow(2.0, Double(min(reconnectAttempts, 4))))
    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      let current = self.connectionID == epoch && self.reconnectEnabled
      self.reconnectWorkItem = nil
      self.lock.unlock()
      if current {
        self.connect(onlyWhenIdle: onlyWhenIdle, expectedConnection: epoch, reason: reason)
      }
    }
    reconnectWorkItem = item
    lock.unlock()
    settleQueue.asyncAfter(deadline: .now() + delay, execute: item)
  }

  func abandonTurn() {
    lock.lock()
    // Replace the socket only when this turn could have left it unusable: something of the
    // turn reached it, a SMART turn already used the session, a goAway asked for a swap, or
    // the socket failed and is waiting out a reconnect backoff. A turn that only queued
    // writes behind a clean handshake (the usual case right after a session reset) leaves
    // that handshake alone instead of cancelling it and starting over.
    let needsRotation =
      turnOpen
      && (turnSentAnyMessage || sessionUsedBySmartTurn || rotateWhenIdle
        || reconnectWorkItem != nil)
    turnOpen = false
    discardPendingWritesLocked()
    turnCompletion = nil
    isCommitting = false
    hasFiredTurnCompletion = true
    settleWorkItem?.cancel()
    settleMaxWorkItem?.cancel()
    let epoch = connectionID
    lock.unlock()
    // A planned reset, bound to this epoch: it never restarts a client that disconnect() or
    // the key-rejection stop turned off, and leaves the rejection streak alone.
    if needsRotation { connect(expectedConnection: epoch, reason: "turn_reset") }
  }

  func disconnect() {
    lock.lock()
    connectionID &+= 1
    let hadConnection = webSocketTask != nil
    let socketAgeS =
      sessionEstablishedAt > 0 ? ProcessInfo.processInfo.systemUptime - sessionEstablishedAt : nil
    let turnOpenAtDisconnect = turnOpen
    turnConnectionChanged = true
    reconnectEnabled = false
    sessionRotationWorkItem?.cancel()
    sessionRotationWorkItem = nil
    sessionEstablishedAt = 0
    reconnectWorkItem?.cancel()
    reconnectWorkItem = nil
    keepaliveWorkItem?.cancel()
    keepaliveWorkItem = nil
    settleWorkItem?.cancel()
    settleWorkItem = nil
    settleMaxWorkItem?.cancel()
    settleMaxWorkItem = nil
    let task = webSocketTask
    webSocketTask = nil
    connectedState = false
    readyState = false
    resetSessionContextLocked()
    if turnOpen { turnHasAudioGap = true }
    discardPendingWritesLocked()
    let completion = turnCompletion
    turnCompletion = nil
    isCommitting = false
    lock.unlock()
    task?.cancel(with: .normalClosure, reason: nil)
    if hadConnection { onConnectionEvent?("closed_by_client", turnOpenAtDisconnect, socketAgeS) }
    completion?(
      .failure(
        NSError(
          domain: "Tok", code: -4,
          userInfo: [NSLocalizedDescriptionKey: "Live connection closed."])))
  }
  func shutdown() {
    disconnect()
    urlSession.invalidateAndCancel()
  }

}
