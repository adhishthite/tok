import SwiftUI

@main
struct TokApp: App {
  var body: some Scene {
    MenuBarExtra("Tok", systemImage: "waveform") {
      StatusMenu()
    }
    .menuBarExtraStyle(.window)
  }
}
