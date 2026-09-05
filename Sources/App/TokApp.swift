import SwiftUI

@main
struct TokApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  var body: some Scene {
    MenuBarExtra {
      StatusMenu().environment(delegate.store)
    } label: {
      MenuBarLabel().environment(delegate.store)
    }.menuBarExtraStyle(.window)
    Settings { SettingsView().environment(delegate.store) }
    Window("Tok diagnostics", id: "diagnostics") {
      DiagnosticsView().environment(delegate.store)
    }.defaultSize(width: 760, height: 480)
  }
}
