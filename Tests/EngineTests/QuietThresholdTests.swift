// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import TokEngine

/// The adaptive quiet line for the trailing-capture wait (QUIET_MARGIN_DB).
final class QuietThresholdTests: XCTestCase {
  /// 20 ms frames: `quiet` room frames and `loud` speech frames.
  private func frames(room: Double, speech: Double, quiet: Int = 30, loud: Int = 70) -> [Double] {
    Array(repeating: room, count: quiet) + Array(repeating: speech, count: loud)
  }

  func testQuietRoomKeepsTheConfiguredThreshold() {
    let line = AudioCaptureEngine.quietThresholdDb(
      frames: frames(room: -62, speech: -24), configuredDb: -40, marginDb: 8)
    XCTAssertEqual(line, -40)
  }

  func testNoisyRoomRaisesTheLineAboveRoomTone() {
    // Room at -44 dBFS: the fixed -40 line sits 4 dB above room tone, so any swell resets
    // the quiet window. The adaptive line moves to floor + margin.
    let line = AudioCaptureEngine.quietThresholdDb(
      frames: frames(room: -44, speech: -22), configuredDb: -40, marginDb: 8)
    XCTAssertEqual(line, -36, accuracy: 0.001)
  }

  func testSpeechKeepsItsHeadroom() {
    // Room tone close to speech level: floor + margin would swallow words, so the line
    // stops quietSpeechHeadroomDb below speech.
    let line = AudioCaptureEngine.quietThresholdDb(
      frames: frames(room: -38, speech: -26), configuredDb: -40, marginDb: 8)
    XCTAssertEqual(line, -38, accuracy: 0.001)
  }

  func testNeverBelowTheConfiguredThreshold() {
    // Room and speech so close that headroom alone would pull the line under the
    // configured threshold: the configured threshold wins.
    let line = AudioCaptureEngine.quietThresholdDb(
      frames: frames(room: -33, speech: -30), configuredDb: -40, marginDb: 8)
    XCTAssertEqual(line, -40)
  }

  func testZeroMarginDisablesIt() {
    let line = AudioCaptureEngine.quietThresholdDb(
      frames: frames(room: -44, speech: -22), configuredDb: -40, marginDb: 0)
    XCTAssertEqual(line, -40)
  }

  func testTooFewFramesKeepsTheConfiguredThreshold() {
    let line = AudioCaptureEngine.quietThresholdDb(
      frames: [-44, -44, -22, -22], configuredDb: -40, marginDb: 8)
    XCTAssertEqual(line, -40)
  }

  func testSettingDefaultsAndClamps() {
    XCTAssertEqual(EngineConfiguration.load(values: [:]).quietMarginDb, 8)
    XCTAssertEqual(EngineConfiguration.load(values: ["QUIET_MARGIN_DB": "50"]).quietMarginDb, 20)
    XCTAssertEqual(EngineConfiguration.load(values: ["QUIET_MARGIN_DB": "-3"]).quietMarginDb, 0)
  }
}
