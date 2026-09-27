// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import XCTest

@testable import TokEngine

/// Build 15 stored TypeSafe judgments in `corrections.genuineness` and `transcriptions.jev_*`.
/// Opening such a database drops those columns and keeps every row.
final class HistoryStoreRetiredColumnsTests: XCTestCase {
  private static let retiredTranscriptionColumns: Set<String> = [
    "jev_filler", "jev_plausibility", "jev_register", "jev_language", "jev_model", "jev_ms",
    "jev_input_tokens",
  ]

  func testOpeningABuild15DatabaseDropsJudgmentColumnsAndKeepsRows() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path

    makeBuild15Database(config)

    let reopened = HistoryStore(config: config)
    defer { reopened.close() }
    reopened.record(Self.turn("after upgrade"))
    reopened.recordCorrection(wrong: "cot", right: "Kot", appName: "Fixture")
    reopened.queue.sync {}

    XCTAssertTrue(
      columnNames(config.historyDbPath, table: "transcriptions")
        .isDisjoint(with: Self.retiredTranscriptionColumns))
    XCTAssertFalse(columnNames(config.historyDbPath, table: "corrections").contains("genuineness"))
    XCTAssertEqual(
      strings(config.historyDbPath, "SELECT text FROM transcriptions ORDER BY id"),
      [
        "seed", "after upgrade",
      ])
    XCTAssertEqual(
      strings(config.historyDbPath, "SELECT source FROM corrections ORDER BY id"),
      ["ax_readback", "ax_readback"])
  }

  func testLaunchCleanupDropsJudgmentColumnsWithoutAHistoryStore() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    config.historyEnabled = false
    makeBuild15Database(config)

    HistoryRetiredColumns.removeIfPresent(configuration: config)

    XCTAssertTrue(
      columnNames(config.historyDbPath, table: "transcriptions")
        .isDisjoint(with: Self.retiredTranscriptionColumns))
    XCTAssertFalse(columnNames(config.historyDbPath, table: "corrections").contains("genuineness"))
    XCTAssertEqual(strings(config.historyDbPath, "SELECT text FROM transcriptions"), ["seed"])
    XCTAssertEqual(strings(config.historyDbPath, "SELECT source FROM corrections"), ["ax_readback"])
  }

  func testLaunchCleanupNeverCreatesADatabase() {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path

    HistoryRetiredColumns.removeIfPresent(configuration: config)

    XCTAssertFalse(FileManager.default.fileExists(atPath: config.historyDbPath))
  }

  /// A history database as build 15 left it: one row, the judgment columns filled, and one
  /// TypeSafe-confirmed correction.
  private func makeBuild15Database(_ config: EngineConfiguration) {
    let first = HistoryStore(config: config)
    first.record(Self.turn("seed"))
    first.queue.sync {}
    first.close()

    execute(
      config.historyDbPath,
      [
        "ALTER TABLE corrections ADD COLUMN genuineness REAL",
        "ALTER TABLE transcriptions ADD COLUMN jev_filler REAL",
        "ALTER TABLE transcriptions ADD COLUMN jev_plausibility REAL",
        "ALTER TABLE transcriptions ADD COLUMN jev_register TEXT",
        "ALTER TABLE transcriptions ADD COLUMN jev_language TEXT",
        "ALTER TABLE transcriptions ADD COLUMN jev_model TEXT",
        "ALTER TABLE transcriptions ADD COLUMN jev_ms INTEGER",
        "ALTER TABLE transcriptions ADD COLUMN jev_input_tokens INTEGER",
        "UPDATE transcriptions SET jev_filler = 0.1, jev_register = 'chat'",
        """
        INSERT INTO corrections (ts_utc, ts_epoch, session_id, wrong_text, right_text, source, genuineness)
        VALUES ('2026-09-26T00:00:00Z', 0, 's', 'cloud', 'Claude', 'ax_readback_jev', 0.9)
        """,
      ])
    XCTAssertTrue(
      columnNames(config.historyDbPath, table: "transcriptions")
        .isSuperset(of: Self.retiredTranscriptionColumns))
  }

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

  private func execute(_ path: String, _ statements: [String]) {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return XCTFail("could not open fixture") }
    defer { sqlite3_close(db) }
    for sql in statements {
      guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        XCTFail("fixture SQL failed: \(String(cString: sqlite3_errmsg(db)))")
        return
      }
    }
  }

  private func columnNames(_ path: String, table: String) -> Set<String> {
    Set(strings(path, "SELECT name FROM pragma_table_info('\(table)')"))
  }

  private func strings(_ path: String, _ sql: String) -> [String] {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK else { return [] }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    var result: [String] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      result.append(sqlite3_column_text(statement, 0).map { String(cString: $0) } ?? "")
    }
    return result
  }
}
