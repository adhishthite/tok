// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AdvancedPane: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @State private var confirmReset = false
  var body: some View {
    Form {
      CatalogSections(group: .advanced)
      Section("Maintenance") {
        Button("Open diagnostics") { openWindow(id: "diagnostics") }
        Button("Reset settings…", role: .destructive) { confirmReset = true }
      }
    }
    .confirmationDialog("Reset Tok’s settings?", isPresented: $confirmReset) {
      Button("Reset settings", role: .destructive) { store.settings.reset() }
    } message: {
      Text("Your API key, history, and vocabulary are kept.")
    }
  }
}
