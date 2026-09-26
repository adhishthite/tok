// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// One headline number with a caption and an optional comparison line.
struct StatsTile: View {
  let title: String
  let value: String
  var detail: String? = nil
  var rising: Bool? = nil
  var body: some View {
    StatsCard {
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.caption).foregroundStyle(.secondary)
        Text(value)
          .font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
          .contentTransition(.numericText())
          .lineLimit(1).minimumScaleFactor(0.7)
        if let detail {
          HStack(spacing: 4) {
            if let rising {
              Image(systemName: rising ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(rising ? Color.green : Color.secondary)
                .accessibilityHidden(true)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
          }
          .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }
}
