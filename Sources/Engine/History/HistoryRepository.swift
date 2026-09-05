import Foundation
import SQLite3

// The path is immutable and each database connection stays on the serial queue.
public final class HistoryRepository: @unchecked Sendable {
  private let path: String
  private let queue = DispatchQueue(label: "com.adhishthite.tok.history-query", qos: .userInitiated)
  public init(path: String) {
    self.path =
      NSString(string: path.isEmpty ? "~/Library/Application Support/Tok/history.db" : path)
      .expandingTildeInPath
  }
  public func entries(search: String = "", since: Date? = nil, limit: Int = 500) async throws
    -> [HistoryEntry]
  {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          guard FileManager.default.fileExists(atPath: self.path) else {
            continuation.resume(returning: [])
            return
          }
          let rows = try self.withDatabase { db -> [HistoryEntry] in
            let sql = """
              SELECT id,ts_epoch,COALESCE(text,''),outcome,COALESCE(app_name,''),
                CASE WHEN is_live_route=1 THEN 'Live' WHEN is_live_route=0 THEN 'Fallback' ELSE COALESCE(transport,'') END,
                COALESCE(model,''),word_count,cost_usd,input_tokens,output_tokens,COALESCE(tokens_metered,0),
                audio_seconds,event_queue_ms,capture_finalize_ms,first_token_ms,roundtrip_ms,inject_ms,total_ms,ready_ms,
                COALESCE(delivery_outcome,''),COALESCE(finish_mode,''),COALESCE(error,'')
              FROM transcriptions WHERE ts_epoch >= ? AND
                (COALESCE(text,'') LIKE ? ESCAPE char(92) OR COALESCE(app_name,'') LIKE ? ESCAPE char(92))
              ORDER BY ts_epoch DESC,id DESC LIMIT ?
              """
            let statement = try Self.prepare(db, sql)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, since?.timeIntervalSince1970 ?? 0)
            let term =
              "%"
              + search.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(
                of: "%", with: "\\%"
              ).replacingOccurrences(of: "_", with: "\\_") + "%"
            Self.bind(statement, 2, term)
            Self.bind(statement, 3, term)
            sqlite3_bind_int(statement, 4, Int32(limit <= 0 ? -1 : min(limit, 10000)))
            var rows: [HistoryEntry] = []
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
              rows.append(
                HistoryEntry(
                  id: sqlite3_column_int64(statement, 0),
                  date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                  text: Self.text(statement, 2), outcome: Self.text(statement, 3),
                  app: Self.text(statement, 4), route: Self.text(statement, 5),
                  model: Self.text(statement, 6), words: Int(sqlite3_column_int(statement, 7)),
                  cost: Self.number(statement, 8), inputTokens: Self.integer(statement, 9),
                  outputTokens: Self.integer(statement, 10),
                  metered: sqlite3_column_int(statement, 11) == 1,
                  audioSeconds: Self.number(statement, 12),
                  eventQueueMs: Self.number(statement, 13), captureMs: Self.number(statement, 14),
                  firstTokenMs: Self.number(statement, 15), apiMs: Self.number(statement, 16),
                  injectionMs: Self.number(statement, 17), totalMs: Self.number(statement, 18),
                  readyMs: Self.number(statement, 19), delivery: Self.text(statement, 20),
                  finishMode: Self.text(statement, 21), error: Self.text(statement, 22)))
              status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE else { throw HistoryRepositoryError.queryFailed }
            return rows
          }
          continuation.resume(returning: rows)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  public func statistics(since: Date) async throws -> HistoryStatistics {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          guard FileManager.default.fileExists(atPath: self.path) else {
            continuation.resume(returning: .empty)
            return
          }
          let result = try self.withDatabase { db -> HistoryStatistics in
            let stmt = try Self.prepare(
              db,
              "SELECT word_count,cost_usd,total_ms FROM transcriptions WHERE outcome='success' AND ts_epoch >= ?"
            )
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            var count = 0
            var words = 0
            var cost = 0.0
            var latencies: [Double] = []
            var status = sqlite3_step(stmt)
            while status == SQLITE_ROW {
              count += 1
              words += Int(sqlite3_column_int(stmt, 0))
              cost += Self.number(stmt, 1) ?? 0
              if let value = Self.number(stmt, 2), value.isFinite { latencies.append(value) }
              status = sqlite3_step(stmt)
            }
            guard status == SQLITE_DONE else { throw HistoryRepositoryError.queryFailed }
            latencies.sort()
            return HistoryStatistics(
              count: count, words: words, cost: cost, medianMs: Self.percentile(latencies, 0.5),
              p95Ms: Self.percentile(latencies, 0.95))
          }
          continuation.resume(returning: result)
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  public func delete(ids: Set<Int64>) async throws {
    guard !ids.isEmpty else { return }
    try await mutate { db in
      guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
        throw HistoryRepositoryError.queryFailed
      }
      do {
        let stmt = try Self.prepare(db, "DELETE FROM transcriptions WHERE id=?")
        defer { sqlite3_finalize(stmt) }
        for id in ids {
          sqlite3_reset(stmt)
          sqlite3_bind_int64(stmt, 1, id)
          guard sqlite3_step(stmt) == SQLITE_DONE else { throw HistoryRepositoryError.queryFailed }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
          throw HistoryRepositoryError.queryFailed
        }
      } catch {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        throw error
      }
    }
  }
  public func prune(before cutoff: Date) async throws {
    try await mutate { db in
      guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
        throw HistoryRepositoryError.queryFailed
      }
      do {
        for table in ["transcriptions", "corrections"] {
          let statement = try Self.prepare(db, "DELETE FROM \(table) WHERE ts_epoch < ?")
          defer { sqlite3_finalize(statement) }
          sqlite3_bind_double(statement, 1, cutoff.timeIntervalSince1970)
          guard sqlite3_step(statement) == SQLITE_DONE else {
            throw HistoryRepositoryError.queryFailed
          }
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
          throw HistoryRepositoryError.queryFailed
        }
      } catch {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        throw error
      }
    }
  }
  public func clear() async throws {
    try await mutate { db in
      guard
        sqlite3_exec(
          db, "BEGIN IMMEDIATE; DELETE FROM transcriptions; DELETE FROM corrections; COMMIT;", nil,
          nil, nil) == SQLITE_OK
      else {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        throw HistoryRepositoryError.queryFailed
      }
    }
  }
  private func mutate(_ body: @escaping (OpaquePointer) throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      queue.async {
        do {
          guard FileManager.default.fileExists(atPath: self.path) else {
            continuation.resume()
            return
          }
          try self.withDatabase(body)
          continuation.resume()
        } catch { continuation.resume(throwing: error) }
      }
    }
  }
  private func withDatabase<Value>(_ body: (OpaquePointer) throws -> Value) throws -> Value {
    var db: OpaquePointer?
    guard
      sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
      let handle = db
    else {
      if let db { sqlite3_close(db) }
      throw HistoryRepositoryError.databaseUnavailable
    }
    defer { sqlite3_close(handle) }
    sqlite3_busy_timeout(handle, 2000)
    return try body(handle)
  }
  private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw HistoryRepositoryError.queryFailed
    }
    return statement
  }
  private static func bind(_ stmt: OpaquePointer, _ index: Int32, _ value: String) {
    sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
  }
  private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
    guard let bytes = sqlite3_column_text(stmt, index) else { return "" }
    return String(
      decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(stmt, index))),
      as: UTF8.self)
  }
  private static func number(_ stmt: OpaquePointer, _ index: Int32) -> Double? {
    sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, index)
  }
  private static func integer(_ stmt: OpaquePointer, _ index: Int32) -> Int? {
    sqlite3_column_type(stmt, index) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, index))
  }
  private static func percentile(_ sorted: [Double], _ quantile: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let position = Double(sorted.count - 1) * quantile
    let lower = Int(position)
    let upper = min(sorted.count - 1, Int(position.rounded(.up)))
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
  }
}
