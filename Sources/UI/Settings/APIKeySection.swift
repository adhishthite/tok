// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct APIKeySection: View {
  @Environment(DictationStore.self) private var store
  @State private var key = ""
  @State private var checkStatus: ConnectionCheckStatus = .unchecked
  @State private var result: String?
  @State private var checkTask: Task<Void, Never>?
  private var testing: Bool { checkStatus == .checking }
  var body: some View {
    Section {
      LabeledContent("API key") {
        SecureField(
          "API key", text: $key,
          prompt: Text(store.settings.hasAPIKey ? "Paste a new key" : "Paste your Gemini API key")
        )
        .labelsHidden().textFieldStyle(.roundedBorder).frame(width: 280)
        .autocorrectionDisabled()
        .disabled(store.settings.apiKeyProvidedByEnvironment || testing)
      }
      .onChange(of: key) {
        // A successful save clears the field. Editing a new candidate key
        // invalidates the prior check without implying it was saved.
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
                try await store.settings.testConnection()
              } else {
                try await store.settings.validateAndSaveAPIKey(candidate)
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
        }.disabled(testing || (key.isEmpty && !store.settings.hasAPIKey))
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
      if store.settings.apiKeyProvidedByEnvironment {
        Text("API key supplied by environment.").font(.caption).foregroundStyle(.secondary)
      }
      Link("Get an API key", destination: URL(string: "https://aistudio.google.com/apikey")!)
        .font(.callout)
      if let result { Text(result).font(.callout).foregroundStyle(.red) }
    } header: {
      Text("Gemini connection")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if store.settings.hasAPIKey {
          Label("Saved in Keychain", systemImage: "checkmark.shield")
        }
        Text(
          "Your key stays in the macOS Keychain. Tok sends audio to Gemini only while you dictate.")
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
