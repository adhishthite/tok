// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import TokEngine

/// Audit F14. The post-roll wait used to notice its exit conditions only every 25 ms, so a
/// turn whose quiet was already banked at key-up left at about 75 ms against a 60 ms floor.
final class PostRollFloorTests: XCTestCase {
  private let grace = 0.25
  private let floor = 0.06
  private let cap = 2.0
  private let poll = 0.010

  private func delay(_ now: Double, quietStart: Double?) -> Double {
    AudioCaptureEngine.postRollWakeDelay(
      now: now, entryTime: 0, quietStart: quietStart, graceSec: grace, minTrailSec: floor,
      maxTrailSec: cap, pollSec: poll)
  }

  func testBankedQuietSleepsStraightToTheFloor() {
    // Quiet banked before the release already satisfies grace, so the only thing left is
    // the fixed floor: one sleep of exactly 60 ms, not three 25 ms polls.
    XCTAssertEqual(delay(0, quietStart: -0.3), 0.06, accuracy: 1e-9)
  }

  func testFloorSleepShrinksAsTheFloorApproaches() {
    XCTAssertEqual(delay(0.05, quietStart: -0.3), 0.01, accuracy: 1e-9)
    XCTAssertEqual(delay(0.0599, quietStart: -0.3), 0.0001, accuracy: 1e-9)
  }

  func testExitIsImmediateOnceGraceAndFloorAreBothMet() {
    XCTAssertEqual(delay(0.06, quietStart: -0.3), 0)
    XCTAssertEqual(delay(0.5, quietStart: 0.2), 0)
  }

  func testOpenGraceWindowKeepsPolling() {
    // New speech can still push the grace window out, so it is polled rather than slept
    // through.
    XCTAssertEqual(delay(0.1, quietStart: 0.1), poll, accuracy: 1e-9)
    XCTAssertEqual(delay(0.3, quietStart: 0.2), poll, accuracy: 1e-9)
  }

  func testSpeakingKeepsPolling() {
    XCTAssertEqual(delay(0.1, quietStart: nil), poll, accuracy: 1e-9)
    XCTAssertEqual(delay(1.5, quietStart: nil), poll, accuracy: 1e-9)
  }

  func testHardCapEndsTheWaitAndIsNeverOvershot() {
    XCTAssertEqual(delay(cap, quietStart: nil), 0)
    XCTAssertEqual(delay(cap + 0.5, quietStart: 0), 0)
    // Less than one poll left before the cap: sleep only to the cap.
    XCTAssertEqual(delay(cap - 0.004, quietStart: nil), 0.004, accuracy: 1e-9)
    // A floor that sits past the cap cannot extend the wait.
    XCTAssertEqual(
      AudioCaptureEngine.postRollWakeDelay(
        now: 0, entryTime: 0, quietStart: -1, graceSec: grace, minTrailSec: floor,
        maxTrailSec: 0.03, pollSec: poll), 0.03, accuracy: 1e-9)
  }
}
