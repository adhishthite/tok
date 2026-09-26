// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// A rounded surface for one dashboard section, with an optional title row.
struct StatsCard<Content: View>: View {
  var title: String? = nil
  var subtitle: String? = nil
  @ViewBuilder let content: Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if let title {
        VStack(alignment: .leading, spacing: 2) {
          Text(title).font(.headline)
          if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
      }
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
  }
}
