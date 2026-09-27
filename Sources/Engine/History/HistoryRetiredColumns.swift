// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

/// Build 15 stored third-party (TypeSafe) judgments in `corrections.genuineness` and
/// `transcriptions.jev_*`. These columns are dropped so no judgment outlives the removed
/// integration. Rows are kept.
public enum HistoryRetiredColumns {
  static let columns: [(table: String, column: String)] = [
    ("corrections", "genuineness"), ("transcriptions", "jev_filler"),
    ("transcriptions", "jev_plausibility"), ("transcriptions", "jev_register"),
    ("transcriptions", "jev_language"), ("transcriptions", "jev_model"),
    ("transcriptions", "jev_ms"), ("transcriptions", "jev_input_tokens"),
  ]

  /// Called at launch whether or not history is on, so the cleanup does not wait for the next
  /// recorded turn. Never creates a database: a missing file has nothing to clean.
  public static func removeIfPresent(configuration: EngineConfiguration) {
    let path = HistoryStore.resolvedPath(configuration)
    guard FileManager.default.fileExists(atPath: path) else { return }
    var handle: OpaquePointer?
    guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
      let db = handle
    else {
      Log.warn("HISTORY", "Could not open history to remove retired judgment columns.")
      if let handle { sqlite3_close(handle) }
      return
    }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "PRAGMA busy_timeout=2000;", nil, nil, nil)
    remove(from: db)
  }

  /// Drops every retired column that is present. A failure is logged and retried on the next
  /// open. `secure_delete` zeroes the freed pages so the old values do not stay in the file.
  static func remove(from db: OpaquePointer) {
    let present = columns.filter { hasColumn(db, table: $0.table, column: $0.column) }
    guard !present.isEmpty else { return }
    sqlite3_exec(db, "PRAGMA secure_delete=ON;", nil, nil, nil)
    for (table, column) in present {
      if sqlite3_exec(db, "ALTER TABLE \(table) DROP COLUMN \(column)", nil, nil, nil) != SQLITE_OK
      {
        Log.warn(
          "HISTORY",
          "Could not drop retired column \(table).\(column): \(String(cString: sqlite3_errmsg(db)))"
        )
      }
    }
    sqlite3_exec(
      db, "UPDATE corrections SET source = 'ax_readback' WHERE source = 'ax_readback_jev'",
      nil, nil, nil)
  }

  private static func hasColumn(_ db: OpaquePointer, table: String, column: String) -> Bool {
    var statement: OpaquePointer?
    let sql = "SELECT 1 FROM pragma_table_info('\(table)') WHERE name = ?"
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return false }
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_text(statement, 1, column, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    return sqlite3_step(statement) == SQLITE_ROW
  }
}
