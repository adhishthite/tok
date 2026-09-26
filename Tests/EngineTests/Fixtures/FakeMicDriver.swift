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
import XCTest

@testable import TokEngine

final class FakeMicDriver {
  var now: TimeInterval = 0
  var scheduled: [(TimeInterval, () -> Void)] = []
  var rebuilds = 0
  var stops = 0
  var failures = 0
  var tap = false
  var running = false
  var interruptions = 0
  lazy var controller = MicRecoveryController(
    rebuild: { [unowned self] in
      rebuilds += 1
      if failures > 0 {
        failures -= 1
        return false
      }
      tap = true
      running = true
      return true
    },
    stop: { [unowned self] in
      stops += 1
      tap = false
      running = false
    },
    running: { [unowned self] in running },
    interrupted: { [unowned self] _ in interruptions += 1 },
    clock: { [unowned self] in now },
    schedule: { [unowned self] delay, action in scheduled.append((now + delay, action)) }
  )
  func advance(_ amount: Double) {
    let end = now + amount
    while let next = scheduled.indices.min(by: { scheduled[$0].0 < scheduled[$1].0 }),
      scheduled[next].0 <= end
    {
      let (time, action) = scheduled.remove(at: next)
      now = time
      action()
    }
    now = end
  }
  func buffer() { controller.receivedBuffer(generation: controller.generation, at: now) }
}
