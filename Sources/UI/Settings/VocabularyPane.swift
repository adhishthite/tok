// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TokEngine

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
        Text(termSummary).font(.caption).foregroundStyle(dropped > 0 ? .orange : .secondary)
      }
      CatalogSections(group: .vocabulary)
    }
  }
  private var dropped: Int { store.settings.configuration.customVocabularyDropped }
  private var termSummary: String {
    let count = store.settings.configuration.recognitionVocabulary.count
    if dropped > 0 {
      return
        "\(count) terms sent. \(dropped) more exceed the \(EngineConfiguration.vocabularyLimit)-term limit and are not sent."
    }
    if count > EngineConfiguration.vocabularyRecommended {
      return
        "\(count) terms sent. Recognition works best near \(EngineConfiguration.vocabularyRecommended) terms."
    }
    return count == 1 ? "1 term sent for recognition." : "\(count) terms sent for recognition."
  }
}
