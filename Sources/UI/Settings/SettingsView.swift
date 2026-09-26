// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TokEngine

struct SettingsView: View {
  @State private var selection: SettingGroup? = .general
  var body: some View {
    NavigationSplitView {
      List(SettingGroup.allCases, selection: $selection) { group in
        Label(group.rawValue, systemImage: group.symbol).tag(group)
      }
      .navigationSplitViewColumnWidth(min: 170, ideal: 185, max: 210)
      .toolbar(removing: .sidebarToggle)
    } detail: {
      SettingsPane(group: selection ?? .general)
    }
    .frame(minWidth: 680, idealWidth: 740, minHeight: 480, idealHeight: 580)
  }
}
