import AppKit
import Observation
import TokEngine

@MainActor
@Observable
final class DictationStore: DictationEngineDelegate {
  let settings = SettingsStore()
  private(set) var status = DictationStatus.setup
  private(set) var permissions = PermissionStatus.current()
  private(set) var message = "Grant permissions to start dictating."
  private(set) var lastText = ""
  private(set) var liveText = ""
  private(set) var lastLatencyLine = "No dictations measured yet."
  private(set) var diagnostics: [String] = []
  private(set) var completedTurns = 0
  @ObservationIgnored private var engine: DictationEngine?
  var hotkey: String { settings.configuration.hotkey }
  func start() {
    settings.load()
    refreshPermissions()
  }
  func refreshPermissions() {
    defer { reportRuntime() }
    permissions = .current()
    guard engine == nil else { return }
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
    self.engine = engine
    engine.start()
  }
  func stop() {
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
    switch event {
    case .ready:
      status = .ready
      message = "Hold \(hotkey) to dictate."
    case .starting:
      status = .starting
      message = "Waiting for microphone audio."
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
      message = "Paste events dispatched."
    case .liveText(let text): liveText = settings.configuration.privacyMode ? "" : text
    case .turnSettled(let record):
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
  }
  private static func milliseconds(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "n/a" }
    return String(format: "%.1fms", value)
  }

  private func reportRuntime() {
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
