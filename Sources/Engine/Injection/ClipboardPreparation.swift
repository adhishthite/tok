// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class ClipboardPreparation<Contents> {

  let lock = NSLock()
  let queue = DispatchQueue(label: "com.adhishthite.tok.clipboard", qos: .utility)
  let version: () -> Int
  let read: () -> Contents?
  var generation: UInt64 = 0
  private var requested = false
  var running = false
  private var reading = false
  private var readingGeneration: UInt64 = 0
  var prepared: Snapshot?
  var waiters: [UUID: (Bool) -> Void] = [:]

  init(version: @escaping () -> Int, read: @escaping () -> Contents?) {
    self.version = version
    self.read = read
  }

  func prepare() {
    lock.lock()
    generation &+= 1
    prepared = nil
    requested = true
    let start = !running
    running = true
    lock.unlock()
    if start { queue.async { self.run() } }
  }

  func discard() {
    lock.lock()
    generation &+= 1
    requested = false
    prepared = nil
    let callbacks = Array(waiters.values)
    waiters.removeAll()
    lock.unlock()
    for callback in callbacks { callback(false) }
  }

  func take() -> Snapshot? {
    let currentVersion = version()
    lock.lock()
    let snapshot = prepared
    prepared = nil
    generation &+= 1
    requested = false
    lock.unlock()
    return snapshot?.version == currentVersion ? snapshot : nil
  }

  func awaitPrepared(timeout: Double, completion: @escaping (Bool) -> Void) {
    let currentVersion = version()
    let id = UUID()
    lock.lock()
    let ready = prepared?.version == currentVersion
    if !ready { waiters[id] = completion }
    let start = !ready && !running
    if !ready && (!reading || readingGeneration != generation) && !requested {
      generation &+= 1
      prepared = nil
      requested = true
    }
    if start { running = true }
    lock.unlock()
    if ready {
      completion(true)
      return
    }
    if start { queue.async { self.run() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout)) {
      self.lock.lock()
      let callback = self.waiters.removeValue(forKey: id)
      self.lock.unlock()
      callback?(false)
    }
  }

  func run() {
    while true {
      lock.lock()
      guard requested else {
        running = false
        lock.unlock()
        return
      }
      requested = false
      reading = true
      let token = generation
      readingGeneration = token
      lock.unlock()
      let before = version()
      let contents = read()
      let after = version()
      lock.lock()
      reading = false
      let current = token == generation
      if current, before == after, let contents = contents {
        prepared = Snapshot(version: before, contents: contents)
      }
      // Retry a concurrent user copy only while a bounded waiter still needs a snapshot.
      let retry = current && before != after && !waiters.isEmpty
      if retry { requested = true }
      let callbacks = current && !retry ? Array(waiters.values) : []
      if current && !retry { waiters.removeAll() }
      let ready = prepared != nil
      lock.unlock()
      for callback in callbacks { callback(ready) }
    }
  }
}
