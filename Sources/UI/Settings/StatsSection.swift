// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TokEngine

/// The two stats tracking toggles with the controls that make them trustworthy.
struct StatsSection: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  @State private var confirmReset = false
  var body: some View {
    Section {
      ForEach(SettingCatalog.all.filter { ["STATS", "STATS_WORDS"].contains($0.key) }) { setting in
        SettingRow(setting: setting)
      }
      LabeledContent {
        HStack {
          Button("Open") { openWindow(id: "stats") }
          Button("Reset…", role: .destructive) { confirmReset = true }
        }
      } label: {
        Text("Stats database")
        Text("Counts and timing only, kept apart from history.").font(.caption)
          .foregroundStyle(.secondary)
      }
    } header: {
      Text("Dictation stats")
    } footer: {
      Text("Stats stay on this Mac and survive history retention and clearing.")
    }
    .confirmationDialog("Reset all dictation stats?", isPresented: $confirmReset) {
      Button("Reset stats", role: .destructive) { Task { await store.stats.clear() } }
    } message: {
      Text("Words, streaks, and time saved start again from zero. History and vocabulary are kept.")
    }
  }
}
