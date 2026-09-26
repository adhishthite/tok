// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import TokEngine

final class MetricsSchemaTests: XCTestCase {
  private let envelope = MetricEnvelope(
    installID: "test-install", appVersion: "0.1.3", build: "10", osVersion: "15.6", arch: "arm64",
    date: Date(timeIntervalSince1970: 1_757_500_000))

  func testEveryBuiltEventUsesOnlyDocumentedFields() {
    var record = Self.record()
    record.outcome = "success"
    let events = [
      MetricEvent.launch(
        envelope: envelope, configuration: EngineConfiguration(), daysSinceInstall: 3),
      MetricEvent.setup(
        envelope: envelope, microphone: true, accessibility: false, inputMonitoring: true,
        apiKey: true),
      MetricEvent.dictation(envelope: envelope, record: record),
    ]
    for event in events {
      XCTAssertEqual(event.undocumentedKeys, [], event.name)
      XCTAssertNotNil(MetricsSchema.definition(named: event.name), event.name)
    }
  }

  func testDictationEventCarriesNoTextAppOrErrorMessage() throws {
    var record = Self.record()
    record.outcome = "error"
    record.text = "SECRET TRANSCRIPT"
    record.appName = "Mail"
    record.appBundleId = "com.apple.mail"
    record.error = "Network failed for user@example.com"
    record.fallbackReason = "custom reason"
    record.finishMode = "unexpected"
    record.deliveryOutcome = "weird"
    record.totalMs = 1234
    record.audioSeconds = 7
    record.inputTokens = 42
    let event = MetricEvent.dictation(envelope: envelope, record: record)
    let json = String(decoding: try event.json(), as: UTF8.self)
    for forbidden in ["SECRET", "Mail", "com.apple", "example.com", "custom reason"] {
      XCTAssertFalse(json.contains(forbidden), forbidden)
    }
    XCTAssertEqual(event.fields["had_error"], .bool(true))
    XCTAssertEqual(event.fields["finish"], .string("other"))
    XCTAssertEqual(event.fields["delivery"], .string("other"))
    XCTAssertEqual(event.fields["latency"], .string("1000-2000"))
    XCTAssertEqual(event.fields["audio"], .string("5-15"))
    XCTAssertEqual(event.fields["input_tokens"], .int(42))
    XCTAssertEqual(event.fields["output_tokens"], .null)
    XCTAssertEqual(event.fields["hour"], .string("2025-09-10T10"))
  }

  func testBucketsAndCategoriesCloseOverTheirRanges() {
    XCTAssertEqual(MetricsBucket.latency(nil), .null)
    XCTAssertEqual(MetricsBucket.latency(499), .string("<500"))
    XCTAssertEqual(MetricsBucket.latency(4000), .string("4000+"))
    XCTAssertEqual(MetricsBucket.audio(0.5), .string("<2"))
    XCTAssertEqual(MetricsBucket.audio(61), .string("60+"))
    XCTAssertEqual(MetricsBucket.days(0), .string("0"))
    XCTAssertEqual(MetricsBucket.days(30), .string("8-30"))
    XCTAssertEqual(MetricsBucket.days(91), .string("90+"))
    XCTAssertEqual(MetricsBucket.category(nil, allowed: ["a"]), .string("none"))
    XCTAssertEqual(MetricsBucket.category("b", allowed: ["a"]), .string("other"))
    var record = Self.record()
    record.finishMode = "session_limit"
    XCTAssertEqual(
      MetricEvent.dictation(envelope: envelope, record: record).fields["finish"],
      .string("session_limit"))
  }

  func testSchemaMarkdownListsEveryEventAndField() {
    let markdown = MetricsSchema.markdown()
    for event in MetricsSchema.events {
      XCTAssertTrue(markdown.contains("### \(event.name)"))
      for field in event.fields { XCTAssertTrue(markdown.contains("`\(field.name)`"), field.name) }
    }
    XCTAssertFalse(markdown.contains("—"))
  }

  private static func record() -> TurnRecord {
    TurnRecord(
      outcome: "success", text: nil, charCount: 0, wordCount: 0, transport: "Live",
      model: "fixture", isLiveRoute: true, fallbackReason: nil, audioSeconds: 1,
      firstTokenMs: nil, roundtripMs: 300, captureFinalizeMs: 80, injectMs: 15, totalMs: 500,
      injected: true, inputTokens: nil, outputTokens: nil, tokensMetered: true, costUSD: nil,
      languageCodes: "en-IN", smartMode: true, vadMode: "manual", error: nil, appBundleId: nil,
      appName: nil, inputDevice: nil, inputTransport: nil, deliveryOutcome: "dispatched")
  }
}
