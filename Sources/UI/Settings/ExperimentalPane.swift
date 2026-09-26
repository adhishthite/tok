// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Home for optional, off-by-default features. Nothing here runs until it is configured. The
/// pane mirrors the engine's live TypeSafe probe state (`JudgmentService.availability`,
/// surfaced through `DictationStore.judgmentAvailability`) instead of only reporting whether
/// a key exists, so "saved" and "verified" are never conflated.
struct ExperimentalPane: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    Form {
      Section {
        Text(
          "Experimental features are optional. They stay off until you configure them, and their behavior may change."
        )
        .foregroundStyle(.secondary)
        statusLabel
      }
      TypeSafeKeySection()
    }
  }

  @ViewBuilder
  private var statusLabel: some View {
    switch store.judgmentAvailability {
    case .off:
      Text(
        "Jev judgments (correction scoring, analyzer confidence, and per-turn quality signals in history) turn on once you save a valid TypeSafe key below."
      )
    case .checking:
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text("Verifying TypeSafe key")
      }
    case .available:
      Label("TypeSafe judgments active", systemImage: "checkmark.circle")
    case .unavailable(let reason):
      // `reason` covers transport failures ("network error") as well as a rejected key, so the
      // copy stays on "not verified" rather than claiming the key itself was refused.
      Label(
        "TypeSafe key not verified: \(reason). Judgments are off.",
        systemImage: "exclamationmark.triangle"
      )
      .foregroundStyle(.orange)
    }
  }
}
