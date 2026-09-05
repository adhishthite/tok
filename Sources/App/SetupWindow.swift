import AppKit
import SwiftUI

@MainActor
final class SetupWindow: NSObject, NSWindowDelegate {
  private weak var store: DictationStore?
  private var controller: NSWindowController?

  func show(store: DictationStore) {
    self.store = store
    if controller == nil {
      let content = SetupStatusView(onDone: { [weak self] in self?.controller?.close() })
        .environment(store)
      let window = NSWindow(contentViewController: NSHostingController(rootView: content))
      window.title = "Set up Tok"
      window.delegate = self
      window.contentMinSize = NSSize(width: 540, height: 620)
      window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
      window.setContentSize(NSSize(width: 580, height: 700))
      window.center()
      window.setFrameAutosaveName("TokSetup")
      controller = NSWindowController(window: window)
    }
    controller?.showWindow(nil)
    controller?.window?.makeKeyAndOrderFront(nil)
    NSApplication.shared.activate(ignoringOtherApps: true)
    store.reportRuntime()
  }
  func windowWillClose(_ notification: Notification) {
    store?.setShortcutTesting(false)
    controller = nil
  }

}
