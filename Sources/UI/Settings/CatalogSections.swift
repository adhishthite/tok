// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TokEngine

/// Renders a group's catalog rows as headed sections. `trailing` can add a row
/// after a specific setting, such as an action that belongs beside it.
struct CatalogSections<Trailing: View>: View {
  let group: SettingGroup
  var excluding: Set<String> = []
  @ViewBuilder let trailing: (SettingDefinition) -> Trailing

  var body: some View {
    ForEach(CatalogSection.sections(for: group, excluding: excluding)) { section in
      Section(section.title) {
        ForEach(section.settings) { setting in
          SettingRow(setting: setting)
          trailing(setting)
        }
      }
    }
  }
}

extension CatalogSections where Trailing == EmptyView {
  init(group: SettingGroup, excluding: Set<String> = []) {
    self.init(group: group, excluding: excluding) { _ in EmptyView() }
  }
}
