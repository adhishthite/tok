// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import XCTest

@testable import TokEngine

/// Engine/Judgment, item 1 and item 3: the corrections.genuineness column, the
/// transcriptions.jev_* columns, and the record/updateJudgment correlation path.
final class HistoryStoreJudgmentTests: XCTestCase {
  func testMigrationAddsJevColumns() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }
    store.record(Self.turn("seed"))
    store.queue.sync {}

    XCTAssertEqual(
      columnNames(config.historyDbPath, table: "transcriptions").intersection([
        "jev_filler", "jev_plausibility", "jev_register", "jev_language", "jev_model", "jev_ms",
        "jev_input_tokens",
      ]).count, 7)
    XCTAssertTrue(columnNames(config.historyDbPath, table: "corrections").contains("genuineness"))

    // Reopening runs the whole ALTER list again against a DB that already has every column.
    // The existing pattern ignores the duplicate-column error, so this must stay a no-op and
    // must not lose the seeded row.
    store.close()
    let reopened = HistoryStore(config: config)
    defer { reopened.close() }
    reopened.record(Self.turn("second run"))
    reopened.queue.sync {}
    XCTAssertEqual(rowCount(config.historyDbPath), 2)
    XCTAssertTrue(
      columnNames(config.historyDbPath, table: "transcriptions").isSuperset(of: [
        "jev_filler", "jev_plausibility", "jev_register", "jev_language", "jev_model", "jev_ms",
        "jev_input_tokens",
      ]))
  }

  func testRecordCompletionDeliversRowidAndUpdateJudgmentWritesColumns() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }

    let rowidExpectation = expectation(description: "rowid delivered")
    var deliveredRowid: Int64?
    store.record(Self.turn("hello world")) { rowid in
      deliveredRowid = rowid
      rowidExpectation.fulfill()
    }
    wait(for: [rowidExpectation], timeout: 5)
    let rowid = try XCTUnwrap(deliveredRowid)
    XCTAssertGreaterThan(rowid, 0)

    store.updateJudgment(
      rowid: rowid, filler: 0.05, plausibility: 3.4, register: "chat", language: "english",
      model: "jev-1.13.0", ms: 320, inputTokens: 88)
    store.queue.sync {}

    let row = try XCTUnwrap(jevRow(config.historyDbPath, rowid: rowid))
    XCTAssertEqual(row.filler ?? -1, 0.05, accuracy: 0.0001)
    XCTAssertEqual(row.plausibility ?? -1, 3.4, accuracy: 0.0001)
    XCTAssertEqual(row.register, "chat")
    XCTAssertEqual(row.language, "english")
    XCTAssertEqual(row.model, "jev-1.13.0")
    XCTAssertEqual(row.ms, 320)
    XCTAssertEqual(row.inputTokens, 88)
  }

  func testRecordWithoutCompletionStillInsertsUnaffected() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }
    store.record(Self.turn("no completion"))
    store.queue.sync {}
    XCTAssertEqual(rowCount(config.historyDbPath), 1)
  }

  func testRecordCorrectionStoresGenuinenessAndSource() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }

    store.recordCorrection(wrong: "cloud", right: "Claude", appName: "Notes")
    store.recordCorrection(
      wrong: "cot", right: "Kot", appName: "Notes", genuineness: 0.91, source: "ax_readback_jev")
    store.queue.sync {}

    let rows = correctionRows(config.historyDbPath)
    XCTAssertEqual(rows.count, 2)
    XCTAssertEqual(rows[0].source, "ax_readback")
    XCTAssertNil(rows[0].genuineness)
    XCTAssertEqual(rows[1].source, "ax_readback_jev")
    XCTAssertEqual(rows[1].genuineness ?? -1, 0.91, accuracy: 0.0001)
  }

  // MARK: - Fixtures

  private static func turn(_ text: String) -> TurnRecord {
    TurnRecord(
      outcome: "success", text: text, charCount: text.count, wordCount: 1,
      transport: "Live", model: "fixture", isLiveRoute: true, fallbackReason: nil,
      audioSeconds: 1, firstTokenMs: nil, roundtripMs: 100, captureFinalizeMs: 0,
      injectMs: 0, totalMs: 100, injected: true, inputTokens: nil, outputTokens: nil,
      tokensMetered: false, costUSD: 0, languageCodes: "en-IN", smartMode: true,
      vadMode: "manual", error: nil, appBundleId: "fixture.app", appName: "Fixture",
      inputDevice: nil, inputTransport: nil, deliveryOutcome: "dispatched")
  }

  private func columnNames(_ path: String, table: String) -> Set<String> {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &statement, nil) == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var result: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = sqlite3_column_text(statement, 1) { result.insert(String(cString: name)) }
    }
    return result
  }

  private func rowCount(_ path: String) -> Int {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return -1 }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM transcriptions", -1, &statement, nil)
        == SQLITE_OK
    else { return -1 }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { return -1 }
    return Int(sqlite3_column_int(statement, 0))
  }

  private struct JevRow {
    let filler: Double?
    let plausibility: Double?
    let register: String?
    let language: String?
    let model: String?
    let ms: Int?
    let inputTokens: Int?
  }

  private func jevRow(_ path: String, rowid: Int64) -> JevRow? {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return nil }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let sql =
      "SELECT jev_filler, jev_plausibility, jev_register, jev_language, jev_model, jev_ms, jev_input_tokens FROM transcriptions WHERE id = ?"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_int64(statement, 1, rowid)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    func double(_ idx: Int32) -> Double? {
      sqlite3_column_type(statement, idx) == SQLITE_NULL
        ? nil : sqlite3_column_double(statement, idx)
    }
    func text(_ idx: Int32) -> String? {
      sqlite3_column_text(statement, idx).map { String(cString: $0) }
    }
    func int(_ idx: Int32) -> Int? {
      sqlite3_column_type(statement, idx) == SQLITE_NULL
        ? nil : Int(sqlite3_column_int64(statement, idx))
    }
    return JevRow(
      filler: double(0), plausibility: double(1), register: text(2), language: text(3),
      model: text(4), ms: int(5), inputTokens: int(6))
  }

  private struct CorrectionRow {
    let source: String
    let genuineness: Double?
  }

  private func correctionRows(_ path: String) -> [CorrectionRow] {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(
        db, "SELECT source, genuineness FROM corrections ORDER BY id", -1, &statement, nil)
        == SQLITE_OK
    else { return [] }
    defer { sqlite3_finalize(statement) }
    var rows: [CorrectionRow] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      let source = sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? ""
      let genuineness =
        sqlite3_column_type(statement, 1) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 1)
      rows.append(CorrectionRow(source: source, genuineness: genuineness))
    }
    return rows
  }
}
