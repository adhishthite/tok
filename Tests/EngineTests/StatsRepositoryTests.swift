// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import XCTest

@testable import TokEngine

final class StatsRepositoryTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  private func record(
    _ text: String?, outcome: String = "success", audio: Double = 10, latency: Double = 400,
    app: String = "Notes"
  ) -> TurnRecord {
    TurnRecord(
      outcome: outcome, text: text, charCount: text?.count ?? 0,
      wordCount: text?.split { $0.isWhitespace }.count ?? 0, transport: "Live", model: "fixture",
      isLiveRoute: true, fallbackReason: nil, audioSeconds: audio, firstTokenMs: nil,
      roundtripMs: latency, captureFinalizeMs: 0, injectMs: 0, totalMs: latency, injected: true,
      inputTokens: nil, outputTokens: nil, tokensMetered: false, costUSD: nil,
      languageCodes: "en-IN", smartMode: true, vadMode: "manual", error: nil,
      appBundleId: "fixture.app", appName: app, inputDevice: nil, inputTransport: nil,
      deliveryOutcome: "dispatched")
  }

  func testRecordsCountsAndWordCountsButNeverTranscripts() async throws {
    let repository = StatsRepository(directory: directory)
    try await repository.record(
      record("Deploy the Kubernetes cluster tonight"), trackWords: true)
    try await repository.record(
      record("Kubernetes rollout finished", app: "Slack"), trackWords: true)
    try await repository.record(record(nil, outcome: "empty", audio: 1), trackWords: true)
    let report = try await repository.report(range: .all, typingWordsPerMinute: 40)
    XCTAssertEqual(report.words, 8)
    XCTAssertEqual(report.dictations, 2)
    XCTAssertEqual(report.attempts, 3)
    XCTAssertEqual(report.speakingSeconds, 20)
    XCTAssertEqual(report.apps.map(\.name), ["Notes", "Slack"])
    XCTAssertEqual(report.topWords.first, StatsWordCount(word: "kubernetes", count: 2))
    XCTAssertEqual(report.distinctWords, 6)
    XCTAssertEqual(report.rareWords.first?.count, 1)
    XCTAssertEqual(report.currentStreakDays, 1)
    let words = try await repository.words(since: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(words, 8)

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(repository.url.path, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(columns(db, table: "dictations").intersection(["text", "transcript"]), [])
    XCTAssertEqual(columns(db, table: "word_days"), ["day", "word", "count"])
    let attributes = try FileManager.default.attributesOfItem(atPath: repository.url.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
  }

  func testWordTrackingOffKeepsCountsWithoutWords() async throws {
    let repository = StatsRepository(directory: directory)
    try await repository.record(record("Deploy the cluster"), trackWords: false)
    let report = try await repository.report(range: .all, typingWordsPerMinute: 40)
    XCTAssertEqual(report.words, 3)
    XCTAssertTrue(report.topWords.isEmpty)
    XCTAssertEqual(report.distinctWords, 0)
  }

  func testRangesFilterTurnsAndComparePreviousWindow() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    let repository = StatsRepository(directory: directory, calendar: calendar)
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 10, hour: 15))!
    let previousStart = StatsRange.week.previousStart(now: now, calendar: calendar)!
    try await repository.record(record("one two three"), trackWords: true, date: now)
    try await repository.record(
      record("four five"), trackWords: true, date: previousStart.addingTimeInterval(3600))
    try await repository.record(
      record("six"), trackWords: true, date: previousStart.addingTimeInterval(-86400))
    let week = try await repository.report(range: .week, typingWordsPerMinute: 40, now: now)
    XCTAssertEqual(week.words, 3)
    XCTAssertEqual(week.previousWords, 2)
    XCTAssertEqual(week.wordsChange!, 0.5, accuracy: 0.0001)
    XCTAssertEqual(week.topWords.map(\.word), ["one", "three", "two"])
    let all = try await repository.report(range: .all, typingWordsPerMinute: 40, now: now)
    XCTAssertEqual(all.words, 6)
    XCTAssertNil(all.previousWords)
    XCTAssertEqual(all.distinctWords, 6)
  }

  func testReadingWithoutADatabaseCreatesNothing() async throws {
    let repository = StatsRepository(directory: directory)
    let report = try await repository.report(range: .month, typingWordsPerMinute: 50)
    XCTAssertEqual(report, StatsReport.empty(.month, typingWordsPerMinute: 50))
    let words = try await repository.words(since: Date())
    XCTAssertEqual(words, 0)
    try await repository.clear()
    XCTAssertFalse(FileManager.default.fileExists(atPath: repository.url.path))
  }

  func testClearRemovesEveryRow() async throws {
    let repository = StatsRepository(directory: directory)
    try await repository.record(record("keep counting words"), trackWords: true)
    try await repository.clear()
    let report = try await repository.report(range: .all, typingWordsPerMinute: 40)
    XCTAssertEqual(report.attempts, 0)
    XCTAssertEqual(report.distinctWords, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: repository.url.path))
  }

  private func columns(_ db: OpaquePointer?, table: String) -> Set<String> {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var names: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = sqlite3_column_text(statement, 1) { names.insert(String(cString: name)) }
    }
    return names
  }
  func testUnicodeTotalsDoNotDependOnWordTrackingOrWhitespaceCounts() async throws {
    for tracking in [false, true] {
      let repository = StatsRepository(
        directory: directory.appendingPathComponent(String(tracking)))
      let text = "我喜欢北京的天气"
      try await repository.record(record(text), trackWords: tracking)
      let report = try await repository.report(range: .all, typingWordsPerMinute: 40)
      XCTAssertGreaterThan(report.words, 1)
      XCTAssertEqual(report.words, WordTokenizer.count(in: text))
      XCTAssertEqual(report.topWords.isEmpty, !tracking)
      XCTAssertEqual(report.apps.first?.words, report.words)
      XCTAssertEqual(report.wordsPerMinute!, Double(report.words) * 6, accuracy: 0.001)
    }
  }

  func testComparisonExcludesTheRestOfThePreviousPeriod() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 10))!
    for range in [StatsRange.today, .week, .month, .year] {
      let repository = StatsRepository(
        directory: directory.appendingPathComponent(range.rawValue), calendar: calendar)
      let previous = try XCTUnwrap(range.previousComparisonInterval(now: now, calendar: calendar))
      try await repository.record(record("one two"), trackWords: false, date: now)
      try await repository.record(
        record("three four"), trackWords: false,
        date: previous.end.addingTimeInterval(-1))
      try await repository.record(record("five six seven"), trackWords: false, date: previous.end)
      let report = try await repository.report(range: range, typingWordsPerMinute: 40, now: now)
      XCTAssertEqual(report.words, 2)
      XCTAssertEqual(report.previousWords, 2)
      XCTAssertEqual(report.wordsChange, 0)
    }
  }

}
