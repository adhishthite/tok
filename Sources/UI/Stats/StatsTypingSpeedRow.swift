// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The typing speed behind the time-saved estimate, editable in place. It is the
/// TYPING_WPM setting, so it also appears in Settings > General.
struct StatsTypingSpeedRow: View {
  @Environment(DictationStore.self) private var store
  private static let key = "TYPING_WPM"
  private static let range = 10...200
  var body: some View {
    HStack(spacing: 8) {
      Text("Time saved assumes you type at").foregroundStyle(.secondary)
      TextField("Typing speed", value: binding, format: .number.grouping(.never))
        .labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        .frame(width: 52)
      Stepper("Typing speed", value: binding, in: Self.range, step: 5).labelsHidden()
      Text("words per minute.").foregroundStyle(.secondary)
      if store.settings.isOverridden(Self.key) {
        Label("Set by environment", systemImage: "terminal").foregroundStyle(.secondary)
      }
    }
    .font(.callout)
    .disabled(store.settings.isOverridden(Self.key))
  }
  private var binding: Binding<Int> {
    Binding(
      get: { Int(store.settings.string(Self.key)) ?? 40 },
      set: {
        store.settings.set(
          Self.key, String(min(Self.range.upperBound, max(Self.range.lowerBound, $0))))
      })
  }
}
