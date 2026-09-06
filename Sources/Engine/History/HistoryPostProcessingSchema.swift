import SQLite3

enum HistoryPostProcessingSchema {
  static let columns = [
    ("post_process_status", "TEXT"), ("post_process_model", "TEXT"),
    ("post_process_ms", "REAL"), ("post_process_input_tokens", "INTEGER"),
    ("post_process_output_tokens", "INTEGER"), ("post_process_thinking_tokens", "INTEGER"),
    ("post_process_cost_usd", "REAL"), ("post_process_error", "TEXT"),
    ("post_process_app_context", "INTEGER"), ("transcription_cost_usd", "REAL"),
  ]

  static func migrate(_ db: OpaquePointer) throws {
    let existing = try names(db)
    guard !existing.isEmpty, columns.contains(where: { !existing.contains($0.0) }) else { return }
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
      throw HistoryRepositoryError.queryFailed
    }
    var committed = false
    defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
    // Recheck under the write lock: another connection may have migrated first.
    let locked = try names(db)
    for (name, type) in columns where !locked.contains(name) {
      guard
        sqlite3_exec(db, "ALTER TABLE transcriptions ADD COLUMN \(name) \(type)", nil, nil, nil)
          == SQLITE_OK
      else {
        throw HistoryRepositoryError.queryFailed
      }
    }
    guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
      throw HistoryRepositoryError.queryFailed
    }
    committed = true
  }

  private static func names(_ db: OpaquePointer) throws -> Set<String> {
    var statement: OpaquePointer?
    guard
      sqlite3_prepare_v2(db, "PRAGMA table_info(transcriptions)", -1, &statement, nil) == SQLITE_OK
    else {
      throw HistoryRepositoryError.queryFailed
    }
    defer { sqlite3_finalize(statement) }
    var result: Set<String> = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      if let name = sqlite3_column_text(statement, 1) { result.insert(String(cString: name)) }
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw HistoryRepositoryError.queryFailed }
    return result
  }
}
