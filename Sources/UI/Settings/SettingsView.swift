import SwiftUI
import TokEngine

struct SettingsView: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @State private var selection: SettingGroup? = .general
  @State private var importResult: String?
  @State private var confirmReset = false
  private var group: SettingGroup { selection ?? .general }
  var body: some View {
    NavigationSplitView {
      List(SettingGroup.allCases, selection: $selection) { group in
        Label(group.rawValue, systemImage: group.symbol).tag(group)
      }.navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 210)
    } detail: {
      Form {
        if group == .transcription { APIKeySection() }
        if group == .vocabulary {
          Section { Button("Open Vocabulary editor") { store.showVocabulary?() } }
        }
        if group == .appearance {
          Section { Button("Preview overlay") { store.previewHUD() } }
        }
        Section {
          ForEach(SettingCatalog.all.filter { $0.group == group }) { setting in
            SettingRow(setting: setting)
          }
        }
        if group == .general {
          Section {
            Button("Review permissions") { store.showSetup?() }
            Button("Import JustSpeak settings…") {
              guard let url = FileDialogs.chooseConfiguration() else { return }
              do {
                try store.settings.importConfiguration(from: url)
                importResult = "Settings and available vocabulary imported."
              } catch {
                importResult = "Could not import this file. Choose a readable JustSpeak .env file."
              }
            }
            if let importResult { Text(importResult).font(.caption).foregroundStyle(.secondary) }
          }
        }
        if group == .advanced {
          Section {
            Button("Open diagnostics") { openWindow(id: "diagnostics") }
            Button("Reset settings…", role: .destructive) { confirmReset = true }
          }
        }
        if store.settingsPending {
          Text("Changes will apply after this dictation.").font(.caption).foregroundStyle(
            .secondary)
        }
      }
      .formStyle(.grouped)
      .navigationTitle(group.rawValue)
    }
    .frame(minWidth: 680, idealWidth: 740, minHeight: 480, idealHeight: 580)
    .confirmationDialog("Reset Tok’s settings?", isPresented: $confirmReset) {
      Button("Reset settings", role: .destructive) { store.settings.reset() }
    } message: {
      Text("Your API key, history, and vocabulary are kept.")
    }
  }
}
