// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct TranscriptionPane: View {
  var body: some View {
    Form {
      APIKeySection()
      CatalogSections(group: .transcription)
    }
  }
}
