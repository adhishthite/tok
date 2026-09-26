// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Coalesces values onto one target queue. The newest value wins and at most one hop is in
/// flight, so a fast producer (a hardware audio tap) cannot flood the consumer.
/// Use this instead of `MainQueueDelivery` whenever the consumer owns its own queue: routing
/// such traffic through main makes a main-thread stall look like a dead producer.
class QueueDelivery<Value> {
  private let lock = NSLock()
  private var latest: Value?
  private var scheduled = false
  let queue: DispatchQueue
  private let consume: (Value) -> Void

  init(queue: DispatchQueue, _ consume: @escaping (Value) -> Void) {
    self.queue = queue
    self.consume = consume
  }

  func submit(_ value: Value) {
    lock.lock()
    latest = value
    let start = !scheduled
    scheduled = true
    lock.unlock()
    guard start else { return }
    queue.async {
      // Snapshot under the lock, release, then call out. The consumer never runs with the
      // lock held.
      self.lock.lock()
      let value = self.latest
      self.latest = nil
      self.scheduled = false
      self.lock.unlock()
      if let value = value { self.consume(value) }
    }
  }
}
