// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TokEngine

/// The engine delegate for one arm block. Engine events arrive on main and on the
/// session queue, so every field is lock-guarded and read as a snapshot.
final class HarnessObserver: DictationEngineDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private let settled = DispatchSemaphore(value: 0)
  private let log: (String) -> Void
  private var record: TurnRecord?
  private var listening = false
  private var failures: [String] = []

  init(log: @escaping (String) -> Void) { self.log = log }

  func engineDidEmit(_ event: EngineEvent) {
    switch event {
    case .turnSettled(let turn):
      lock.lock()
      record = turn
      lock.unlock()
      settled.signal()
    case .listening:
      lock.lock()
      listening = true
      lock.unlock()
    case .failure(let message):
      lock.lock()
      failures.append(message)
      lock.unlock()
    case .diagnostic(let line):
      log(line)
    default:
      break
    }
  }

  /// Clears per-turn state. Call before each key-down.
  func reset() {
    lock.lock()
    record = nil
    listening = false
    failures = []
    lock.unlock()
    while settled.wait(timeout: .now()) == .success {}
  }

  var captureStarted: Bool {
    lock.lock()
    defer { lock.unlock() }
    return listening
  }

  var failureMessages: [String] {
    lock.lock()
    defer { lock.unlock() }
    return failures
  }

  /// Waits for the turn's history row. Nil when the turn ended without one (a capture that
  /// never started, a micro-click) or the wait timed out.
  func waitForRecord(timeout: TimeInterval) -> TurnRecord? {
    guard settled.wait(timeout: .now() + timeout) == .success else { return nil }
    lock.lock()
    defer { lock.unlock() }
    return record
  }
}
