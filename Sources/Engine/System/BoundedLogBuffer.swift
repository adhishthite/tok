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

final class BoundedLogBuffer {
  let lock = NSLock()
  let queue = DispatchQueue(label: "com.adhishthite.tok.log", qos: .utility)
  private var lines: [String] = []
  private var latestMeter: String?
  private var draining = false
  private var dropped = 0
  let write: (String) -> Void

  init(
    write: @escaping (String) -> Void
  ) {
    self.write = write
  }

  func submit(_ text: String, meter: Bool = false, endMeter: Bool = false) {
    let bounded = String(text.prefix(8192))
    lock.lock()
    if endMeter { latestMeter = nil }
    if meter {
      latestMeter = bounded
    } else if lines.count < 128 {
      lines.append(bounded)
    } else {
      dropped += 1
    }
    let start = !draining
    draining = true
    lock.unlock()
    if start { queue.async { self.drain() } }
  }

  private func drain() {
    while true {
      lock.lock()
      let next: String?
      if !lines.isEmpty {
        next = lines.removeFirst()
      } else if let meter = latestMeter {
        next = meter
        latestMeter = nil
      } else if dropped > 0 {
        next = "\n[LOG] Dropped \(dropped) messages while output was busy.\n"
        dropped = 0
      } else {
        next = nil
        draining = false
      }
      lock.unlock()
      guard let next = next else { return }
      write(next)
    }
  }

  func flush(timeout: TimeInterval = 0.2) {
    let done = DispatchSemaphore(value: 0)
    queue.async { done.signal() }
    _ = done.wait(timeout: .now() + timeout)
  }
}
