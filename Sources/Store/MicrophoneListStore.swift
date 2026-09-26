// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import TokEngine

@MainActor
@Observable
final class MicrophoneListStore {
  private(set) var devices: [InputDeviceCatalog.Device] = []
  @ObservationIgnored private var changes: AudioDeviceChanges?
  @ObservationIgnored private var refreshTask: Task<Void, Never>?
  @ObservationIgnored private var needsRefresh = false

  func start() {
    guard changes == nil else { return }
    changes = AudioDeviceChanges { [weak self] in
      Task { @MainActor [weak self] in self?.refresh() }
    }
    refresh()
  }

  func stop() {
    changes = nil
    refreshTask?.cancel()
    refreshTask = nil
    needsRefresh = false
  }

  func refresh() {
    guard changes != nil else { return }
    if refreshTask != nil {
      needsRefresh = true
      return
    }
    refreshTask = Task { [weak self] in
      let devices = await Task.detached(priority: .utility) {
        InputDeviceCatalog.inputDevices()
      }.value
      guard !Task.isCancelled, let self else { return }
      self.devices = devices
      self.refreshTask = nil
      if self.needsRefresh {
        self.needsRefresh = false
        self.refresh()
      }
    }
  }
}
