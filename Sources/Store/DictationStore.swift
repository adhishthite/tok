import AppKit
import Observation
import TokEngine
import TokHUD

@MainActor
@Observable
final class DictationStore: DictationEngineDelegate {
  let settings: SettingsStore
  let updates = UpdateStore()
  let loginItem = LoginItemStore()
  let history = HistoryViewStore()
  let stats = StatsViewStore()
  let metrics: MetricsStore
  @ObservationIgnored var showVocabulary: (() -> Void)?
  @ObservationIgnored var showSetup: (() -> Void)?
  private(set) var status = DictationStatus.setup
  private(set) var permissions = PermissionStatus.current()
  private(set) var message = "Grant permissions to start dictating."
  private(set) var lastText = ""
  private(set) var liveText = ""
  private(set) var lastLatencyLine = "No dictations measured yet."
  private(set) var diagnostics: [DiagnosticEntry] = []
  private(set) var lastLatency: LatencySnapshot?
  private(set) var completedTurns = 0
  private(set) var settingsPending = false
  private(set) var retentionError: String?
  private(set) var historyError: String?
  @ObservationIgnored private var retentionTimer: Timer?
  @ObservationIgnored private var retaining = false
  private(set) var hasLoaded = false
  private(set) var isPaused = false
  @ObservationIgnored private var settingsWorkItem: DispatchWorkItem?
  /// Setup state is recorded once after launch and again only when completeness flips.
  @ObservationIgnored private var lastSetupComplete: Bool?
  var needsSetup: Bool { !permissions.allGranted || !settings.hasAPIKey }
  var shortcutLabel: String { settings.configuration.shortcutLabel }
  var dictationActive: Bool { active }
  @ObservationIgnored private var shortcutTesting = false
  private var active: Bool { [.starting, .listening, .locked, .processing].contains(status) }
  @ObservationIgnored private var hud: HUDController?
  @ObservationIgnored private var vocabularyWatcher: VocabularyWatcher?
  @ObservationIgnored private var watchedVocabularyURL: URL?
  @ObservationIgnored private var engine: DictationEngine?
  var hotkey: String { settings.configuration.hotkey }
  init(settings: SettingsStore = SettingsStore()) {
    self.settings = settings
    self.metrics = MetricsStore(supportDirectory: settings.supportDirectory)
    settings.didChange = { [weak self] in self?.settingsChanged() }
  }
  func start() {
    settings.load()
    updates.start()
    configureVocabularyWatcher()
    hasLoaded = true
    configureStats()
    stats.refreshGlance()
    metrics.configure(enabled: settings.configuration.shareUsageMetrics)
    metrics.record(
      .launch(
        envelope: metrics.envelope(), configuration: settings.configuration,
        daysSinceInstall: metrics.daysSinceInstall))
    applyRetention()
    retentionTimer?.invalidate()
    retentionTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.applyRetention() }
    }
    hud = HUDController(configuration: settings.configuration)
    refreshPermissions()
  }
  func refreshPermissions() {
    defer { reportRuntime() }
    permissions = .current()
    if hasLoaded, lastSetupComplete != !needsSetup {
      lastSetupComplete = !needsSetup
      recordSetupState()
    }
    guard engine == nil, !isPaused else { return }
    if let error = settings.loadError {
      message = error
      return
    }
    guard settings.hasAPIKey else {
      message = "Add a Gemini API key to start dictating."
      return
    }
    guard permissions.allGranted else {
      message = "Grant microphone, Accessibility, and Input Monitoring access."
      return
    }
    let engine = DictationEngine(config: settings.configuration)
    engine.delegate = self
    engine.acceptsNewCaptures = !shortcutTesting
    self.engine = engine
    engine.start()
  }
  func setShortcutTesting(_ testing: Bool) {
    shortcutTesting = testing
    engine?.acceptsNewCaptures = !testing
  }
  private func configureVocabularyWatcher() {
    let url = settings.resolvedVocabularyURL
    guard url != watchedVocabularyURL else { return }
    vocabularyWatcher?.stop()
    vocabularyWatcher = VocabularyWatcher(url: url) { [weak self] in
      Task { @MainActor [weak self] in self?.settings.reloadVocabulary() }
    }
    watchedVocabularyURL = url
  }
  private func configureStats() {
    let configuration = settings.configuration
    stats.configure(
      directory: settings.supportDirectory, enabled: configuration.statsEnabled,
      trackWords: configuration.statsWordsEnabled,
      typingWordsPerMinute: configuration.typingWordsPerMinute)
  }
  private func applyRetention() {
    let days = settings.configuration.historyRetentionDays
    guard days > 0, !retaining else { return }
    retaining = true
    let repository = HistoryRepository(path: settings.configuration.historyDbPath)
    let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date())!
    Task {
      defer { retaining = false }
      do {
        try await repository.prune(before: cutoff)
        retentionError = nil
        history.reload()
      } catch {
        retentionError = "Could not apply retention. Review the history database location."
      }
    }
  }
  func settingsChanged() {
    if settings.configuration.privacyMode {
      lastText = ""
      liveText = ""
    }
    if metrics.enabled != settings.configuration.shareUsageMetrics {
      metrics.configure(enabled: settings.configuration.shareUsageMetrics)
    }
    configureStats()
    applyRetention()
    configureVocabularyWatcher()
    hud?.update(configuration: settings.configuration)
    settingsWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.settingsPending = true
      self.applyPendingSettings()
    }
    settingsWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
  }
  private func applyPendingSettings() {
    guard settingsPending, !active else { return }
    settingsPending = false
    history.configure(path: settings.configuration.historyDbPath)
    engine?.stop()
    engine = nil
    refreshPermissions()
  }
  func setPaused(_ paused: Bool) {
    isPaused = paused
    if paused {
      stop()
      status = .paused
    } else {
      refreshPermissions()
    }
  }
  func copyLastDictation() {
    guard !lastText.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(lastText, forType: .string)
  }
  func previewHUD() { hud?.preview() }

  func stop() {
    hud?.hide()
    engine?.stop()
    engine = nil
  }
  nonisolated func engineDidEmit(_ event: EngineEvent) {
    if Thread.isMainThread {
      MainActor.assumeIsolated { consume(event) }
    } else {
      DispatchQueue.main.async { [weak self] in self?.consume(event) }
    }
  }
  private func consume(_ event: EngineEvent) {
    hud?.handle(event)
    switch event {
    case .ready:
      status = .ready
      message = "Hold \(hotkey) to dictate."
    case .starting:
      status = .starting
      message = "Getting ready…"
    case .listening:
      status = .listening
      liveText = ""
      message = "Speak, then release to paste."
    case .locked:
      status = .locked
      message = "Release the key. Press again to finish."
    case .processing, .busy:
      status = .processing
      message = "Finishing your dictation."
    case .hidden:
      status = .ready
      message = "Hold \(hotkey) to dictate."
    case .microphoneReleased:
      status = .microphoneReleased
      message = "Hold \(hotkey) to wake the microphone."
    case .failure(let reason):
      status = .error
      message = reason
      appendDiagnostic("[ERROR] [APP] \(reason)")
    case .success:
      status = .ready
      message = "Done."
    case .liveText(let text): liveText = settings.configuration.privacyMode ? "" : text
    case .turnSettled(let record):
      history.reload()
      stats.record(record)
      metrics.record(.dictation(envelope: metrics.envelope(), record: record))
      if let text = record.text { lastText = settings.configuration.privacyMode ? "" : text }
      if record.outcome == "success" { completedTurns += 1 }
      if let total = record.totalMs {
        lastLatency = LatencySnapshot(record: record)
        let route = record.isLiveRoute.map { $0 ? "WS" : "REST" } ?? record.transport ?? "none"
        lastLatencyLine =
          "LATENCY route=\(route) capture=\(Self.milliseconds(record.captureFinalizeMs)) api=\(Self.milliseconds(record.roundtripMs)) injection=\(Self.milliseconds(record.injectMs)) total=\(Self.milliseconds(total)) delivery=\(record.deliveryOutcome ?? "none")"
        if let cleanup = record.postProcessing {
          lastLatencyLine +=
            " cleanup_status=\(cleanup.status) cleanup=\(Self.milliseconds(cleanup.latencyMs))"
          lastLatencyLine += " cleanup_model=\(cleanup.model ?? "none")"
          lastLatencyLine +=
            " cleanup_input_tokens=\(cleanup.inputTokens.map(String.init) ?? "n/a")"
          lastLatencyLine +=
            " cleanup_output_tokens=\(cleanup.outputTokens.map(String.init) ?? "n/a")"
          lastLatencyLine +=
            " cleanup_thinking_tokens=\(cleanup.thinkingTokens.map(String.init) ?? "n/a")"
          lastLatencyLine +=
            " cleanup_cost_usd=\(cleanup.costUSD.map { String(format: "%.8f", $0) } ?? "n/a")"
          lastLatencyLine += " app_context=\(cleanup.appContextUsed)"
        }
        lastLatencyLine +=
          " total_cost_usd=\(record.costUSD.map { String(format: "%.8f", $0) } ?? "n/a")"
        appendDiagnostic(lastLatencyLine)
        reportRuntime()
      }
    case .diagnostic(let line): appendDiagnostic(line)
    case .historyError(let reason): historyError = reason
    case .audioLevel, .captureStarted: break
    }
    applyPendingSettings()
  }
  private static func milliseconds(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "n/a" }
    return String(format: "%.1fms", value)
  }

  private func recordSetupState() {
    metrics.record(
      .setup(
        envelope: metrics.envelope(), microphone: permissions.microphone,
        accessibility: permissions.accessibility, inputMonitoring: permissions.inputMonitoring,
        apiKey: settings.hasAPIKey))
  }

  func reportRuntime() {
    RuntimeReport.write(
      status: status.rawValue, permissions: permissions,
      hasAPIKey: settings.hasAPIKey, latency: lastLatencyLine)
  }

  private func appendDiagnostic(_ line: String) {
    guard !line.isEmpty else { return }
    let key = settings.configuration.geminiApiKey
    let safeLine = key.isEmpty ? line : line.replacingOccurrences(of: key, with: "[redacted]")
    diagnostics.append(DiagnosticEntry(line: safeLine))
    if diagnostics.count > 300 { diagnostics.removeFirst(diagnostics.count - 300) }
  }

  func clearDiagnostics() { diagnostics.removeAll() }
}
