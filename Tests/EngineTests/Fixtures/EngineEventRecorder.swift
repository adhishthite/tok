// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

@testable import TokEngine

final class EngineEventRecorder: DictationEngineDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var values: [EngineEvent] = []

  func engineDidEmit(_ event: EngineEvent) {
    lock.lock()
    values.append(event)
    lock.unlock()
  }

  var events: [EngineEvent] {
    lock.lock()
    defer { lock.unlock() }
    return values
  }
}
