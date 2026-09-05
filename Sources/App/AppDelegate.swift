import AppKit
import TokEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = DictationStore()
  private let setupWindow = SetupWindow()
  private let vocabularyWindows = VocabularyWindows()
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    store.showSetup = { [weak self] in
      guard let self else { return }
      self.setupWindow.show(store: self.store)
    }
    store.showVocabulary = { [weak self] in
      guard let self else { return }
      self.vocabularyWindows.show(settings: self.store.settings)
    }
    store.start()
    if store.needsSetup || ProcessInfo.processInfo.arguments.contains("--show-setup") {
      setupWindow.show(store: store)
    }
    if ProcessInfo.processInfo.arguments.contains("--hud-demo") { store.previewHUD() }
    #if DEBUG
      let delayedProbe = ProcessInfo.processInfo.arguments.contains("--probe-microphone-delayed")
      if ProcessInfo.processInfo.arguments.contains("--probe-microphone") || delayedProbe {
        store.setPaused(true)
        Task {
          var report: [String: Any]
          do {
            if delayedProbe { try await Task.sleep(for: .seconds(6)) }
            let measurements = try await MicrophoneProbe.measure()
            report = [
              "startup_ms": measurements.map(\.readinessMilliseconds),
              "main_thread_setup_ms": measurements.map(\.synchronousSetupMilliseconds),
              "pid": ProcessInfo.processInfo.processIdentifier,
              "success": true,
            ]
          } catch { report = ["success": false, "error_code": (error as NSError).code] }
          if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
          {
            try? data.write(
              to: URL(fileURLWithPath: "/tmp/tok-microphone-probe.json"), options: .atomic)
          }
          store.setPaused(false)
        }
      }
    #endif
  }
  func applicationWillTerminate(_ notification: Notification) { store.stop() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard NSDocumentController.shared.hasEditedDocuments else { return .terminateNow }
    NSDocumentController.shared.reviewUnsavedDocuments(
      withAlertTitle: "Save vocabulary changes?", cancellable: true, delegate: self,
      didReviewAllSelector: #selector(reviewedDocuments(_:didReviewAll:contextInfo:)),
      contextInfo: nil)
    return .terminateLater
  }

  @objc private func reviewedDocuments(
    _ controller: NSDocumentController, didReviewAll: Bool, contextInfo: UnsafeMutableRawPointer?
  ) {
    NSApplication.shared.reply(toApplicationShouldTerminate: didReviewAll)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
