// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct MenuBarLabel: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Image(systemName: store.status.symbol)
      .accessibilityLabel("Tok, \(store.status.rawValue)")
  }
}
