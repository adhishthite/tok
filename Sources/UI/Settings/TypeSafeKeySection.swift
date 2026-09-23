import SwiftUI

/// Optional upgrade (see Engine/Judgment, POSTPROCESSING.md-style precedent). Mirrors
/// APIKeySection's Test/Save flow for the TypeSafe key.
struct TypeSafeKeySection: View {
  @Environment(DictationStore.self) private var store
  @State private var key = ""
  @State private var checkStatus: ConnectionCheckStatus = .unchecked
  @State private var result: String?
  @State private var checkTask: Task<Void, Never>?
  private var testing: Bool { checkStatus == .checking }
  var body: some View {
    Section {
      LabeledContent("TypeSafe API key") {
        SecureField(
          "TypeSafe API key", text: $key,
          prompt: Text(
            store.settings.hasTypeSafeKey ? "Paste a new key" : "Paste your TypeSafe API key")
        )
        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 280)
        .autocorrectionDisabled()
        .disabled(store.settings.typesafeApiKeyProvidedByEnvironment || testing)
      }
      .onChange(of: key) {
        if !testing && (!key.isEmpty || checkStatus == .failed) {
          invalidateCheck()
        }
      }
      HStack {
        Button(key.isEmpty ? "Test connection" : "Test and save") {
          let candidate = key
          checkStatus = .checking
          result = nil
          checkTask = Task {
            do {
              if candidate.isEmpty {
                try await store.settings.testTypeSafeConnection()
              } else {
                try await store.settings.validateAndSaveTypeSafeKey(candidate)
                try Task.checkCancellation()
                key = ""
              }
              try Task.checkCancellation()
              checkStatus = .connected
            } catch {
              guard !Task.isCancelled else { return }
              result = error.localizedDescription
              checkStatus = .failed
            }
          }
        }.disabled(testing || (key.isEmpty && !store.settings.hasTypeSafeKey))
        Spacer()
        if checkStatus != .unchecked {
          HStack(spacing: 6) {
            if testing {
              ProgressView().controlSize(.small)
              Text(checkStatus.label)
            } else {
              Label(checkStatus.label, systemImage: checkStatus.symbol)
            }
          }
          .font(.callout.weight(.medium))
          .foregroundStyle(checkStatus.color)
          .padding(.horizontal, 10).padding(.vertical, 5)
          .background(checkStatus.color.opacity(0.12), in: Capsule())
          .accessibilityElement(children: .combine)
          .help("Result of the latest connection test.")
        }
      }
      if store.settings.typesafeApiKeyProvidedByEnvironment {
        Text("API key supplied by environment.").font(.caption).foregroundStyle(.secondary)
      }
      Link("Get a TypeSafe API key", destination: URL(string: "https://typesafe.ai")!)
        .font(.callout)
      if let result { Text(result).font(.callout).foregroundStyle(.red) }
    } header: {
      Text("TypeSafe judgments (optional)")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if store.settings.hasTypeSafeKey {
          Label("Saved in Keychain", systemImage: "checkmark.shield")
        }
        if let typesafeKeyError = store.settings.typesafeKeyError {
          Label(typesafeKeyError, systemImage: "exclamationmark.triangle")
            .foregroundStyle(.orange)
        }
        Text(
          "Optional upgrade. When a key is saved and verified, transcript text, typed-correction word pairs with their surrounding sentence, and the destination app name and bundle identifier are sent to api.typesafe.ai for scoring, to catch garbled dictations and confirm genuine corrections. Audio is never sent. Leave this blank and nothing is sent to TypeSafe and nothing else changes."
        )
      }
    }
    .onChange(of: store.settings.values) { invalidateCheck() }
    .onChange(of: store.settings.overrides) { invalidateCheck() }
    .onDisappear { invalidateCheck() }
  }

  private func invalidateCheck() {
    checkTask?.cancel()
    checkTask = nil
    checkStatus = .unchecked
    result = nil
  }
}
