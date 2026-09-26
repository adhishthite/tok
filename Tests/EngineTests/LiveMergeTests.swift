// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import TokEngine

final class LiveMergeTests: XCTestCase {
  private func overlap(_ committed: String, _ incoming: String) -> Int {
    GeminiLiveClient.transcriptOverlapLength(committed: committed, incoming: incoming)
  }

  func testOverlapCountsWholeWordsOnly() {
    XCTAssertEqual(overlap("hello world", "world today"), 5)
    XCTAssertEqual(overlap("the quick brown fox", "brown fox jumps over"), 9)
    // "world" is the head of "worldly", not a word of its own: trimming it would splice
    // "ly goods" onto the committed text.
    XCTAssertEqual(overlap("hello world", "worldly goods"), 0)
    XCTAssertEqual(overlap("hello", "goodbye"), 0)
    XCTAssertEqual(overlap("", "anything"), 0)
  }

  func testOverlapScanIsCapped() {
    // A run that repeats is the only way one transcript's tail can overlap another's head
    // by more than the cap.
    let shared = String(repeating: "ab ", count: 100)
    XCTAssertGreaterThan(shared.count, 200)
    let measured = overlap("x " + shared, shared + "end")
    // The shared run is longer than the scan cap, so the match is found but bounded.
    XCTAssertGreaterThan(measured, 0)
    XCTAssertLessThanOrEqual(measured, 200)
  }

  func testCorrectedFinalAppendsOnlyTheNewWords() {
    let client = GeminiLiveClient(apiKey: "")
    client.fixtureOpen()
    client.fixtureMessage(["inputTranscription": ["text": "the quick brown fox"]])
    client.fixtureMessage(["inputTranscription": ["text": "brown fox jumps over"]])
    XCTAssertEqual(client.fixtureText(), "the quick brown fox jumps over")
  }

  func testRepeatedFinalAddsNothing() {
    let client = GeminiLiveClient(apiKey: "")
    client.fixtureOpen()
    client.fixtureMessage(["inputTranscription": ["text": "hello there world"]])
    client.fixtureMessage(["inputTranscription": ["text": "there world"]])
    XCTAssertEqual(client.fixtureText(), "hello there world")
  }

  func testUnrelatedFinalStillAppendsWithASeparator() {
    let client = GeminiLiveClient(apiKey: "")
    client.fixtureOpen()
    client.fixtureMessage(["inputTranscription": ["text": "hello"]])
    client.fixtureMessage(["inputTranscription": ["text": "goodbye"]])
    XCTAssertEqual(client.fixtureText(), "hello goodbye")
  }
}
