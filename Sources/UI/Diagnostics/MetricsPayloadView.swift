// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Shows exactly what usage metrics have been recorded, byte for byte.
struct MetricsPayloadView: View {
  @Environment(DictationStore.self) private var store
  @State private var expanded = false
  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      if !store.metrics.enabled {
        Text("Usage metrics are off. Nothing is recorded.").font(.caption)
          .foregroundStyle(.secondary)
      } else if let payload = store.metrics.lastPayload {
        ScrollView {
          Text(payload).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxHeight: 220)
        HStack {
          Button("Copy all queued events") { copyAll() }
          Button("Delete queued events") { store.metrics.deleteQueue() }
          Spacer()
        }.controlSize(.small)
      } else {
        Text("Usage metrics are on. No events recorded yet.").font(.caption)
          .foregroundStyle(.secondary)
      }
    } label: {
      Text(title).font(.callout)
    }
    .padding(.horizontal, 12).padding(.vertical, 8)
  }
  private var title: String {
    guard store.metrics.enabled else { return "Usage metrics: off" }
    return "Usage metrics: \(store.metrics.queuedCount) queued locally, nothing sent"
  }
  private func copyAll() {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(
      store.metrics.queuedPayloads.joined(separator: "\n"), forType: .string)
  }
}
