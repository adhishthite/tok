import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  let store = DictationStore()
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    store.start()
  }
  func applicationWillTerminate(_ notification: Notification) { store.stop() }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
