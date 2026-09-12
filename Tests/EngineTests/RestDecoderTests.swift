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
    // A candidate with text but no stated reason is usable; that is how streamed
    // envelopes arrive.
    XCTAssertEqual(decode(["candidates": [["content": content]]]), .text("hello"))
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
    // 44-byte WAV header, then 4 base64 characters per 3 bytes.
    XCTAssertEqual(GeminiRestClient.inlineAudioBytes(pcmByteCount: 0), 60)
    let sevenMinutes = 7 * 60 * 32_000
    let nineMinutes = 9 * 60 * 32_000
    XCTAssertLessThanOrEqual(
      GeminiRestClient.inlineAudioBytes(pcmByteCount: sevenMinutes),
      GeminiRestClient.maxInlineAudioBytes)
    XCTAssertGreaterThan(
      GeminiRestClient.inlineAudioBytes(pcmByteCount: nineMinutes),
      GeminiRestClient.maxInlineAudioBytes)
  }

  func testOverlongRecordingFailsWithoutSendingARequest() {
    let finished = expectation(description: "size check answers")
    var failure: NSError?
    GeminiRestClient.transcribe(
      pcmData: Data(count: 9 * 60 * 32_000), apiKey: "fixture-key", model: "gemini-fixture"
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
