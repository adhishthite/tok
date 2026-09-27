// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import TokEngine

/// The detail column: one dedicated pane view per group, so each pane keeps
/// its own scroll position, plus the pending-change notice at the top.
struct SettingsPane: View {
  let group: SettingGroup
  @Environment(DictationStore.self) private var store
  var body: some View {
    pane
      .formStyle(.grouped)
      .navigationTitle(group.rawValue)
      .safeAreaInset(edge: .top, spacing: 0) {
        if store.settingsPending {
          Label("Changes will apply after this dictation.", systemImage: "clock")
            .font(.callout).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity).padding(.vertical, 8)
            .background(.bar)
        }
      }
  }
  @ViewBuilder private var pane: some View {
    switch group {
    case .general: GeneralPane()
    case .transcription: TranscriptionPane()
    case .audio: AudioPane()
    case .appearance: AppearancePane()
    case .vocabulary: VocabularyPane()
    case .privacy: PrivacyPane()
    case .advanced: AdvancedPane()
    case .about: AboutPane()
    }
  }
}
