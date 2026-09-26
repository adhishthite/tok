// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AppearancePane: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Form {
      CatalogSections(group: .appearance) { setting in
        if setting.key == "HUD_REVEAL" {
          Button("Preview overlay") { store.previewHUD() }
        }
      }
    }
  }
}
