import SwiftUI

struct StatusMenu: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Tok", systemImage: "waveform")
        .font(.headline)
      Text("Dictation engine is not connected yet.")
        .foregroundStyle(.secondary)
      Divider()
      Button("Quit Tok") { NSApplication.shared.terminate(nil) }
        .keyboardShortcut("q")
    }
    .padding(20)
    .frame(width: 300, alignment: .leading)
  }
}
