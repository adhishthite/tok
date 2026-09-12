import SwiftUI

struct VocabularyView: View {
  @Bindable var model: VocabularyEditorModel
  let save: () -> Void
  let analyze: () -> Void
  let cancelAnalysis: () -> Void
  let addSelected: () -> Void
  @State private var confirmAnalysis = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Words that sound like you").font(.title2.weight(.semibold))
        Text("Add one term per line. Use wrong => right for a replacement.").foregroundStyle(
          .secondary)
      }.padding(22)
      Divider()
      TextEditor(text: $model.contents)
        .font(.system(.body, design: .monospaced))
        .autocorrectionDisabled()
        .padding(12)
        .accessibilityLabel("Vocabulary terms and replacement rules")
      Divider()
      HStack {
        if model.analyzing {
          ProgressView().controlSize(.small)
          Text("Finding suggestions…").font(.callout)
          Button("Cancel", action: cancelAnalysis)
        } else {
          Button("Analyze history…", systemImage: "sparkles") { confirmAnalysis = true }
            .help("Find vocabulary terms and replacements from saved dictations.")
        }
        Spacer()
        Button("Save", action: save).keyboardShortcut("s")
      }.padding(16)
      if let message = model.message {
        Text(message).font(.callout).foregroundStyle(.secondary).padding(
          [.horizontal, .bottom], 16)
      }
    }
    .frame(minWidth: 620, minHeight: 420)
    .confirmationDialog("Find vocabulary suggestions?", isPresented: $confirmAnalysis) {
      Button("Analyze history", action: analyze)
    } message: {
      Text(
        "This sends up to 500 saved dictations from the last 30 days, the app you dictated each one into, your vocabulary, and observed word corrections to Gemini. No timestamps are sent. You choose which suggestions to add."
      )
    }
    .sheet(
      isPresented: Binding(
        get: { !model.suggestions.isEmpty },
        set: {
          if !$0 {
            model.suggestions = []
            model.selected = []
          }
        })
    ) {
      VocabularySuggestionsView(model: model, addSelected: addSelected)
    }
  }
}
