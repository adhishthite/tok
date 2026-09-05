import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = DictationStore()
  private let setupWindow = SetupWindow()
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    store.showSetup = { [weak self] in
      guard let self else { return }
      self.setupWindow.show(store: self.store)
    }
    store.start()
    if store.needsSetup || ProcessInfo.processInfo.arguments.contains("--show-setup") {
      setupWindow.show(store: store)
    }
    if ProcessInfo.processInfo.arguments.contains("--hud-demo") { store.previewHUD() }
  }
  func applicationWillTerminate(_ notification: Notification) { store.stop() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
