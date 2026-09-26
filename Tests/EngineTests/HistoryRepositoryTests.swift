// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import XCTest

@testable import TokEngine

final class HistoryRepositoryTests: XCTestCase {
  func testRetentionDeletesOnlyExpiredRecords() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let writer = HistoryStore(config: config)
    writer.record(record(text: "Expired", words: 1, latency: 100, cost: 0))
    writer.record(record(text: "Keep", words: 1, latency: 100, cost: 0))
    writer.recordCorrection(wrong: "word", right: "Word", appName: "Fixture")
    writer.close()
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(
      sqlite3_exec(
        db, "UPDATE transcriptions SET ts_epoch=1 WHERE id=1; UPDATE corrections SET ts_epoch=1;",
        nil, nil, nil), SQLITE_OK)
    let repository = HistoryRepository(path: config.historyDbPath)
    try await repository.prune(before: Date(timeIntervalSince1970: 100))
    let rows = try await repository.entries()
    XCTAssertEqual(rows.map(\.text), ["Keep"])
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM corrections", -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(statement, 0), 0)
  }
  func testSearchStatisticsAndDeletionUseTheRealSchema() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let writer = HistoryStore(config: config)
    writer.record(record(text: "Quoted 100% value", words: 3, latency: 100, cost: 0.001))
    writer.record(record(text: "literal_under_score", words: 1, latency: 300, cost: 0.002))
    writer.close()
    let repository = HistoryRepository(path: config.historyDbPath)
    let all = try await repository.entries()
    XCTAssertEqual(all.count, 2)
    XCTAssertEqual(all.first?.text, "literal_under_score")
    let percent = try await repository.entries(search: "%")
    XCTAssertEqual(percent.map(\.text), ["Quoted 100% value"])
    let underscore = try await repository.entries(search: "_")
    XCTAssertEqual(underscore.map(\.text), ["literal_under_score"])
    let stats = try await repository.statistics(since: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(stats.count, 2)
    XCTAssertEqual(stats.words, 4)
    XCTAssertEqual(stats.cost, 0.003, accuracy: 0.000001)
    XCTAssertEqual(stats.medianMs, 200)
    XCTAssertEqual(stats.p95Ms, 290)
    try await repository.prune(before: Date(timeIntervalSince1970: 0))
    let retained = try await repository.entries()
    XCTAssertEqual(retained.count, 2)
    try await repository.delete(ids: [all[0].id])
    let remaining = try await repository.entries()
    XCTAssertEqual(remaining.count, 1)
    try await repository.clear()
    let cleared = try await repository.entries()
    XCTAssertTrue(cleared.isEmpty)
  }

  func testCountMatchesEntriesFilterIndependentOfLimit() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let writer = HistoryStore(config: config)
    for index in 0..<7 {
      writer.record(record(text: "Row \(index)", words: 1, latency: 100, cost: 0))
    }
    writer.record(record(text: "Other app text", words: 1, latency: 100, cost: 0))
    writer.close()
    let repository = HistoryRepository(path: config.historyDbPath)
    // count(search:since:) must use the same WHERE clause as entries(...), so a
    // capped limit never hides how many rows actually match (audit F31).
    let total = try await repository.count()
    XCTAssertEqual(total, 8)
    let capped = try await repository.entries(limit: 3)
    XCTAssertEqual(capped.count, 3)
    let filtered = try await repository.count(search: "Row")
    XCTAssertEqual(filtered, 7)
    let none = try await repository.count(search: "nonexistent")
    XCTAssertEqual(none, 0)
  }

  private func record(text: String, words: Int, latency: Double, cost: Double) -> TurnRecord {
    TurnRecord(
      outcome: "success", text: text, charCount: text.count, wordCount: words,
      transport: "Live", model: "fixture", isLiveRoute: true, fallbackReason: nil,
      audioSeconds: 1, firstTokenMs: nil, roundtripMs: latency, captureFinalizeMs: 0,
      injectMs: 0, totalMs: latency, injected: true, inputTokens: nil, outputTokens: nil,
      tokensMetered: false, costUSD: cost, languageCodes: "en-IN", smartMode: true,
      vadMode: "manual", error: nil, appBundleId: "fixture.app", appName: "Fixture",
      inputDevice: nil, inputTransport: nil, deliveryOutcome: "dispatched")
  }
}
