import SwiftUI

/// Home for optional, off-by-default features. Nothing here runs until it is configured,
/// so the pane only reports whether a key exists; the judgment probe result lives in the
/// engine (`JudgmentService.isAvailable`) and is never guessed at here.
struct ExperimentalPane: View {
  @Environment(DictationStore.self) private var store
  private var keyConfigured: Bool {
    store.settings.hasTypeSafeKey || store.settings.typesafeApiKeyProvidedByEnvironment
  }
  var body: some View {
    Form {
      Section {
        Text(
          "Experimental features are optional. They stay off until you configure them, and their behavior may change."
        )
        .foregroundStyle(.secondary)
        if keyConfigured {
          Label(
            "TypeSafe key configured. Jev judgments run after Tok verifies the key.",
            systemImage: "checkmark.circle")
        } else {
          Text(
            "Jev judgments (correction scoring, analyzer confidence, and per-turn quality signals in history) turn on once you save a valid TypeSafe key below."
          )
        }
      }
      TypeSafeKeySection()
    }
  }
}
