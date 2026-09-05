import SwiftUI

struct StatusMenu: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .firstTextBaseline) {
        Text("Tok").font(.headline)
        Spacer()
        Text(store.isPaused ? "Paused" : store.shortcutLabel).font(.callout).foregroundStyle(
          .secondary)
      }
      if store.needsSetup {
        Text("Finish setup to start dictating.").foregroundStyle(.secondary)
        Button("Set up Tok") { store.showSetup?() }.buttonStyle(.borderedProminent)
      } else if store.status == .error {
        Text(store.message).font(.callout)
      } else if !store.lastText.isEmpty {
        Text(store.lastText).font(.callout).lineLimit(4).textSelection(.enabled)
        Button("Copy last dictation", systemImage: "doc.on.doc") { store.copyLastDictation() }
          .buttonStyle(.borderless).font(.callout)
      } else {
        Text(
          store.isPaused ? "Resume when you’re ready." : "Hold \(store.shortcutLabel) and speak."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
      Button("History…", systemImage: "clock") { show("history") }
        .buttonStyle(.borderless).font(.callout)
      Divider()
      Toggle(
        "Hide dictated words",
        isOn: Binding(
          get: { store.settings.bool("PRIVACY_MODE") },
          set: { store.settings.set("PRIVACY_MODE", String($0)) })
      )
      .toggleStyle(.checkbox).controlSize(.small)
      Toggle(
        "Play sounds",
        isOn: Binding(
          get: { store.settings.bool("SOUND_FEEDBACK") },
          set: { store.settings.set("SOUND_FEEDBACK", String($0)) })
      )
      .toggleStyle(.checkbox).controlSize(.small)
      Divider()
      HStack {
        SettingsLink { Text("Settings…") }.keyboardShortcut(",")
        Spacer()
        Button(store.isPaused ? "Resume" : "Pause") { store.setPaused(!store.isPaused) }
        Button("Quit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
      }.controlSize(.small)
      #if DEBUG
        Menu("Developer") {
          Button("Preview overlay") { store.previewHUD() }
          Button("Diagnostics") { show("diagnostics") }
        }.menuStyle(.borderlessButton).font(.caption).foregroundStyle(.secondary)
      #endif
    }
    .padding(18).frame(width: 300, alignment: .leading)
    .onAppear { store.refreshPermissions() }
  }
  private func show(_ id: String) {
    openWindow(id: id)
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
