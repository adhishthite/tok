import SwiftUI

struct StatusMenu: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack {
        Label("Tok", systemImage: store.status.symbol).font(.headline)
        Spacer()
        Text(store.status.rawValue).font(.caption).foregroundStyle(.secondary)
      }
      Text(store.message).font(.callout)
      if !store.liveText.isEmpty {
        Text(store.liveText).lineLimit(3).foregroundStyle(.secondary)
      } else if !store.lastText.isEmpty {
        Text(store.lastText).lineLimit(3).textSelection(.enabled)
      }
      if !store.permissions.allGranted || !store.settings.hasAPIKey {
        Button("Set up Tok") { show("setup") }.buttonStyle(.borderedProminent)
      }
      Divider()
      HStack {
        Button("Diagnostics") { show("diagnostics") }
        Spacer()
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
      }
    }
    .padding(20).frame(width: 340, alignment: .leading)
    .onAppear { store.refreshPermissions() }
  }
  private func show(_ id: String) {
    openWindow(id: id)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
