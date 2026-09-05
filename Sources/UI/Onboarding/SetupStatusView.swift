import AVFoundation
@preconcurrency import ApplicationServices
import SwiftUI
import TokEngine

struct SetupStatusView: View {
  @Environment(DictationStore.self) private var store
  var onDone: (() -> Void)?
  @State private var importError: String?
  @State private var importMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 8) {
        Label("Set up Tok", systemImage: "waveform").font(.title2.weight(.semibold))
        Text("Speak naturally. Your words appear where you’re writing.").foregroundStyle(.secondary)
      }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
      Form {
        Section {
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
        } header: {
          Text("Allow dictation")
        } footer: {
          Text(
            "Tok needs these permissions to capture your voice, detect the shortcut, and paste text. The microphone closes between dictations by default."
          )
        }
        APIKeySection()
        Section {
          if let setting = SettingCatalog.all.first(where: { $0.key == "HOTKEY" }) {
            SettingRow(setting: setting)
          }
          ShortcutCheckView()
        } header: {
          Text("Choose a shortcut")
        }
        Section {
          Button("Import JustSpeak settings…") {
            guard let url = FileDialogs.chooseConfiguration() else { return }
            do {
              importMessage = try store.settings.importConfiguration(from: url).message
              importError = nil
            } catch {
              importMessage = nil
              importError = "Choose a readable UTF-8 settings file no larger than 1 MB."
            }
          }
          Button("Add vocabulary from file…") {
            guard let url = FileDialogs.chooseVocabulary() else { return }
            do {
              importMessage = try store.settings.importVocabulary(from: url).message
              importError = nil
            } catch {
              importMessage = nil
              importError = "Choose a readable UTF-8 text file no larger than 1 MB."
            }
          }.disabled(store.settings.isOverridden("CUSTOM_VOCABULARY_FILE"))
          if let importError { Text(importError).foregroundStyle(.red).font(.caption) }
          if let importMessage { Text(importMessage).foregroundStyle(.secondary).font(.caption) }
        } footer: {
          Text(
            "Import is optional. Your key goes to Keychain. New vocabulary is added to your existing terms."
          )
        }
      }.formStyle(.grouped)
      Divider()
      HStack {
        Text(
          store.needsSetup
            ? "Complete the permissions and API-key steps."
            : "Ready. Open a document and try your shortcut."
        )
        .font(.callout).foregroundStyle(.secondary)
        Spacer()
        Button("Done") { onDone?() }.buttonStyle(.borderedProminent).disabled(store.needsSetup)
      }.padding(20)
    }.frame(minWidth: 540, idealWidth: 580, minHeight: 620, idealHeight: 700)
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
    NSWorkspace.shared.open(
      URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
  }
}
