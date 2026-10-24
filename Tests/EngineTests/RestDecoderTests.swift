// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import TokEngine

final class RestDecoderTests: XCTestCase {
  private let content: [String: Any] = ["parts": [["text": "hello"]]]

  private func decode(_ value: [String: Any]) -> GenerateContentDecoder.Outcome {
    GenerateContentDecoder.decode(value)
  }

  func testFinishReasonsMapToDistinctOutcomes() {
    XCTAssertEqual(
      decode(["candidates": [["finishReason": "STOP", "content": content]]]), .text("hello"))
    // Non-streaming calls always state a reason, so a missing one marks an incomplete
    // envelope: text is treated as truncated, and no text at all as malformed.
    XCTAssertEqual(decode(["candidates": [["content": content]]]), .truncated)
    XCTAssertEqual(decode(["candidates": [["content": ["parts": []]]]]), .malformed)
    XCTAssertEqual(
      decode(["candidates": [["finishReason": "MAX_TOKENS", "content": content]]]), .truncated)
    for reason in ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII"] {
      XCTAssertEqual(
        decode(["candidates": [["finishReason": reason, "content": content]]]),
        .blocked(reason: reason))
    }
    XCTAssertEqual(
      decode(["candidates": [["finishReason": "STOP", "content": ["parts": []]]]]), .empty)
    XCTAssertEqual(
      decode(["candidates": [["finishReason": "OTHER", "content": content]]]), .truncated)
    XCTAssertEqual(
      decode(["promptFeedback": ["blockReason": "SAFETY"]]), .blocked(reason: "SAFETY"))
    XCTAssertEqual(decode(["usageMetadata": ["promptTokenCount": 3]]), .malformed)
  }

  func testEveryTextPartJoinsAndThoughtPartsAreExcluded() {
    let parts: [[String: Any]] = [
      ["text": "reasoning", "thought": true],
      ["text": "one "],
      ["text": "two"],
    ]
    XCTAssertEqual(
      decode(["candidates": [["finishReason": "STOP", "content": ["parts": parts]]]]),
      .text("one two"))
  }

  func testInlineAudioSizeMathMatchesTheDocumentedCap() {
    // 4 base64 characters per 3 encoded bytes, padded.
    XCTAssertEqual(GeminiRestClient.inlineAudioBytes(encodedByteCount: 44), 60)
    let sevenMinutesWAV = 7 * 60 * 32_000 + 44
    let nineMinutesWAV = 9 * 60 * 32_000 + 44
    XCTAssertLessThanOrEqual(
      GeminiRestClient.inlineAudioBytes(encodedByteCount: sevenMinutesWAV),
      GeminiRestClient.maxInlineAudioBytes)
    XCTAssertGreaterThan(
      GeminiRestClient.inlineAudioBytes(encodedByteCount: nineMinutesWAV),
      GeminiRestClient.maxInlineAudioBytes)
    // The turn cap is sized from WAV, the largest payload the encoder returns.
    let cappedWAV = Int(GeminiRestClient.maxInlineAudioSeconds * 32_000) + 44
    XCTAssertLessThanOrEqual(
      GeminiRestClient.inlineAudioBytes(encodedByteCount: cappedWAV),
      GeminiRestClient.maxInlineAudioBytes)
  }

  func testOverlongRecordingFailsWithoutSendingARequest() {
    let finished = expectation(description: "size check answers")
    var failure: NSError?
    GeminiRestClient.transcribe(
      audio: (Data(count: 9 * 60 * 32_000 + 44), "audio/wav"), apiKey: "fixture-key",
      model: "gemini-fixture"
    ) { result in
      if case .failure(let error) = result { failure = error as NSError }
      finished.fulfill()
    }
    wait(for: [finished], timeout: 5)
    XCTAssertEqual(failure?.domain, "GeminiAPI")
    XCTAssertEqual(failure?.code, -22)
    XCTAssertEqual(
      failure?.localizedDescription, "Recording too long for the backup route. Nothing pasted.")
  }

  func testTruncatedAndBlockedFailuresReadAsShortHUDLines() {
    XCTAssertEqual(
      RESTResponse.truncatedError().localizedDescription,
      "Transcription was cut short. Nothing pasted.")
    XCTAssertEqual(
      RESTResponse.blockedError().localizedDescription,
      "Transcription blocked by the service. Nothing pasted.")
    // The engine surfaces domain "GeminiAPI" verbatim, so these must carry it.
    XCTAssertEqual(RESTResponse.truncatedError().domain, "GeminiAPI")
    XCTAssertEqual(RESTResponse.blockedError().domain, "GeminiAPI")
  }
}
