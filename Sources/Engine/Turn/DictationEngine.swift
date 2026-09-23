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
  // Settings that DictationStore swaps in without an engine restart (audit F30). The
  // struct is replaced whole under hotLock and read as a snapshot on whichever queue
  // needs it, so a mid-turn change applies from the next read without a data race.
  private let hotLock = NSLock()
  private var hotSettings: HotSettings
  var hot: HotSettings {
    hotLock.lock()
    defer { hotLock.unlock() }
    return hotSettings
  }
  let audioCapture: AudioCaptureEngine
  private var liveClient: GeminiLiveClient?
  private var hotkeyManager: HotkeyManager?
  let history: HistoryStore?
  private var correctionWatcher: CorrectionWatcher?
  // Optional upgrade (see Engine/Judgment). Always present; a no-op gate until a TypeSafe
  // key is configured and its models probe succeeds.
  let judgmentService: JudgmentService

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
  // captureGeneration snapshotted on main in handleKeyUp and read on sessionQueue when the
  // turn's feedback is emitted, the same way turnFinishMode is. Reading captureGeneration
  // itself from sessionQueue would break its main-thread-only rule (audit F33).
  private var turnFeedbackGeneration: UInt64 = 0
  // Main-thread-only: true once the missing-microphone-permission refusal has been logged,
  // so holding the shortcut does not repeat the same error line (audit F16).
  private var loggedMicrophoneDenied = false
  // Main-thread-only: workspace sleep/wake observer tokens, removed in stop() (audit F33).
  private var powerObservers: [NSObjectProtocol] = []

  // Main-thread-only hold-to-lock state. turnLocked: the hold outlasted HOLD_TO_LOCK, so
  // the physical release is a non-event and the NEXT key-down finishes the turn.
  // lockWorkItem fires the lock; lockLimitWorkItem finishes a locked turn nobody came back
  // for. Any key-up that really finishes the turn cancels both, and the lock item re-checks
  // captureActive so a release a few ms before it fires can never lock a turn that ended.
  private var turnLocked: Bool = false
  private var lockWorkItem: DispatchWorkItem?
  private var lockLimitWorkItem: DispatchWorkItem?
  private var sessionLimitWorkItem: DispatchWorkItem?
  // Main-thread-only: the deferred "Getting ready" pill (audit F10) and the instant of the
  // last key-up that really finished a turn, which separates a double-tap bounce from a
  // deliberate cancel press (audit F11).
  private var startingNoticeWorkItem: DispatchWorkItem?
  private var lastKeyUpTime: TimeInterval = 0
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
  // First-word evidence (audit F13). turnKeyDownTime and turnCaptureStartMs are written on
  // main (key-down, then beginCapture) and read on sessionQueue like turnFinishMode;
  // turnFirstInterimMs is sessionQueue-only, read from the live client at settle.
  private var turnKeyDownTime: TimeInterval = 0
  private var turnCaptureStartMs: Double?
  private var turnFirstInterimMs: Double?
  // sessionQueue-only: the clip length of the turn now in flight, so a cancel can stamp
  // the audio it already paid for on the history row (audit F11).
  private var turnAudioSeconds: Double?

  // Item AB: self-describing rows and key-down readiness. Same cross-thread discipline as
  // the first-word evidence above - written on main, read on sessionQueue via recordTurn's
  // central fallback-fill, except turnOnsetDb (sessionQueue-only, like turnPeakDb) and
  // lastCaptureEndUptime (written on sessionQueue right after stopRecording, read on main at
  // the next key-down; captureTimingLock is the same snapshot-then-release idiom
  // processingLock already uses for isProcessing across this exact thread boundary).
  private var turnKeyDownEpoch: Double?
  private var turnKeyUpEpoch: Double?
  private var turnMicStateAtKeydown: String?
  private var turnStartingNoticeShown: Bool = false
  private var turnPrerollMsUsed: Double?
  private var turnMsSincePrevCapture: Double?
  private var turnOnsetDb: Double?
  private let captureTimingLock = NSLock()
  private var lastCaptureEndUptime: TimeInterval?

  // sessionQueue-only. Snapshots the instant a capture finished (any outcome) and this
  // turn's onset_db, right after stopRecording returns. Call once per stopRecording call.
  private func noteCaptureFinished() {
    captureTimingLock.lock()
    lastCaptureEndUptime = ProcessInfo.processInfo.systemUptime
    captureTimingLock.unlock()
    turnOnsetDb = audioCapture.onsetDbInTurn
  }

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
  // sessionQueue-only: the "still working" notice for a turn that outlives the first beat.
  private var pendingProgressNotice: DispatchWorkItem?
  // sessionQueue-only per-route terminal state for the current turn, reset when the turn id
  // increments (audit F21). A failed REST hedge must not end a turn whose live commit is
  // still in flight, so the arbiter needs to know which routes can still answer.
  var wsCommitInFlight = false
  var wsTerminal = false
  var restTerminal = false
  var lastRestError: Error?
  // sessionQueue-only. turnHasResult: a transcript reached settle(), so a cancel from here
  // on must not destroy it. turnCopyOnlyRequested: Escape arrived after that point, so the
  // text goes to the clipboard instead of the destination (review of PR 7).
  private var turnHasResult = false
  private var turnCopyOnlyRequested = false
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
    self.hotSettings = HotSettings(config)
    self.audioCapture = AudioCaptureEngine(
      preRollMs: config.preRollMs, chunkMs: config.chunkMs, silenceFlushMs: config.silenceFlushMs,
      inputDevice: config.inputDevice)
    if config.enableLiveWebSocket && !config.geminiApiKey.isEmpty {
      self.liveClient = GeminiLiveClient(
        apiKey: config.geminiApiKey,
        model: config.geminiLiveModel,
        smartTranscription: config.smartTranscription,
        languageCodes: config.languageCodes,
        customVocabulary: config.recognitionVocabulary,
        vadMode: config.vadMode,
        vadSilenceMs: config.vadSilenceMs,
        endpointAligned: config.wsEndpointAligned
      )
    }
    self.history = config.historyEnabled ? HistoryStore(config: config) : nil
    self.judgmentService = JudgmentService(apiKey: config.typesafeApiKey)
    // A failed history write is otherwise only a log line; Settings shows this (audit F29).
    // onError arrives on the history queue, so the hop to main is this wiring's job.
    // (judgmentService must be assigned before this point: every stored property needs a
    // value before `self` can be captured, even weakly, in a closure.)
    history?.onError = { [weak self] message in
      DispatchQueue.main.async { self?.delegate?.engineDidEmit(.historyError(message)) }
    }
    // Forwards every availability transition through the same delegate every other engine
    // event uses; engineDidEmit hops to main itself, so no extra dispatch is needed here.
    // The callback fires on judgmentService.queue, never while its lock is held.
    self.judgmentService.onAvailabilityChange = { [weak self] availability in
      self?.delegate?.engineDidEmit(.judgmentAvailability(availability))
    }
    if config.learnCorrections {
      if config.historyEnabled {
        self.correctionWatcher = CorrectionWatcher(
          config: config, history: self.history, judgment: self.judgmentService)
      } else {
        // Without history there is nowhere to store a correction, so the watcher would
        // read the destination window over Accessibility for nothing (audit F33).
        Log.warn(
          "LEARN",
          "LEARN_CORRECTIONS is on but HISTORY=false - corrections are not observed. Turn History on to collect them for `make analyze`."
        )
      }
    }
  }

  public func start() {
    SoundManager.prepare()
    if config.customVocabularyDropped > 0 {
      Log.warn(
        "VOCAB",
        "\(config.customVocabularyDropped) vocabulary terms beyond the \(EngineConfiguration.vocabularyLimit)-term limit were not sent. Recognition works best near \(EngineConfiguration.vocabularyRecommended) terms."
      )
    } else if config.recognitionVocabulary.count > EngineConfiguration.vocabularyRecommended {
      Log.info(
        "VOCAB",
        "\(config.recognitionVocabulary.count) vocabulary terms sent. Recognition works best near \(EngineConfiguration.vocabularyRecommended) terms."
      )
    }
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
      // A key the service keeps refusing stops the live route; say so once instead of
      // leaving every turn to the backup route in silence.
      liveClient?.onAuthRejected = { [weak self] in
        DispatchQueue.main.async {
          self?.feedback.showError(message: "API key rejected. Check the key in Settings.")
        }
      }
      liveClient?.connect(reason: "startup")
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

    // The tap's run loop source is added on the main run loop, so these arrive on main
    // like onKeyDown and onKeyUp do.
    hotkey.onChord = { [weak self] in
      self?.handleChord()
    }

    hotkey.onCancelKey = { [weak self] in
      self?.handleCancel(source: "escape")
    }

    // Sleep/wake hygiene: release the mic before sleep (suspendEngine refuses mid-dictation),
    // and force a fresh WS connection on wake - the socket often survives sleep in a
    // half-dead state where sends succeed but no server responses ever arrive.
    // The tokens are kept so stop() can remove them: a settings change restarts the engine,
    // and an un-removed observer would fire once per past start (audit F33).
    powerObservers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.audioCapture.suspendEngine()
        Log.info("POWER", "System sleeping - mic released.")
      })
    powerObservers.append(
      NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
      ) { [weak self] _ in
        guard let self = self else { return }
        Log.info("POWER", "System woke - refreshing Live WebSocket connection.")
        if self.config.enableLiveWebSocket {
          self.liveClient?.disconnect()
          self.liveClient?.connect(reason: "wake")
        }
      })

    guard hotkey.start() else {
      Log.error(
        "HOTKEY",
        "Could not detect the shortcut. Enable Input Monitoring and Accessibility for Tok."
      )
      feedback.showError(message: "Enable Input Monitoring and Accessibility for Tok.")
      return
    }
    self.hotkeyManager = hotkey

    // The judgment probe (kicked off in init) may already have settled before a delegate
    // existed to hear about it, so push the current snapshot once at startup rather than
    // relying only on the next transition (otherwise the store shows a stale `.off`).
    delegate?.engineDidEmit(.judgmentAvailability(judgmentService.availability))
    feedback.ready()
  }

  /// Replaces the hot-applied settings from a fresh configuration. Main thread. Keys whose
  /// consumers read `hot` (or the HUD, which the store updates itself) are marked
  /// `restartsEngine: false` in SettingCatalog; every other key still rebuilds the engine.
  public func applyHotSettings(from configuration: EngineConfiguration) {
    hotLock.lock()
    hotSettings = HotSettings(configuration)
    hotLock.unlock()
    // Rebuilds the TypeSafe client and reruns its probe immediately when the key differs,
    // without waiting for a full engine restart (a key edit while a turn is active is
    // debounced and may not restart the engine right away).
    judgmentService.configure(apiKey: configuration.typesafeApiKey)
    Log.configure(
      delegate: delegate, apiKey: config.geminiApiKey, privacyMode: configuration.privacyMode)
  }

  private func recordTurn(_ record: TurnRecord) {
    // Every row gets the turn's first-word evidence, whatever path built it.
    var stamped = record
    if stamped.captureStartMs == nil { stamped.captureStartMs = turnCaptureStartMs }
    if stamped.firstInterimMs == nil { stamped.firstInterimMs = turnFirstInterimMs }
    // Key timing, capture settings, and key-down readiness, filled the same way.
    if stamped.keyDownEpoch == nil { stamped.keyDownEpoch = turnKeyDownEpoch }
    if stamped.keyUpEpoch == nil { stamped.keyUpEpoch = turnKeyUpEpoch }
    if stamped.experimentTag == nil { stamped.experimentTag = hot.experimentTag }
    if stamped.micStateAtKeydown == nil { stamped.micStateAtKeydown = turnMicStateAtKeydown }
    if stamped.msSincePrevCapture == nil { stamped.msSincePrevCapture = turnMsSincePrevCapture }
    if stamped.prerollMsUsed == nil { stamped.prerollMsUsed = turnPrerollMsUsed }
    if stamped.startingNoticeShown == nil { stamped.startingNoticeShown = turnStartingNoticeShown }
    if stamped.onsetDb == nil { stamped.onsetDb = turnOnsetDb }
    // Item 3: a delivered (pasted or copy-only), non-empty transcript gets a fire-and-forget
    // Jev quality judgment once history has assigned it a rowid. Respects PRIVACY_MODE the
    // same way history already does (no extra gating: history keeps recording under privacy
    // mode today, so this does too); with history disabled there is nothing to key the
    // judgment to, so it is skipped entirely.
    if let history, judgmentService.isAvailable, stamped.outcome == "success",
      let text = stamped.text, !text.isEmpty
    {
      let appName = stamped.appName
      let appBundleId = stamped.appBundleId
      history.record(stamped) { [weak judgmentService] rowid in
        guard let judgmentService else { return }
        TranscriptQualityJudge.assess(
          rowid: rowid, transcript: text, appName: appName, appBundleId: appBundleId,
          judgment: judgmentService, history: history)
      }
    } else {
      history?.record(stamped)
    }
    delegate?.engineDidEmit(.turnSettled(stamped))
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
    startingNoticeWorkItem?.cancel()
    startingNoticeWorkItem = nil
    correctionWatcher?.cancelPending()
    for token in powerObservers { NSWorkspace.shared.notificationCenter.removeObserver(token) }
    powerObservers.removeAll()
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
      self.pendingProgressNotice?.cancel()
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
    let busy = isProcessing
    processingLock.unlock()
    if busy {
      // A press inside the bounce window is the tail of the gesture that just ended: the
      // post-roll drain is still running and the turn deserves to finish. A later press is
      // the user asking to stop a turn that is waiting on the network (audit F11).
      if ProcessInfo.processInfo.systemUptime - lastKeyUpTime < Self.cancelPressGraceSec {
        feedback.showBusy()
      } else {
        handleCancel(source: "press")
      }
      return
    }
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
      if hot.soundFeedback {
        SoundManager.playErrorSound()
      }
      feedback.showError(message: "Secure input active. Dictation blocked.")
      return
    }

    // Microphone permission can be revoked while Tok runs. Refuse the turn at the shortcut
    // and name the fix, instead of recording silence until the third no-speech turn names
    // it (audit F16). The 3-turn heuristic still covers a wrong input device.
    if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
      if !loggedMicrophoneDenied {
        loggedMicrophoneDenied = true
        Log.error(
          "MIC",
          "Microphone access is not authorized. Enable Tok in System Settings > Privacy & Security > Microphone."
        )
      }
      if hot.soundFeedback {
        SoundManager.playErrorSound()
      }
      feedback.showError(message: "Microphone access is off. Enable Tok in System Settings.")
      return
    }
    loggedMicrophoneDenied = false

    // Offline fast-fail: say so in 0ms instead of recording a clip whose WS and REST
    // routes will both time out ~10s later.
    if !NetworkMonitor.shared.isOnline {
      Log.warn("NET", "No internet connection - dictation blocked.")
      if hot.soundFeedback {
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
    turnKeyDownTime = ProcessInfo.processInfo.systemUptime
    turnKeyDownEpoch = Date().timeIntervalSince1970
    turnCaptureStartMs = nil
    // A turn cancelled by chord or Escape while capturing (discardCapture) never reaches
    // handleKeyUp, so without this reset it would inherit the previous turn's key_up_epoch.
    turnKeyUpEpoch = nil
    turnStartingNoticeShown = false
    captureTimingLock.lock()
    let previousCaptureEnd = lastCaptureEndUptime
    captureTimingLock.unlock()
    turnMsSincePrevCapture = previousCaptureEnd.map { (turnKeyDownTime - $0) * 1000 }

    micIdleWorkItem?.cancel()
    micIdleWorkItem = nil

    capturePending = true
    captureGeneration &+= 1
    let generation = captureGeneration
    // Item AB: "warm" iff the mic was already running when this key-down was decided -
    // the same instant that decides whether the "Getting ready" pill is even scheduled.
    let micWasWarm = audioCapture.isEngineRunning
    turnMicStateAtKeydown = micWasWarm ? "warm" : "cold"
    if !micWasWarm { scheduleStartingNotice(generation: generation) }
    audioCapture.ensureReady { [weak self] ready in
      guard let self = self, self.capturePending, self.captureGeneration == generation else {
        return
      }
      self.capturePending = false
      // Readiness answered: beginCapture's listening pill, or the error below, is the
      // right thing to show now.
      self.cancelStartingNotice()
      guard ready else {
        self.hotkeyManager?.resetToggle()
        self.feedback.showError(message: "Microphone unavailable. Try again.")
        if self.hot.soundFeedback { SoundManager.playErrorSound() }
        self.scheduleMicIdleRelease()
        return
      }
      self.beginCapture(generation: generation)
    }
  }

  /// How long a lone hold must last before the "Getting ready" pill appears. A chord's
  /// second key lands within about 120 ms of the modifier, so waiting this long means
  /// Fn plus Delete never flashes an overlay (audit F10). A microphone that becomes ready
  /// sooner replaces the pill with the listening one anyway.
  static let startingNoticeDelay: TimeInterval = 0.12

  /// How long after a key-up a shortcut press is still read as an eager re-press rather
  /// than a cancel (audit F11). One second covers the bounce of the gesture itself and the
  /// median turn (about 550 ms measured), so a fast next phrase never discards the one
  /// that is about to paste; a press later than this targets a turn stuck on the network.
  static let cancelPressGraceSec: TimeInterval = 1.0

  /// Main thread. Defers the readiness pill so a chord can cancel it before it is seen.
  private func scheduleStartingNotice(generation: UInt64) {
    cancelStartingNotice()
    let item = DispatchWorkItem { [weak self] in
      guard let self = self, self.captureGeneration == generation,
        self.capturePending || self.captureActive
      else { return }
      self.startingNoticeWorkItem = nil
      self.turnStartingNoticeShown = true
      self.feedback.showStarting()
    }
    startingNoticeWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.startingNoticeDelay, execute: item)
  }

  /// Main thread.
  private func cancelStartingNotice() {
    startingNoticeWorkItem?.cancel()
    startingNoticeWorkItem = nil
  }

  /// Main thread. Another key was pressed while the shortcut was held, so this was a system
  /// chord (Fn plus Delete, Fn plus arrow), not a dictation. Abandon it silently: no sound,
  /// no error pill and no history row - nothing happened that the user asked for (F10).
  private func handleChord() {
    guard !isStopping else { return }
    cancelStartingNotice()
    hotkeyManager?.resetToggle()
    if capturePending {
      // Same retreat as the capturePending branch of handleKeyUp: the readiness callback
      // is disowned by the generation bump and nothing was ever recorded.
      capturePending = false
      captureGeneration &+= 1
      audioCapture.cancelPendingReadiness()
      feedback.hide()
      scheduleMicIdleRelease()
      return
    }
    // A locked turn is not being held, so no key can chord against it.
    guard captureActive, !turnLocked else { return }
    // Info, not debug: this is the only trace of a silently abandoned hold.
    Log.info("HOTKEY", "Another key was pressed during the hold - capture abandoned.")
    discardCapture(record: false, announce: false)
  }

  /// Main thread. The user asked to stop this turn: Escape at any stage, or a second
  /// shortcut press once the turn is network-bound. Nothing is pasted. Audio already sent
  /// to the API cannot be retracted, so a cancel late in the turn still costs its tokens.
  private func handleCancel(source: String) {
    guard !isStopping else { return }
    if capturePending {
      cancelStartingNotice()
      hotkeyManager?.resetToggle()
      capturePending = false
      captureGeneration &+= 1
      audioCapture.cancelPendingReadiness()
      // No capture ever started, so there is no turn to write a row for.
      feedback.showCancelled()
      scheduleMicIdleRelease()
      Log.info("TURN", "Dictation cancelled before the microphone was ready (\(source)).")
      return
    }
    if captureActive {
      // Escape cancels a locked turn too: the user is not holding anything to release.
      cancelStartingNotice()
      hotkeyManager?.resetToggle()
      Log.info("TURN", "Dictation cancelled during capture (\(source)).")
      discardCapture(record: true, announce: true)
      return
    }
    processingLock.lock()
    let busy = isProcessing
    processingLock.unlock()
    guard busy else { return }
    // The arbiter work belongs to sessionQueue, which is serial: a cancel queued behind a
    // post-roll drain or an abandoned capture runs after it, and the busy re-check inside
    // cancelTurn is what stops it acting on a turn that ended in the meantime. The pill is
    // shown from there too, because a late cancel may keep the transcript instead.
    Log.info("TURN", "Cancel requested while finishing (\(source)).")
    sessionQueue.async { [weak self] in self?.cancelTurn(source: source) }
  }

  /// Main thread. Ends the capture in flight without transcribing it. The audio is drained
  /// and discarded and the live turn is abandoned uncommitted, the pattern the micro-click
  /// guard already uses. isProcessing is set here, before the drain is dispatched, for the
  /// same reason handleKeyUp sets it: stopRecording must not overlap the next key-down.
  /// The sessionQueue block below is the only exit and clears it.
  private func discardCapture(record: Bool, announce: Bool) {
    captureActive = false
    // The gesture ended here, so a press right behind it is a bounce, not a cancel.
    lastKeyUpTime = ProcessInfo.processInfo.systemUptime
    turnLocked = false
    turnFinishMode = "cancel"
    lockWorkItem?.cancel()
    lockWorkItem = nil
    lockLimitWorkItem?.cancel()
    lockLimitWorkItem = nil
    sessionLimitWorkItem?.cancel()
    sessionLimitWorkItem = nil
    pendingDuckItem?.cancel()
    pendingDuckItem = nil
    if config.duckAudio { AudioDucker.shared.restore() }
    // A chord retreats without a word; a cancel says so.
    if announce { feedback.showCancelled() } else { feedback.hide() }

    processingLock.lock()
    isProcessing = true
    processingLock.unlock()

    sessionQueue.async { [weak self] in
      guard let self = self else { return }
      // Zero grace and zero trail: there is nothing in this clip worth waiting for. The
      // buffers still have to be drained, or the next turn would inherit them.
      let (_, duration, _, _, _, _, _) = self.audioCapture.stopRecording(
        gracePeriodMs: 0, maxTrailMs: 0, silenceThresholdDb: self.config.trailSilenceDb)
      self.noteCaptureFinished()
      self.liveClient?.abandonTurn()
      if !self.config.keepMicrophoneWarm {
        DispatchQueue.main.async { [weak self] in self?.audioCapture.suspendEngine() }
      }
      // No pipeline ran for this turn, so the previous turn's first-interim value is still
      // in the field; a cancelled capture has none.
      self.turnFirstInterimMs = nil
      if record { self.recordCancelledTurn(audioSeconds: duration) }
      self.processingLock.lock()
      self.isProcessing = false
      self.processingLock.unlock()
      DispatchQueue.main.async { [weak self] in self?.scheduleMicIdleRelease() }
    }
  }

  /// sessionQueue-only. Retires the turn in flight. Incrementing currentTurnId is what makes
  /// every route stale: the live commit completion, the REST completion, the fallback timer,
  /// the deadline and the cleanup stage all re-check it, so none of them reaches settle().
  /// settle() therefore stays the sole paste-or-error path; a cancel produces neither, which
  /// is why it does not go through it. Audio already uploaded cannot be recalled.
  func cancelTurn(source: String) {
    guard !isStopping else { return }
    processingLock.lock()
    let busy = isProcessing
    processingLock.unlock()
    // The turn settled between the key press and this block: it already pasted, and a
    // second "cancelled" row would claim otherwise.
    guard busy else { return }
    // The transcript already arrived, so discarding it would lose paid-for words with no
    // trace. A second shortcut press means "next phrase": let the paste finish. Escape means
    // "not here": keep the words on the clipboard instead of pasting them.
    if turnHasResult {
      if source == "escape" {
        turnCopyOnlyRequested = true
        Log.info("TURN", "Cancel arrived after the transcript; copying instead of pasting.")
      } else {
        Log.info("TURN", "Cancel press arrived after the transcript; pasting as normal.")
      }
      return
    }
    currentTurnId &+= 1
    turnSettled = true
    pendingRestRequest?.cancel()
    pendingRestRequest = nil
    postProcessingStage.cancel()
    pendingFallbackTimer?.cancel()
    pendingFallbackTimer = nil
    pendingTurnDeadline?.cancel()
    pendingTurnDeadline = nil
    pendingProgressNotice?.cancel()
    pendingProgressNotice = nil
    wsCommitInFlight = false
    wsTerminal = true
    restTerminal = true
    liveClient?.abandonTurn()
    recordCancelledTurn(audioSeconds: turnAudioSeconds)
    processingLock.lock()
    isProcessing = false
    processingLock.unlock()
    DispatchQueue.main.async { [weak self] in
      self?.feedback.showCancelled()
      self?.scheduleMicIdleRelease()
    }
  }

  /// The history row for a cancelled turn: no text and no delivery, so the stats query
  /// (which counts outcome='success') and the menu's last-delivery label ignore it.
  private func recordCancelledTurn(audioSeconds: Double?) {
    recordTurn(
      TurnRecord(
        outcome: "cancelled",
        text: nil,
        charCount: 0,
        wordCount: 0,
        transport: nil,
        model: nil,
        isLiveRoute: nil,
        fallbackReason: nil,
        audioSeconds: audioSeconds,
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
        finishMode: "cancel"
      ))
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
    turnCaptureStartMs = (ProcessInfo.processInfo.systemUptime - turnKeyDownTime) * 1000
    turnPrerollMsUsed = audioCapture.preRollMsUsedInTurn
    if hot.soundFeedback { SoundManager.playStartSound() }
    feedback.showListening(lockAfter: holdToLockInterval)
    feedback.captureStarted(pid: turnFrontmostPID, followFocus: hot.hudFollowFocus)
    if config.restoreClipboard { TextInjector.prepareClipboard() }
    armHoldToLock()
    armSessionLimit()

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
    // Item AB: wall-clock equivalent of keyUpTime. When keyUpTime came from an event
    // timestamp (uptime-based, in the past), shift now's epoch back by the same queueing
    // delay instead of stamping the moment this handler happened to run.
    turnKeyUpEpoch = Date().timeIntervalSince1970 - (handlerTime - keyUpTime)

    if capturePending {
      capturePending = false
      captureGeneration &+= 1
      cancelStartingNotice()
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
    // Stamped on main with the other per-turn fields; sessionQueue compares against this
    // instead of reading captureGeneration off its own thread (audit F33).
    turnFeedbackGeneration = captureGeneration
    turnEventQueueMs = (handlerTime - keyUpTime) * 1000
    lockWorkItem?.cancel()
    lockWorkItem = nil
    lockLimitWorkItem?.cancel()
    lockLimitWorkItem = nil
    sessionLimitWorkItem?.cancel()
    sessionLimitWorkItem = nil

    // Release acknowledged, before the settle race: on a slow REST fallback there are
    // otherwise seconds of silence between letting go and the commit earcon. While the
    // output is ducked the cue's own volume is boosted to compensate.
    if hot.soundFeedback && hot.releaseSound {
      let scale: Float =
        AudioDucker.shared.isDucked ? Float(1.0 / max(0.15, config.duckFraction)) : 1.0
      SoundManager.playReleaseSound(volumeScale: scale)
    }

    // A press this soon after the release is a bounce, not a cancel (audit F11).
    lastKeyUpTime = handlerTime

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
      if self.hot.soundFeedback {
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

  /// The one failure that is not a fault: the clip held no speech. The store maps it to a
  /// calmer menu-bar state than a real error.
  public static let noSpeechMessage = "No speech detected"

  /// Margin kept before the live session limit so the final audio and end signals
  /// still land inside the session.
  static let sessionLimitMargin = 15.0

  // Main thread. Scheduled at capture start in every shortcut mode: the live service
  // ends a session at ten minutes, so a turn must finish before the current session
  // does, whatever LOCK_LIMIT says. The REST route is the fallback for every turn and its
  // inline request carries about eight minutes of audio, so the bound is the smaller of the
  // live session and that cap; a locked turn is never left uncapped (audit F33).
  private func armSessionLimit() {
    sessionLimitWorkItem?.cancel()
    sessionLimitWorkItem = nil
    let remaining = liveClient?.sessionRemainingSeconds ?? GeminiLiveClient.sessionLimitSeconds
    let limit =
      max(5.0, min(remaining, GeminiRestClient.maxInlineAudioSeconds) - Self.sessionLimitMargin)
    let item = DispatchWorkItem { [weak self] in
      guard let self = self, self.captureActive else { return }
      self.sessionLimitWorkItem = nil
      Log.warn(
        "LIMIT",
        "Dictation reached the maximum recording length after \(String(format: "%.0f", limit))s - finishing it now."
      )
      self.turnLocked = false
      self.handleKeyUp(finish: "session_limit")
      self.announceLimitReached()
    }
    sessionLimitWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + limit, execute: item)
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
      self.announceLimitReached()
    }
    lockLimitWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + config.lockLimitSec, execute: item)
  }

  /// Main thread. A limit ended the turn without the user asking for it, so say so in the
  /// HUD instead of only in the log (audit F06). handleKeyUp hops its own showProcessing to
  /// main first, so this async lands after it and reads as a note on the processing state.
  /// Nothing is said when handleKeyUp found no turn to finish.
  private func announceLimitReached() {
    processingLock.lock()
    let busy = isProcessing
    processingLock.unlock()
    guard busy else { return }
    DispatchQueue.main.async { [weak self] in
      self?.feedback.showProcessingStatus("Time limit reached, finishing")
    }
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
    noteCaptureFinished()
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
    turnFirstInterimMs = nil
    turnAudioSeconds = duration
    turnCaptureFinalizeMs = (ProcessInfo.processInfo.systemUptime - pipelineStartTime) * 1000
    if interrupted {
      currentTurnId &+= 1
      turnSettled = false
      settle(
        turnId: currentTurnId, route: "microphone",
        outcome: .failure(
          NSError(
            domain: "Tok.Microphone", code: 1,
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
        self?.feedback.showError(message: Self.noSpeechMessage)
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
    // New turn: no route has answered or failed yet (audit F21).
    wsCommitInFlight = false
    wsTerminal = false
    restTerminal = false
    lastRestError = nil
    turnHasResult = false
    turnCopyOnlyRequested = false
    let budget = TurnDeadline.budget(fallbackTimeout: config.restFallbackTimeout)
    let deadline = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      // Both routes stalled. A REST error already recorded for this turn says more than
      // "deadline exceeded" does, so it is the failure the user sees (audit F21).
      let error =
        self.lastRestError
        ?? NSError(
          domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
          userInfo: [NSLocalizedDescriptionKey: "Dictation deadline exceeded; nothing pasted."])
      self.settle(turnId: turnId, route: "deadline", outcome: .failure(error))
    }
    pendingTurnDeadline = deadline
    sessionQueue.asyncAfter(
      deadline: .now()
        + TurnDeadline.remaining(
          budget: budget, elapsed: ProcessInfo.processInfo.systemUptime - keyUpTime),
      execute: deadline)

    // Progress after the first beat: a single "Finishing" for the whole budget reads as a
    // hang (audit F09). sessionQueue-only, like every other per-turn timer; settle() cancels it.
    pendingProgressNotice?.cancel()
    let progressNotice = DispatchWorkItem { [weak self] in
      guard let self = self, self.currentTurnId == turnId, !self.turnSettled else { return }
      self.pendingProgressNotice = nil
      DispatchQueue.main.async { [weak self] in
        self?.feedback.showProcessingStatus("Still working")
      }
    }
    pendingProgressNotice = progressNotice
    sessionQueue.asyncAfter(deadline: .now() + 1.5, execute: progressNotice)

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
          captureFinalizeMs: captureFinalizeMs, reason: reason, backupRoute: true)
      }
      pendingFallbackTimer = fallbackTimer
      sessionQueue.asyncAfter(deadline: .now() + dynamicTimeout, execute: fallbackTimer)
      wsCommitInFlight = true

      // A hold of two seconds or more that produced no interim text means the live route
      // is not transcribing: start REST now rather than paying the fallback timeout on top
      // of a long clip (audit F22). Cancelling the timer keeps this from being doubled; the
      // two routes still race, and settle() takes the first result.
      if duration >= 2.0, !liveClient.hasReceivedTokens {
        pendingFallbackTimer?.cancel()
        pendingFallbackTimer = nil
        let hedgeReason = "No live interim during hold (hedge)"
        Log.warn("WS", "\(hedgeReason); executing REST fallback in parallel...")
        executeRestFallback(
          turnId: turnId, pcmData: pcmData, duration: duration, keyUpTime: keyUpTime,
          captureFinalizeMs: captureFinalizeMs, reason: hedgeReason, backupRoute: true)
      }

      liveClient.commitTurn { [weak self] result in
        guard let self = self else { return }
        self.sessionQueue.async {
          guard self.currentTurnId == turnId, !self.turnSettled else { return }
          switch result {
          case .success(let payload):
            let roundtripMs = (ProcessInfo.processInfo.systemUptime - commitStartTime) * 1000.0
            let usage = self.liveClient?.lastTurnUsage
            self.turnSettlePath = self.liveClient?.lastSettlePath
            self.turnFirstInterimMs = self.liveClient?.lastTurnFirstInterimMs
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
            // The live route is done for this turn either way (audit F21).
            self.wsTerminal = true
            // REST already failed and was kept waiting for this result, so no route is
            // left: the live error is the turn's error (audit F21).
            if self.restTerminal {
              // settle() abandons the live turn only for non-WS routes, so do it here:
              // abandonTurn is idempotent and leaves no half-open turn on the client.
              self.liveClient?.abandonTurn()
              self.settle(turnId: turnId, route: "WS", outcome: .failure(error))
              return
            }
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
            if nsError.domain == "Tok", nsError.code == -2,
              speechFrames < self.wsNoSpeechTrustFrames
            {
              Log.warn(
                "WS",
                "No speech recognized (\(speechFrames) speech frames in clip); settling empty - REST fallback suppressed."
              )
              self.turnSettlePath = self.liveClient?.lastSettlePath
              self.turnFirstInterimMs = self.liveClient?.lastTurnFirstInterimMs
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
              captureFinalizeMs: captureFinalizeMs, reason: reason, backupRoute: true)
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
  ///
  /// backupRoute is true when REST stands in for a live route that stalled or failed, and
  /// false for a configuration that always uses REST - only the former is worth saying in
  /// the HUD (audit F09).
  private func executeRestFallback(
    turnId: UInt64, pcmData: Data, duration: Double, keyUpTime: CFAbsoluteTime,
    captureFinalizeMs: Double, reason: String, isRetry: Bool = false, backupRoute: Bool = false
  ) {
    guard currentTurnId == turnId, !turnSettled else { return }
    if backupRoute, !isRetry {
      DispatchQueue.main.async { [weak self] in
        self?.feedback.showProcessingStatus("Using backup route")
      }
    }
    if restAttemptStart == nil { restAttemptStart = ProcessInfo.processInfo.systemUptime }
    let restStartTime = restAttemptStart!
    pendingRestRequest = GeminiRestClient.transcribe(
      pcmData: pcmData,
      apiKey: config.geminiApiKey,
      model: config.geminiModel,
      languageCodes: config.languageCodes,
      customVocabulary: config.recognitionVocabulary,
      smartTranscription: config.smartTranscription
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
              captureFinalizeMs: captureFinalizeMs, reason: reason, isRetry: true,
              backupRoute: backupRoute)
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
          self.handleRestFailure(turnId: turnId, error: error)
        }
      }
    }
  }

  /// sessionQueue-only. Applies a REST failure to the turn arbiter. A hedge that fails while
  /// the live commit is still in flight must leave the turn alive: the live result, or the
  /// turn deadline, settles it instead of throwing away a viable dictation (audit F21).
  func handleRestFailure(turnId: UInt64, error: Error) {
    guard currentTurnId == turnId, !turnSettled else { return }
    restTerminal = true
    lastRestError = error
    guard Self.shouldSettleOnRestFailure(wsViable: wsRouteViable) else {
      Log.warn("REST", "REST failed; waiting for the live result: \(error.localizedDescription)")
      return
    }
    settle(turnId: turnId, route: "REST", outcome: .failure(error))
  }

  /// sessionQueue-only. True while the live route can still answer the current turn: the
  /// commit was issued and has not failed.
  var wsRouteViable: Bool {
    config.enableLiveWebSocket && liveClient != nil && wsCommitInFlight && !wsTerminal
  }

  /// The whole of the F21 decision, kept pure so the regression test does not need a
  /// network turn: a REST failure ends the turn only when no live result can arrive.
  static func shouldSettleOnRestFailure(wsViable: Bool) -> Bool { !wsViable }

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
        self?.feedback.showError(message: "Microphone access lost. Check System Settings.")
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
        return "No internet connection. Nothing pasted."
      case NSURLErrorTimedOut:
        return "Network timeout. Nothing pasted."
      case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorDNSLookupFailed:
        return "Can't reach Gemini. Nothing pasted."
      case NSURLErrorSecureConnectionFailed:
        return "Secure connection failed. Nothing pasted."
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
    pendingProgressNotice?.cancel()
    pendingProgressNotice = nil

    switch outcome {
    case .success(
      let text, let transport, let firstTokenMs, let roundtripMs, let audioDuration, let keyUpTime,
      let captureFinalizeMs, let fallbackReason, let isLiveRoute, let inputTokens, let outputTokens):
      consecutiveNoSpeechTurns = 0
      turnHasResult = true
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
        self?.feedback.showError(message: Self.noSpeechMessage)
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
      if hot.soundFeedback { SoundManager.playErrorSound() }
      let hudMessage =
        (error as NSError).domain == "Tok.Microphone"
        ? "Microphone interrupted. Try again."
        : Self.friendlyFailureMessage(error) ?? "Transcription failed. Nothing pasted."
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
    // False when the prepared snapshot never arrived inside awaitPreparedClipboard's wait.
    // The paste still happens; only the clipboard restore is given up (audit F27).
    clipboardSnapshotReady: Bool = true,
    postProcessing: PostProcessingMetrics = .off
  ) {
    guard !isStopping else { return }
    // The clipboard wait below leaves sessionQueue for up to 150 ms. A cancel that lands in
    // that window retires the turn id, and the re-entry must see it: otherwise the cancel
    // row is written and the text is pasted anyway (audit F11).
    let turnId = currentTurnId
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
      TextInjector.awaitPreparedClipboard { [weak self] ready in
        guard let self = self else { return }
        self.sessionQueue.async {
          guard self.currentTurnId == turnId, !self.isStopping else {
            Log.debug("SESSION", "Turn #\(turnId) retired during the clipboard wait; not pasting.")
            return
          }
          self.handleTranscribedText(
            rawText, transport: transport,
            firstTokenMs: firstTokenMs, roundtripMs: roundtripMs,
            audioDuration: audioDuration, totalStartTime: totalStartTime,
            captureFinalizeMs: captureFinalizeMs, fallbackReason: fallbackReason,
            isLiveRoute: isLiveRoute, inputTokens: inputTokens, outputTokens: outputTokens,
            clipboardPrepared: true, clipboardSnapshotReady: ready,
            postProcessing: postProcessing)
        }
      }
      return
    }
    let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      Log.warn("AI", "Received empty transcription from Gemini.")
      DispatchQueue.main.async { [weak self] in
        self?.feedback.showError(message: Self.noSpeechMessage)
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
    } else if turnCopyOnlyRequested {
      // Escape landed after the transcript: the user did not want it in this field, but the
      // words are paid for, so they stay on the clipboard.
      let copyStart = ProcessInfo.processInfo.systemUptime
      if !TextInjector.copyOnly(text: text, appendSpace: config.trailingSpace) {
        deliveryError = "Clipboard write failed. Text not copied."
      }
      injectMs = (ProcessInfo.processInfo.systemUptime - copyStart) * 1000.0
      injected = false
      Log.info("INJECT", "Cancelled after the transcript arrived - copied, not pasted.")
      copyOnlyReason = "cancelled"
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
        // No snapshot means the previous clipboard cannot be put back, but refusing the
        // paste would lose the dictation instead - the worse trade (audit F27). The
        // dictation simply stays on the clipboard afterwards.
        let restorePrevious = config.restoreClipboard && clipboardSnapshotReady
        if config.restoreClipboard, !clipboardSnapshotReady {
          Log.warn(
            "INJECT",
            "Clipboard snapshot unavailable; pasted without restoring the previous clipboard")
        }
        let result = TextInjector.inject(
          text: text, restorePreviousClipboard: restorePrevious,
          completionSound: hot.soundFeedback, appendSpace: config.trailingSpace,
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

    if copyOnlyReason != nil, deliveryError == nil, hot.soundFeedback {
      // Text still landed - on the clipboard - so this is a commit, not an error sound.
      SoundManager.playCommitSound()
    }

    let totalElapsedMs = (ProcessInfo.processInfo.systemUptime - totalStartTime) * 1000.0

    let feedbackGeneration = turnFeedbackGeneration
    DispatchQueue.main.async { [weak self] in
      guard let self = self, self.captureGeneration == feedbackGeneration else { return }
      if let message = deliveryError {
        self.feedback.showError(message: message)
      } else if let reason = copyOnlyReason {
        let message: String
        switch reason {
        case "secure input":
          message = "Copied. Press ⌘V outside the password field."
        case "accessibility revoked":
          message = "Copied. Accessibility access is off. Press ⌘V to paste."
        case "cancelled":
          message = "Cancelled. Copied to clipboard. Press ⌘V to paste."
        default: message = "Copied. Focus changed. Press ⌘V to paste."
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
    let inputPrice = isLiveRoute ? hot.liveInputPricePer1M : hot.restInputPricePer1M
    let outputPrice = isLiveRoute ? hot.liveOutputPricePer1M : hot.restOutputPricePer1M
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
      wordCount: WordTokenizer.count(in: text),
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
