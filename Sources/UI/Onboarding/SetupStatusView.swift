import AVFoundation
@preconcurrency import ApplicationServices
import SwiftUI

struct SetupStatusView: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Set up Tok").font(.title2.bold())
      Text("Three permissions let Tok hear your voice, detect the hotkey, and paste your words.")
        .foregroundStyle(.secondary)
      permission("Microphone", granted: store.permissions.microphone) {
        Task {
          _ = await AVCaptureDevice.requestAccess(for: .audio)
          store.refreshPermissions()
          if !store.permissions.microphone { openPane("Privacy_Microphone") }
        }
      }
      permission("Accessibility", granted: store.permissions.accessibility) {
        let options =
          [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPane("Privacy_Accessibility")
      }
      permission("Input Monitoring", granted: store.permissions.inputMonitoring) {
        _ = CGRequestListenEventAccess()
        openPane("Privacy_ListenEvent")
      }
      Label(
        store.settings.hasAPIKey ? "API key loaded securely" : "API key not configured",
        systemImage: store.settings.hasAPIKey ? "checkmark.circle.fill" : "key")
      Text("For Fn: System Settings → Keyboard → Press 🌐 key to → Do Nothing.").font(.callout)
        .foregroundStyle(.secondary)
      Text(store.message).font(.callout)
    }.padding(28).frame(minWidth: 460, minHeight: 360)
      .task {
        while !Task.isCancelled {
          store.refreshPermissions()
          try? await Task.sleep(for: .seconds(1))
        }
      }
  }
  private func permission(_ name: String, granted: Bool, action: @escaping () -> Void) -> some View
  {
    HStack {
      Label(name, systemImage: granted ? "checkmark.circle.fill" : "circle")
      Spacer()
      if granted {
        Text("Allowed").foregroundStyle(.secondary)
      } else {
        Button("Enable", action: action).accessibilityLabel("Enable \(name)")
      }
    }
  }
  private func openPane(_ anchor: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
      NSWorkspace.shared.open(url)
    }
  }
}
