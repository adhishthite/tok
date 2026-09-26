// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import TokEngine

final class PostProcessingLiveTests: XCTestCase {
  func testSyntheticTextCleanup() throws {
    guard ProcessInfo.processInfo.environment["TOK_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Run the TokLiveChecks scheme for real cleanup API checks.")
    }
    let root = URL(
      fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["TOK_PROJECT_ROOT"]))
    let env = try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
    var config = EngineConfiguration()
    for line in env.components(separatedBy: .newlines) {
      guard let separator = line.firstIndex(of: "="),
        line[..<separator].trimmingCharacters(in: .whitespaces) == "GEMINI_API_KEY"
      else { continue }
      var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value = String(value.dropFirst().dropLast())
      }
      config.geminiApiKey = value
    }
    XCTAssertFalse(config.geminiApiKey.isEmpty, "The local test key must be present")
    config.postProcessEnabled = true
    let cases: [(String, String, [String])] = [
      (
        "numbered-list", "one buy milk two send the report three book the tickets",
        ["1.", "2.", "3.", "milk", "report", "tickets"]
      ),
      ("numbers", "there are one hundred twenty three requests", ["123", "requests"]),
      ("marathi", "उद्या सकाळी दहा वाजता भेटूया", ["उद्या", "सकाळी"]),
      ("mixed", "उद्याच्या demo साठी Gemini API चे quota तपासा", ["Gemini", "API", "तपासा"]),
      ("app-context", "is the server ready", ["server", "ready"]),
    ]
    let queue = DispatchQueue(label: "test.cleanup.live")
    let stage = PostProcessingStage(queue: queue)
    var measurements: [[String: Any]] = []
    for (name, original, required) in cases {
      let done = DispatchSemaphore(value: 0)
      var result: PostProcessingResult?
      config.postProcessAppContext = name == "app-context"
      queue.sync {
        stage.process(
          text: original, configuration: config, appName: "Terminal",
          appBundleId: "com.apple.Terminal"
        ) {
          result = $0
          done.signal()
        }
      }
      XCTAssertEqual(
        done.wait(timeout: .now() + 4), .success, "Cleanup check exceeded its deadline")
      let completed = try XCTUnwrap(result)
      XCTAssertEqual(completed.metrics.status, "completed", "Synthetic case: \(name)")
      for word in required {
        XCTAssertTrue(
          completed.text.localizedCaseInsensitiveContains(word),
          "Missing expected fixture component in \(name)")
      }
      if name == "numbered-list" {
        XCTAssertEqual(completed.text.split(separator: "\n").count, 3)
      }
      if name == "app-context" {
        XCTAssertEqual(
          completed.text.lowercased().filter { $0.isLetter || $0.isWhitespace },
          "is the server ready")
      }
      let m = completed.metrics
      var row: [String: Any] = ["case": name, "status": m.status, "app_context": m.appContextUsed]
      row["elapsed_ms"] = m.latencyMs
      row["input_tokens"] = m.inputTokens
      row["output_tokens"] = m.outputTokens
      row["thinking_tokens"] = m.thinkingTokens
      row["estimated_cost_usd"] = m.costUSD
      measurements.append(row)
      print(
        "CLEANUP_CHECK case=\(name) status=\(m.status) elapsed_ms=\(m.latencyMs.map { String(format: "%.1f", $0) } ?? "n/a")"
      )
    }
    let data = try JSONSerialization.data(
      withJSONObject: ["model": config.postProcessModel, "samples": measurements],
      options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("build/post-processing-live-check.json"))
  }
}
