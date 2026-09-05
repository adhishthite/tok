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
          VStack(alignment: .leading, spacing: 4) {
            Text(suggestion.line).font(.system(.body, design: .monospaced))
            Text(suggestion.reason).font(.caption).foregroundStyle(.secondary)
          }.padding(.vertical, 4)
        }.toggleStyle(.checkbox)
      }
      HStack {
        Button("Cancel") { dismiss() }
        Spacer()
        Button("Add selected", action: addSelected).buttonStyle(.borderedProminent).disabled(
          model.selected.isEmpty)
      }
    }.padding(24).frame(width: 540, height: 450)
  }
}
