import SwiftUI

struct StatusMenu: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 10) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable().interpolation(.high).frame(width: 36, height: 36)
          .accessibilityHidden(true)
        Text("Tok").font(.title3.weight(.semibold))
        // The version sits beside the name so a support report and a screenshot both
        // identify the build without opening About.
        Text(BuildIdentity.version).font(.caption).foregroundStyle(.tertiary)
          .padding(.top, 3)
        Spacer()
        Text(store.isPaused ? "Paused" : store.shortcutLabel)
          .font(.system(.callout, design: .rounded).weight(.medium))
          .foregroundStyle(.secondary)
          .padding(.horizontal, 8).padding(.vertical, 4)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
      }
      if store.needsSetup {
        Text("Finish setup to start dictating.").foregroundStyle(.secondary)
        Button("Set up Tok") { store.showSetup?() }.buttonStyle(.borderedProminent)
      } else {
        // The last error no longer hides the transcript and the Copy button: a failed
        // delivery is exactly when the words are needed most (audit F04).
        if let error = store.lastError { errorRow(error) }
        if !store.settings.bool("PRIVACY_MODE"), !store.lastText.isEmpty {
          if let delivery = store.lastDelivery {
            Text(delivery).font(.caption).foregroundStyle(.secondary)
          }
          Text(store.lastText).font(.callout).lineLimit(4).textSelection(.enabled)
          Button("Copy last dictation", systemImage: "doc.on.doc") { store.copyLastDictation() }
            .buttonStyle(.borderless).font(.callout)
        } else if store.lastError == nil {
          Text(store.isPaused ? "Resume when you’re ready." : prompt)
            .font(.callout).foregroundStyle(.secondary)
        }
      }
      navigationButton("Vocabulary", symbol: "character.book.closed") {
        store.showVocabulary?()
      }
      navigationButton("History", symbol: "clock") { show("history") }
      navigationButton("Stats", symbol: "chart.bar.xaxis", detail: statsDetail) {
        show("stats")
      }
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
        Button("Settings…") { showSettings() }.keyboardShortcut(",")
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
    .onAppear {
      store.refreshPermissions()
      store.stats.refreshGlance()
    }
  }
  private var prompt: String {
    ShortcutPrompt.menu(
      shortcut: store.shortcutLabel,
      toggleMode: store.settings.string("HOTKEY_MODE") == "toggle")
  }
  private func errorRow(_ error: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      Text(error).font(.callout).foregroundStyle(.secondary)
      Spacer(minLength: 0)
      // Reachable outside DEBUG, unlike the Developer-menu entry below (audit F36).
      Button("Diagnostics") { show("diagnostics") }
        .buttonStyle(.borderless).font(.caption).foregroundStyle(.secondary)
        .help("Opens timing, warnings, and errors for this dictation.")
      Button("Dismiss", systemImage: "xmark.circle") { store.dismissLastError() }
        .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
        .help("Dismisses the last dictation error.")
    }
  }
  private var statsDetail: String? {
    let words = store.stats.wordsToday
    return words > 0 ? "\(StatsFormat.count(words)) today" : nil
  }
  private func navigationButton(
    _ title: String, symbol: String, detail: String? = nil,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 10) {
        // Plain template symbols, as in the system's own menus. Colored tiles read as a
        // consumer app, not a utility.
        Image(systemName: symbol)
          .font(.system(size: 15, weight: .regular)).foregroundStyle(.secondary)
          .frame(width: 22, height: 22)
          .accessibilityHidden(true)
        Text(title).font(.callout).foregroundStyle(.primary)
        Spacer()
        if let detail { Text(detail).font(.caption).foregroundStyle(.tertiary) }
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
          .accessibilityHidden(true)
      }.padding(.vertical, 3).contentShape(.rect)
    }.buttonStyle(.borderless)
  }
  private func show(_ id: String) {
    openWindow(id: id)
    focusWindow(identifier: id)
  }
  /// `SettingsLink` neither closes this panel nor focuses the new window.
  private func showSettings() {
    openSettings()
    focusWindow(identifier: "com_apple_SwiftUI_Settings_window")
  }
  /// A menu-bar-only app is inactive while this panel is open, so a window
  /// SwiftUI opens stays behind the previous app until it is made key, which
  /// is what activation alone failed to do on macOS 14 and 15.
  private func focusWindow(identifier: String) {
    DispatchQueue.main.async {
      let windows = NSApplication.shared.windows
      let window = windows.first { $0.identifier?.rawValue == identifier }
      window?.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }
}
