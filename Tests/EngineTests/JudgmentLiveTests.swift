import Foundation
import XCTest

@testable import TokEngine

/// Live check against the real TypeSafe API, gated like Tests/EngineTests/PostProcessingLiveTests.
/// Run through the TokLiveChecks scheme (`make test-jev-live`), never in `make check`.
final class JudgmentLiveTests: XCTestCase {
  func testProbeSucceedsAndOneNoulRoundTrips() async throws {
    guard ProcessInfo.processInfo.environment["TOK_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Run the TokLiveChecks scheme for real Jev API checks.")
    }
    let root = URL(
      fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["TOK_PROJECT_ROOT"]))
    let env = try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
    var apiKey = ""
    for line in env.components(separatedBy: .newlines) {
      guard let separator = line.firstIndex(of: "="),
        line[..<separator].trimmingCharacters(in: .whitespaces) == "TYPESAFE_API_KEY"
      else { continue }
      var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value = String(value.dropFirst().dropLast())
      }
      apiKey = value
    }
    // Never print the key itself - only whether one was found.
    XCTAssertFalse(apiKey.isEmpty, "The local TypeSafe test key must be present in .env")

    // Capture the [Jev] Diagnostics latency line without touching the real delegate.
    let recorder = EngineEventRecorder()
    Log.configure(delegate: recorder, apiKey: "", privacyMode: false)
    defer { Log.configure(delegate: nil, apiKey: "", privacyMode: false) }

    let service = JudgmentService(apiKey: apiKey)
    let available = await service.awaitAvailability()
    XCTAssertTrue(available, "The models probe must succeed with a valid local test key")

    let result = await service.ask(
      state: .object([
        "pairs": .array([.object(["wrong": .string("cloud"), "right": .string("Claude")])])
      ]),
      questions: [
        "pair_0": .noul(
          instructions:
            "Is `pairs[0].right` what the speaker actually said where speech recognition produced `pairs[0].wrong` - a phonetic or spelling misrecognition fix?",
          criteria: [
            "true": "\"cloud\" -> \"Claude\" (misheard product name).",
            "false": "\"quick\" -> \"fast\" (a wording change, not a misrecognition).",
          ])
      ], label: "live_check")

    switch result {
    case .success(let response):
      guard case .noul(let value)? = response.answers["pair_0"] else {
        return XCTFail("Expected a noul answer for pair_0")
      }
      XCTAssertGreaterThanOrEqual(value, 0.0)
      XCTAssertLessThanOrEqual(value, 1.0)
      print(
        "JEV_CHECK model=\(response.model) input_tokens=\(response.usage.inputTokens ?? -1) noul=\(value)"
      )
    case .failure(let error):
      XCTFail("Live Jev request failed: \(error.diagnosticDescription)")
    }
    // The Diagnostics writer drains asynchronously; force it to catch up before reading.
    Log.flush()

    let diagnostics = recorder.events.compactMap { event -> String? in
      guard case .diagnostic(let line) = event else { return nil }
      return line
    }
    let jevLatencyLines = diagnostics.filter { $0.hasPrefix("[Jev]") }
    XCTAssertFalse(jevLatencyLines.isEmpty, "Expected at least one [Jev] latency Diagnostics line")
    for line in jevLatencyLines { print("JEV_DIAGNOSTICS \(line)") }
  }
}
