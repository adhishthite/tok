// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import TokEngine

final class ReplacementBudgetTests: XCTestCase {
  func testCascadingExpansionStopsAtSmallOutputBudget() {
    let rules = ReplacementEngine.compile([
      ReplacementRule(wrong: "hello", right: String(repeating: "word ", count: 10)),
      ReplacementRule(wrong: "word", right: String(repeating: "abc ", count: 10)),
      ReplacementRule(wrong: "abc", right: String(repeating: "de ", count: 10)),
    ])
    XCTAssertThrowsError(
      try ReplacementEngine.apply("hello", compiled: rules, maximumOutputUTF16: 100))
  }

  func testMatchingAndScanningBudgetsAreCumulative() {
    let rules = ReplacementEngine.compile([
      ReplacementRule(wrong: "hello", right: "world"),
      ReplacementRule(wrong: "world", right: "done"),
    ])
    XCTAssertThrowsError(
      try ReplacementEngine.apply("hello hello", compiled: rules, maximumMatches: 3))
    XCTAssertThrowsError(
      try ReplacementEngine.apply("hello", compiled: rules, maximumScannedUTF16: 5))
  }

  func testOrdinaryCascadesAndUnicodeCaseStillWork() throws {
    let rules = ReplacementEngine.compile([
      ReplacementRule(wrong: "hello", right: "world"),
      ReplacementRule(wrong: "world", right: "done"),
      ReplacementRule(wrong: "straße", right: "Straße"),
    ])
    XCTAssertEqual(try ReplacementEngine.apply("Hello, straße.", compiled: rules), "Done, Straße.")
    XCTAssertEqual(try ReplacementEngine.apply("unchanged", compiled: []), "unchanged")
  }

  func testRejectedReplacementClearsProcessingAndPreservesOriginal() {
    var config = EngineConfiguration.load(values: ["CUSTOM_VOCABULARY": "word => changed"])
    config.historyEnabled = false
    config.soundFeedback = false
    config.enableLiveWebSocket = false
    config.restoreClipboard = false
    let engine = DictationEngine(config: config)
    let recorder = EngineEventRecorder()
    engine.delegate = recorder
    let original = String(repeating: "word ", count: 10_001).trimmingCharacters(in: .whitespaces)
    engine.sessionQueue.sync {
      engine.isProcessing = true
      engine.settle(
        turnId: 0, route: "fixture",
        outcome: .success(
          text: original, transport: "fixture", firstTokenMs: 0, roundtripMs: 0,
          audioDuration: 1, keyUpTime: ProcessInfo.processInfo.systemUptime,
          captureFinalizeMs: 0, fallbackReason: nil, isLiveRoute: true,
          inputTokens: nil, outputTokens: nil))
      XCTAssertFalse(engine.isProcessing)
    }
    let records = recorder.events.compactMap { event -> TurnRecord? in
      if case .turnSettled(let record) = event { return record }
      return nil
    }
    XCTAssertEqual(records.count, 1)
    XCTAssertTrue(records.first?.text == original, "Original transcript must be preserved.")
    XCTAssertEqual(records.first?.deliveryOutcome, "failed")
    XCTAssertEqual(records.first?.injected, false)
  }
}
