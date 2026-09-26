// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import TokEngine

struct ShortcutCheckView: View {
  @Environment(DictationStore.self) private var store
  @State private var monitor: Any?
  @State private var armed = false
  @State private var detected = false
  @State private var result: String?
  @State private var timeout: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Button(armed ? "Press \(store.shortcutLabel)…" : "Test shortcut") {
          armed = true
          detected = false
          result = nil
          store.setShortcutTesting(true)
          timeout?.cancel()
          timeout = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            finish(message: "No key detected. Try another shortcut.", success: false)
          }
        }.disabled(armed || store.dictationActive)
        if detected {
          Label("Shortcut detected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        }
      }
      if let result { Text(result).font(.caption).foregroundStyle(.secondary) }
      if store.hotkey == "fn" {
        Text(
          "Set “Press Globe key to” to “Do Nothing” in Keyboard settings. Some external keyboards do not send Fn to macOS."
        )
        .font(.caption).foregroundStyle(.secondary)
        Button("Open Keyboard settings") {
          NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!)
        }.font(.callout)
      }
    }
    .onAppear {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
        let code = event.keyCode
        let consumed = MainActor.assumeIsolated {
          guard armed, code == ShortcutSupport.keyCode(for: store.hotkey) else { return false }
          finish(message: "Shortcut works.", success: true)
          return true
        }
        return consumed ? nil : event
      }
    }
    .onDisappear {
      if let monitor { NSEvent.removeMonitor(monitor) }
      timeout?.cancel()
      store.setShortcutTesting(false)
    }
  }

  private func finish(message: String, success: Bool) {
    armed = false
    detected = success
    result = message
    timeout?.cancel()
    store.setShortcutTesting(false)
  }
}
