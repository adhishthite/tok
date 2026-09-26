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

final class ClipboardFixture {
  let lock = NSLock()
  var revision = 1
  var reads = 0
  var payload: String? = "original"
  var blocked = false
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
  func version() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return revision
  }
  func read() -> String? {
    lock.lock()
    reads += 1
    let shouldBlock = blocked
    let value = payload
    lock.unlock()
    if shouldBlock {
      entered.signal()
      release.wait()
    }
    return value
  }
}
