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
  /// The last failure text, kept for the menu after `status` returns to ready (audit F03).
  private(set) var lastError: String?
  /// How the last dictation reached the app, in plain language (audit F04).
  private(set) var lastDelivery: String?
  @ObservationIgnored private var errorResetWorkItem: DispatchWorkItem?
  /// Matches the HUD error linger, so the icon clears when the overlay does.
  private static let errorDisplaySeconds = 3.0
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
  /// The persisted counterpart to the in-memory `diagnostics` log (audit F36).
  /// Created in `start()`, once `settings.supportDirectory` is known.
  @ObservationIgnored private var diagnosticsFile: DiagnosticsFile?
  var hotkey: String { settings.configuration.hotkey }
  private var toggleMode: Bool { settings.configuration.hotkeyMode == "toggle" }
  private var readyMessage: String {
    ShortcutPrompt.ready(shortcut: shortcutLabel, toggleMode: toggleMode)
  }
  init(settings: SettingsStore = SettingsStore()) {
    self.settings = settings
    self.metrics = MetricsStore(supportDirectory: settings.supportDirectory)
    settings.didChange = { [weak self] keys in self?.settingsChanged(keys) }
  }
  func start() {
    settings.load()
    // The support directory only exists once settings has loaded (audit F36).
    diagnosticsFile = DiagnosticsFile(directory: settings.supportDirectory)
    // Sparkle must not interrupt a live turn, so it asks the store before acting.
    updates.isDictationActive = { [weak self] in self?.dictationActive ?? false }
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
    // Revoked Accessibility or Input Monitoring access is invisible while an engine
    // exists, because the checks below run only before one is created (audit F16).
    if engine != nil, !permissions.allGranted {
      stop()
      status = .setup
      message = "Grant microphone, Accessibility, and Input Monitoring access."
      return
    }
    guard engine == nil, !isPaused else { return }
    // A load failure is usually transient: a locked Keychain, or a support folder that
    // was not writable yet. Retry once per refresh instead of staying dead (audit F34).
    if settings.loadError != nil { settings.load() }
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
  func settingsChanged(_ keys: Set<String>) {
    if settings.configuration.privacyMode {
      lastText = ""
      liveText = ""
      lastDelivery = nil
    }
    if metrics.enabled != settings.configuration.shareUsageMetrics {
      metrics.configure(enabled: settings.configuration.shareUsageMetrics)
    }
    configureStats()
    applyRetention()
    configureVocabularyWatcher()
    hud?.update(configuration: settings.configuration)
    engine?.applyHotSettings(from: settings.configuration)
    // Only a key the engine reads at construction is worth a rebuild. Sounds, overlay,
    // pricing, stats, and retention are applied above or through hot settings (audit F30).
    // A pending rebuild from an earlier change stays scheduled.
    guard Self.requiresEngineRestart(keys) else { return }
    settingsWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.settingsPending = true
      self.applyPendingSettings()
    }
    settingsWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
  }
  /// A key outside the catalog, including the `everySetting` sentinel, always rebuilds.
  private static func requiresEngineRestart(_ keys: Set<String>) -> Bool {
    keys.contains { key in
      guard let setting = SettingCatalog.all.first(where: { $0.key == key }) else { return true }
      return setting.restartsEngine
    }
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
    let wasActive = active
    switch event {
    case .ready, .starting, .listening, .locked, .processing, .busy, .hidden,
      .microphoneReleased, .success, .failure, .cancelled, .captureStarted:
      // A newer lifecycle event decides the status, so the pending error reset is stale.
      cancelErrorReset()
    default: break
    }
    switch event {
    case .ready:
      status = .ready
      message = readyMessage
    case .starting:
      status = .starting
      message = "Getting ready…"
    case .listening:
      status = .listening
      liveText = ""
      message = ShortcutPrompt.listening(shortcut: shortcutLabel, toggleMode: toggleMode)
    case .locked:
      status = .locked
      message = "Release the key. Press again to finish."
    case .processing, .busy:
      status = .processing
      message = "Finishing your dictation."
    case .hidden:
      status = .ready
      message = readyMessage
    case .microphoneReleased:
      status = .microphoneReleased
      message = ShortcutPrompt.wake(shortcut: shortcutLabel, toggleMode: toggleMode)
    case .failure(let reason):
      status = .error
      message = reason
      lastError = reason
      appendDiagnostic("[ERROR] [APP] \(reason)")
      scheduleErrorReset()
    case .success:
      status = .ready
      message = "Done."
      // The previous failure is answered by this dictation.
      lastError = nil
    case .cancelled:
      // The user stopped the turn, so the menu bar goes back to ready rather than to the
      // attention state a failure would leave behind.
      status = .ready
      message = "Cancelled."
      lastError = nil
    case .liveText(let text): liveText = settings.configuration.privacyMode ? "" : text
    case .turnSettled(let record):
      history.reload()
      stats.record(record)
      metrics.record(.dictation(envelope: metrics.envelope(), record: record))
      if let text = record.text { lastText = settings.configuration.privacyMode ? "" : text }
      lastDelivery = DeliveryLabel.menuDelivery(record.deliveryOutcome)
      if record.outcome == "success" { completedTurns += 1 }
      if let total = record.totalMs {
        lastLatency = LatencySnapshot(record: record)
        let route = record.isLiveRoute.map { $0 ? "WS" : "REST" } ?? record.transport ?? "none"
        lastLatencyLine =
          "LATENCY route=\(route) capture_start=\(Self.milliseconds(record.captureStartMs)) capture=\(Self.milliseconds(record.captureFinalizeMs)) first_interim=\(Self.milliseconds(record.firstInterimMs)) api=\(Self.milliseconds(record.roundtripMs)) injection=\(Self.milliseconds(record.injectMs)) total=\(Self.milliseconds(total)) delivery=\(record.deliveryOutcome ?? "none")"
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
    case .processingStatus(let text):
      // Progress inside the same processing state, so the status stays put.
      message = text
    case .diagnostic(let line): appendDiagnostic(line)
    case .historyError(let reason): historyError = reason
    case .audioLevel, .captureStarted: break
    }
    // Sparkle waits for the turn to finish before it may install or relaunch.
    if wasActive, !active { updates.dictationEnded() }
    applyPendingSettings()
  }

  func dismissLastError() { lastError = nil }

  /// The HUD hides its error after about three seconds without emitting an event, so the
  /// menu-bar icon stayed on "Needs attention" until the next turn (audit F03).
  private func scheduleErrorReset() {
    cancelErrorReset()
    let item = DispatchWorkItem { [weak self] in
      guard let self, self.status == .error else { return }
      self.errorResetWorkItem = nil
      self.status = .ready
      self.message = self.readyMessage
      self.reportRuntime()
    }
    errorResetWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.errorDisplaySeconds, execute: item)
  }

  private func cancelErrorReset() {
    errorResetWorkItem?.cancel()
    errorResetWorkItem = nil
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
    // Redaction above already stripped the key, so the persisted copy is safe too.
    diagnosticsFile?.write(safeLine)
  }

  /// Clears the session log and the persisted file together, so "Clear log" means what it
  /// says (audit F36).
  func clearDiagnostics() {
    diagnostics.removeAll()
    diagnosticsFile?.clear()
  }

  /// Flushes the on-disk log and presents a save panel for a support report:
  /// a header of non-secret context, then the persisted diagnostics lines.
  /// Follows the pattern of `HistoryViewStore.exportCSV` (audit F36).
  func saveDiagnosticsReport() async {
    diagnosticsFile?.flush()
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Tok diagnostics.txt"
    panel.message =
      "Saves timing, warnings, and non-secret settings for troubleshooting. Never your API key."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let header = diagnosticsReportHeader()
    let file = diagnosticsFile
    await Task.detached(priority: .utility) {
      let body = file?.reportContents() ?? ""
      try? (header + body).write(to: url, atomically: true, encoding: .utf8)
    }.value
  }

  /// App version, OS version, last latency line, permissions, and the
  /// non-secret protocol knobs worth including in a support report. Never
  /// the API key.
  private func diagnosticsReportHeader() -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let permissionsLine =
      "microphone=\(permissions.microphone) accessibility=\(permissions.accessibility) inputMonitoring=\(permissions.inputMonitoring)"
    let keys = [
      "WS_ENDPOINT_ALIGNED", "SILENCE_FLUSH_MS", "CHUNK_MS", "VAD_MODE", "REST_FALLBACK_TIMEOUT",
      "HOTKEY", "HOTKEY_MODE",
    ]
    let settingsLines = keys.map { "\($0)=\(settings.string($0))" }.joined(separator: "\n")
    return """
      Tok \(BuildIdentity.version), \(os)
      \(lastLatencyLine)
      Permissions: \(permissionsLine)
      \(settingsLines)

      """
  }
}
