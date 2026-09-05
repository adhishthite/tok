import AppKit
import SwiftUI

@MainActor
final class SetupWindow {
  private var controller: NSWindowController?

  func show(store: DictationStore) {
    if controller == nil {
      let content = SetupStatusView().environment(store)
      let window = NSWindow(contentViewController: NSHostingController(rootView: content))
      window.title = "Set up Tok"
      window.styleMask = [.titled, .closable, .miniaturizable]
      window.setContentSize(NSSize(width: 500, height: 440))
      window.center()
      window.setFrameAutosaveName("TokSetup")
      controller = NSWindowController(window: window)
    }
    controller?.showWindow(nil)
    controller?.window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    store.reportRuntime()
  }
}
