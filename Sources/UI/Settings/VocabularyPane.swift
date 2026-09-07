import SwiftUI

struct VocabularyPane: View {
  @Environment(DictationStore.self) private var store
  @State private var importMessage: String?
  @State private var importError: String?
  var body: some View {
    Form {
      Section("Editor") {
        Button("Open Vocabulary editor") { store.showVocabulary?() }
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
        if let importError { Text(importError).font(.caption).foregroundStyle(.red) }
        if let importMessage { Text(importMessage).font(.caption).foregroundStyle(.secondary) }
      }
      CatalogSections(group: .vocabulary)
    }
  }
}
