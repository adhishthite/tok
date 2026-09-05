import SwiftUI

@main
struct TokApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  var body: some Scene {
    MenuBarExtra(
      "Tok: \(delegate.store.status.rawValue)", systemImage: delegate.store.status.symbol
    ) {
      StatusMenu().environment(delegate.store)
    }.menuBarExtraStyle(.window)
    Window("Tok setup", id: "setup") {
      SetupStatusView().environment(delegate.store)
    }.defaultSize(width: 480, height: 380)
    Window("Tok diagnostics", id: "diagnostics") {
      DiagnosticsView().environment(delegate.store)
    }.defaultSize(width: 760, height: 480)
  }
}
