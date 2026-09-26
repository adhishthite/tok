// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct VocabularySuggestionsView: View {
  @Bindable var model: VocabularyEditorModel
  let addSelected: () -> Void
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Review suggestions").font(.title2.weight(.semibold))
      Text("Choose terms and replacements that match what you mean.").foregroundStyle(.secondary)
      List(model.suggestions) { suggestion in
        Toggle(
          isOn: Binding(
            get: { model.selected.contains(suggestion.id) },
            set: {
              if $0 {
                model.selected.insert(suggestion.id)
              } else {
                model.selected.remove(suggestion.id)
              }
            })
        ) {
          HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
              Text(suggestion.line).font(.system(.body, design: .monospaced))
              Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let confidence = suggestion.confidence {
              Text("\(Int((confidence * 100).rounded()))%")
                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                .help(
                  "Jev's rating: how distinctive a term is, or how safe a replacement rule is.")
            }
          }.padding(.vertical, 4)
        }.toggleStyle(.checkbox)
      }
      HStack {
        Button("Cancel") { dismiss() }
          .keyboardShortcut(.cancelAction)
        Spacer()
        Button("Add selected", action: addSelected).buttonStyle(.borderedProminent).disabled(
          model.selected.isEmpty
        )
        .keyboardShortcut(.defaultAction)
      }
    }.padding(24).frame(width: 540, height: 450)
  }
}
