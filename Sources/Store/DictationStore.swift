import AppKit
import Observation
import TokEngine
import TokHUD

@MainActor
@Observable
final class DictationStore: DictationEngineDelegate {
  let settings = SettingsStore()
  let history = HistoryViewStore()
  @ObservationIgnored var showVocabulary: (() -> Void)?
  @ObservationIgnored var showSetup: (() -> Void)?
  private(set) var status = DictationStatus.setup
  private(set) var permissions = PermissionStatus.current()
  private(set) var message = "Grant permissions to start dictating."
  private(set) var lastText = ""
  private(set) var liveText = ""
  private(set) var lastLatencyLine = "No dictations measured yet."
  private(set) var diagnostics: [String] = []
  private(set) var completedTurns = 0
  private(set) var settingsPending = false
  private(set) var hasLoaded = false
  private(set) var isPaused = false
  @ObservationIgnored private var settingsWorkItem: DispatchWorkItem?
  var needsSetup: Bool { !permissions.allGranted || !settings.hasAPIKey }
  var shortcutLabel: String {
    hotkey == "fn" ? "Fn" : hotkey.replacingOccurrences(of: "_", with: " ").capitalized
  }
  var dictationActive: Bool { active }
  @ObservationIgnored private var shortcutTesting = false
  private var active: Bool { [.starting, .listening, .locked, .processing].contains(status) }
  @ObservationIgnored private var hud: HUDController?
  @ObservationIgnored private var vocabularyWatcher: VocabularyWatcher?
  @ObservationIgnored private var watchedVocabularyURL: URL?
  @ObservationIgnored private var engine: DictationEngine?
  var hotkey: String { settings.configuration.hotkey }
  func start() {
    settings.didChange = { [weak self] in self?.settingsChanged() }
    settings.load()
    configureVocabularyWatcher()
    hasLoaded = true
    hud = HUDController(configuration: settings.configuration)
    refreshPermissions()
  }
  func refreshPermissions() {
    defer { reportRuntime() }
    permissions = .current()
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
  func settingsChanged() {
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
    case .success:
      status = .ready
      message = "Done."
    case .liveText(let text): liveText = settings.configuration.privacyMode ? "" : text
    case .turnSettled(let record):
      history.reload()
      if let text = record.text { lastText = settings.configuration.privacyMode ? "" : text }
      if record.outcome == "success" { completedTurns += 1 }
      if let total = record.totalMs {
        let route = record.isLiveRoute.map { $0 ? "WS" : "REST" } ?? record.transport ?? "none"
        lastLatencyLine =
          "LATENCY route=\(route) capture=\(Self.milliseconds(record.captureFinalizeMs)) api=\(Self.milliseconds(record.roundtripMs)) injection=\(Self.milliseconds(record.injectMs)) total=\(Self.milliseconds(total)) delivery=\(record.deliveryOutcome ?? "none")"
        appendDiagnostic(lastLatencyLine)
        reportRuntime()
      }
    case .diagnostic(let line): appendDiagnostic(line)
    case .audioLevel, .captureStarted: break
    }
    applyPendingSettings()
  }
  private static func milliseconds(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "n/a" }
    return String(format: "%.1fms", value)
  }

  func reportRuntime() {
    RuntimeReport.write(
      status: status.rawValue, permissions: permissions,
      hasAPIKey: settings.hasAPIKey, latency: lastLatencyLine)
  }

  private func appendDiagnostic(_ line: String) {
    guard !line.isEmpty else { return }
    diagnostics.append(line)
    if diagnostics.count > 300 { diagnostics.removeFirst(diagnostics.count - 300) }
  }
}
