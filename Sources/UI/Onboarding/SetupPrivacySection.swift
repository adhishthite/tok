// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TokEngine

/// The privacy step of setup: what leaves the Mac, and the metrics choice, off by default.
struct SetupPrivacySection: View {
  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: 6) {
        Text("Audio goes to the Gemini API only while you dictate. Tok keeps no audio.")
        Text("Dictation history stays in a local database you control.")
        Text("Your API key stays in the macOS Keychain.")
      }.fixedSize(horizontal: false, vertical: true)
      if let setting = SettingCatalog.all.first(where: { $0.key == "SHARE_USAGE_METRICS" }) {
        SettingRow(setting: setting)
      }
    } header: {
      Text("Privacy")
    } footer: {
      HStack {
        Text("You can change this any time in Settings > Privacy.")
        Spacer()
        Button("Privacy details") { PrivacyDocument.open() }.controlSize(.small)
      }
    }
  }
}
