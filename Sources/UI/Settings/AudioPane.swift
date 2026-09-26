// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct AudioPane: View {
  var body: some View {
    Form { CatalogSections(group: .audio) }
  }
}
