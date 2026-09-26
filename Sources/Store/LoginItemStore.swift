// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Observation
import ServiceManagement

@MainActor
@Observable
final class LoginItemStore {
  private(set) var status = SMAppService.Status.notRegistered
  private(set) var changing = false
  private(set) var error: String?
  var enabled: Bool { status == .enabled || status == .requiresApproval }

  func refresh() { status = SMAppService.mainApp.status }

  func setEnabled(_ enabled: Bool) async {
    guard !changing else { return }
    changing = true
    defer {
      changing = false
      refresh()
    }
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try await SMAppService.mainApp.unregister()
      }
      error = nil
    } catch {
      self.error = "Could not change startup behavior. Review Tok in Login Items."
    }
  }

  func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }
}
