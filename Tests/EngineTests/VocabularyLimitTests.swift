// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import TokEngine

final class VocabularyLimitTests: XCTestCase {
  func testVocabularyBeyondTheServiceLimitIsDroppedAndCounted() {
    let terms = (1...1205).map { "term\($0)" }.joined(separator: ",")
    let config = EngineConfiguration.load(values: ["CUSTOM_VOCABULARY": terms])
    XCTAssertEqual(config.recognitionVocabulary.count, EngineConfiguration.vocabularyLimit)
    XCTAssertEqual(config.customVocabularyDropped, 205)
    XCTAssertEqual(config.recognitionVocabulary.first, "term1")
    XCTAssertEqual(config.recognitionVocabulary.last, "term1000")
    // The complete list stays available so the analyzer never re-suggests a saved term.
    XCTAssertEqual(config.customVocabulary.count, 1205)
    XCTAssertEqual(config.customVocabulary.last, "term1205")
  }

  func testVocabularyWithinTheLimitIsSentUnchanged() {
    let config = EngineConfiguration.load(
      values: ["CUSTOM_VOCABULARY": "Kubernetes, gemini => Gemini, Kubernetes"])
    XCTAssertEqual(config.customVocabulary, ["Kubernetes", "Gemini"])
    XCTAssertEqual(config.recognitionVocabulary, config.customVocabulary)
    XCTAssertEqual(config.customVocabularyDropped, 0)
  }

  func testAlignedEndSignalsAndSessionLimitDefaults() {
    let config = EngineConfiguration()
    XCTAssertTrue(config.wsEndpointAligned)
    XCTAssertEqual(GeminiLiveClient.sessionLimitSeconds, 600)
    XCTAssertLessThan(GeminiLiveClient.sessionRotationSeconds, GeminiLiveClient.sessionLimitSeconds)
    XCTAssertNil(GeminiLiveClient(apiKey: "").sessionRemainingSeconds)
  }

  func testSessionClockStartsAtSetupAndStopsAtDisconnect() throws {
    let client = GeminiLiveClient(apiKey: "")
    client.recoveryFixture(LiveWriteProbe())
    client.recoveryReady()
    let remaining = try XCTUnwrap(client.sessionRemainingSeconds)
    XCTAssertGreaterThan(remaining, 595)
    XCTAssertLessThanOrEqual(remaining, GeminiLiveClient.sessionLimitSeconds)
    client.disconnect()
    XCTAssertNil(client.sessionRemainingSeconds)
  }
}
