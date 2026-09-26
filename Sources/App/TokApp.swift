// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

@main
struct TokApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
  var body: some Scene {
    MenuBarExtra {
      StatusMenu().environment(delegate.store)
    } label: {
      MenuBarLabel().environment(delegate.store)
    }.menuBarExtraStyle(.window)
    Settings { SettingsView().environment(delegate.store) }
      .windowToolbarStyle(.unifiedCompact)
    Window("History", id: "history") { HistoryView().environment(delegate.store) }
      .defaultSize(width: 1000, height: 640)
    Window("Stats", id: "stats") { StatsView().environment(delegate.store) }
      .defaultSize(width: 1040, height: 760)
    Window("Tok diagnostics", id: "diagnostics") {
      DiagnosticsView().environment(delegate.store)
    }.defaultSize(width: 760, height: 480)
  }
}
