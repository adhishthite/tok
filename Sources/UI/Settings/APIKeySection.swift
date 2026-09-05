import SwiftUI

struct APIKeySection: View {
  @Environment(DictationStore.self) private var store
  @State private var key = ""
  @State private var testing = false
  @State private var result: String?
  @State private var failed = false
  var body: some View {
    Section {
      SecureField(store.settings.hasAPIKey ? "Replace API key" : "Gemini API key", text: $key)
        .autocorrectionDisabled()
        .disabled(store.settings.apiKeyProvidedByEnvironment)
      HStack {
        if testing { ProgressView().controlSize(.small) }
        Button(key.isEmpty ? "Test connection" : "Test and save") {
          testing = true
          result = nil
          Task {
            do {
              if key.isEmpty {
                try await store.settings.testConnection()
              } else {
                try await store.settings.validateAndSaveAPIKey(key)
                key = ""
              }
              result = "Connected. You’re ready to dictate."
              failed = false
            } catch {
              result = error.localizedDescription
              failed = true
            }
            testing = false
          }
        }.disabled(testing || (key.isEmpty && !store.settings.hasAPIKey))
        if store.settings.hasAPIKey {
          Label("Saved in Keychain", systemImage: "checkmark.shield").font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      if store.settings.apiKeyProvidedByEnvironment {
        Text("API key supplied by environment.").font(.caption).foregroundStyle(.secondary)
      }
      Link("Get an API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
        .font(.callout)
      if let result { Text(result).font(.callout).foregroundStyle(failed ? .red : .secondary) }
    } header: {
      Text("Gemini connection")
    } footer: {
      Text(
        "Your key stays in the macOS Keychain. Tok sends audio to Gemini only while you dictate.")
    }
  }
}
