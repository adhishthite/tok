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
        if group == .general {
          LoginItemSection()
          UpdateSection()
        }
        if group == .history { HistoryRetentionSection() }
        if group == .vocabulary {
          Section {
            Button("Open Vocabulary editor") { store.showVocabulary?() }
            Button("Add vocabulary from file…") {
              guard let url = FileDialogs.chooseVocabulary() else { return }
              do {
                importResult = try store.settings.importVocabulary(from: url).message
              } catch {
                importResult = "Choose a readable UTF-8 text file no larger than 1 MB."
              }
            }.disabled(store.settings.isOverridden("CUSTOM_VOCABULARY_FILE"))
            if let importResult { Text(importResult).font(.caption).foregroundStyle(.secondary) }
          }
        }
        if group == .appearance {
          Section { Button("Preview overlay") { store.previewHUD() } }
        }
        Section {
          ForEach(
            SettingCatalog.all.filter { $0.group == group && $0.key != "HISTORY_RETENTION_DAYS" }
          ) { setting in
            SettingRow(setting: setting)
          }
        }
        if group == .general {
          Section {
            Button("Review permissions") { store.showSetup?() }
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
    .toolbar(removing: .sidebarToggle)
    .frame(minWidth: 680, idealWidth: 740, minHeight: 480, idealHeight: 580)
    .confirmationDialog("Reset Tok’s settings?", isPresented: $confirmReset) {
      Button("Reset settings", role: .destructive) { store.settings.reset() }
    } message: {
      Text("Your API key, history, and vocabulary are kept.")
    }
  }
}
