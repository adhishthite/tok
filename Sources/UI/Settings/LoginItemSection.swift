// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct LoginItemSection: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.scenePhase) private var phase
  var body: some View {
    Section {
      Toggle(
        "Open Tok at login",
        isOn: Binding(
          get: { store.loginItem.enabled },
          set: { value in
            Task { await store.loginItem.setEnabled(value) }
          })
      ).disabled(store.loginItem.changing)
      if store.loginItem.status == .requiresApproval {
        Text("Allow Tok in Login Items to finish enabling startup.").font(.caption).foregroundStyle(
          .secondary)
        Button("Open Login Items") { store.loginItem.openLoginItems() }
      }
      if let error = store.loginItem.error {
        Text(error).font(.caption).foregroundStyle(.secondary)
        Button("Review Login Items") { store.loginItem.openLoginItems() }
      }
    } header: {
      Text("Startup")
    }
    .onAppear { store.loginItem.refresh() }
    .onChange(of: phase) { if phase == .active { store.loginItem.refresh() } }
  }
}
