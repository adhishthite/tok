import Foundation
import SQLite3

/// Local dictation stats: one row of counts and timing per dictation, plus per-day word
/// frequencies. Kept apart from history so totals survive history being off, pruned, or
/// cleared. Transcripts are never written here. Each call opens its own connection on
/// the serial queue, like `HistoryRepository`.
public final class StatsRepository: @unchecked Sendable {
  public static let fileName = "stats.db"
  public static let wordListLimit = 25
  public let url: URL
  private let queue = DispatchQueue(label: "com.adhishthite.tok.stats", qos: .utility)
  private let calendar: Calendar
  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
  private static let schema = """
    CREATE TABLE IF NOT EXISTS dictations (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      ts_epoch REAL NOT NULL,
      day TEXT NOT NULL,
      outcome TEXT NOT NULL,
      words INTEGER NOT NULL DEFAULT 0,
      chars INTEGER NOT NULL DEFAULT 0,
      audio_seconds REAL,
      total_ms REAL,
      app_name TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_dictations_ts ON dictations(ts_epoch);
    CREATE TABLE IF NOT EXISTS word_days (
      day TEXT NOT NULL,
      word TEXT NOT NULL,
      count INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (day, word)
    ) WITHOUT ROWID;
    """

  public init(directory: URL, calendar: Calendar = .current) {
    self.url = directory.appendingPathComponent(Self.fileName)
    self.calendar = calendar
  }

  /// Adds one settled turn. Words are counted only for successful dictations, and only
  /// when `trackWords` is on.
  public func record(_ turn: TurnRecord, trackWords: Bool, date: Date = Date()) async throws {
    let words =
      trackWords && turn.outcome == "success"
      ? Self.counts(StatsWordTokenizer.words(in: turn.text ?? "")) : [:]
    let day = StatsCalculator.dayKey(for: date, calendar: calendar)
    try await withDatabase(create: true) { db in
      guard let db else { throw StatsRepositoryError.databaseUnavailable }
      try Self.execute(db, "BEGIN IMMEDIATE")
      do {
        let insert = try Self.prepare(
          db,
          "INSERT INTO dictations (ts_epoch, day, outcome, words, chars, audio_seconds, total_ms, app_name) VALUES (?,?,?,?,?,?,?,?)"
        )
        defer { sqlite3_finalize(insert) }
        sqlite3_bind_double(insert, 1, date.timeIntervalSince1970)
        Self.bind(insert, 2, day)
        Self.bind(insert, 3, turn.outcome)
        sqlite3_bind_int64(insert, 4, Int64(turn.wordCount))
        sqlite3_bind_int64(insert, 5, Int64(turn.charCount))
        Self.bind(insert, 6, turn.audioSeconds)
        Self.bind(insert, 7, turn.totalMs)
        Self.bind(insert, 8, turn.appName)
        guard sqlite3_step(insert) == SQLITE_DONE else { throw StatsRepositoryError.queryFailed }
        if !words.isEmpty {
          let upsert = try Self.prepare(
            db,
            "INSERT INTO word_days (day, word, count) VALUES (?,?,?) ON CONFLICT(day, word) DO UPDATE SET count = count + excluded.count"
          )
          defer { sqlite3_finalize(upsert) }
          for (word, count) in words {
            sqlite3_reset(upsert)
            Self.bind(upsert, 1, day)
            Self.bind(upsert, 2, word)
            sqlite3_bind_int64(upsert, 3, Int64(count))
            guard sqlite3_step(upsert) == SQLITE_DONE else {
              throw StatsRepositoryError.queryFailed
            }
          }
        }
        try Self.execute(db, "COMMIT")
      } catch {
        sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        throw error
      }
    }
  }

  public func report(range: StatsRange, typingWordsPerMinute: Int, now: Date = Date())
    async throws -> StatsReport
  {
    let calendar = self.calendar
    return try await withDatabase(create: false) { db in
      guard let db else {
        return StatsReport.empty(range, typingWordsPerMinute: typingWordsPerMinute)
      }
      let window = range.interval(now: now, calendar: calendar)
      let since = window?.start ?? Date(timeIntervalSince1970: 0)
      let sinceDay = window.map { StatsCalculator.dayKey(for: $0.start, calendar: calendar) } ?? ""
      var input = StatsCalculator.Input(
        range: range, turns: try Self.turns(db, since: since), previousWords: nil,
        successDays: try Self.successDays(db), typingWordsPerMinute: typingWordsPerMinute,
        now: now, calendar: calendar)
      if let previous = range.previousStart(now: now, calendar: calendar) {
        input.previousWords = try Self.words(db, since: previous, before: since)
      }
      input.topWords = try Self.words(db, sinceDay: sinceDay, ascending: false)
      input.rareWords = try Self.words(db, sinceDay: sinceDay, ascending: true)
      input.distinctWords = try Self.distinctWords(db, sinceDay: sinceDay)
      return StatsCalculator.report(input)
    }
  }

  /// Words from successful dictations since a moment, for the menu-bar glance.
  public func words(since: Date) async throws -> Int {
    try await withDatabase(create: false) { db in
      guard let db else { return 0 }
      return try Self.words(db, since: since, before: nil)
    }
  }

  public func clear() async throws {
    try await withDatabase(create: false) { db in
      guard let db else { return }
      try Self.execute(
        db, "BEGIN IMMEDIATE; DELETE FROM dictations; DELETE FROM word_days; COMMIT;")
    }
  }

  private static func turns(_ db: OpaquePointer, since: Date) throws -> [StatsTurn] {
    let statement = try prepare(
      db,
      "SELECT ts_epoch, outcome, words, chars, audio_seconds, total_ms, COALESCE(app_name,'') FROM dictations WHERE ts_epoch >= ? ORDER BY ts_epoch, id"
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
    var rows: [StatsTurn] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      rows.append(
        StatsTurn(
          date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
          success: text(statement, 1) == "success",
          words: Int(sqlite3_column_int64(statement, 2)),
          characters: Int(sqlite3_column_int64(statement, 3)),
          audioSeconds: number(statement, 4), totalMs: number(statement, 5),
          app: text(statement, 6)))
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw StatsRepositoryError.queryFailed }
    return rows
  }

  private static func words(_ db: OpaquePointer, since: Date, before: Date?) throws -> Int {
    let statement = try prepare(
      db,
      "SELECT COALESCE(SUM(words),0) FROM dictations WHERE outcome='success' AND ts_epoch >= ? AND ts_epoch < ?"
    )
    defer { sqlite3_finalize(statement) }
    sqlite3_bind_double(statement, 1, since.timeIntervalSince1970)
    sqlite3_bind_double(statement, 2, before?.timeIntervalSince1970 ?? .greatestFiniteMagnitude)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw StatsRepositoryError.queryFailed }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private static func successDays(_ db: OpaquePointer) throws -> [String] {
    let statement = try prepare(db, "SELECT DISTINCT day FROM dictations WHERE outcome='success'")
    defer { sqlite3_finalize(statement) }
    var days: [String] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      days.append(text(statement, 0))
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw StatsRepositoryError.queryFailed }
    return days
  }

  private static func words(_ db: OpaquePointer, sinceDay: String, ascending: Bool) throws
    -> [StatsWordCount]
  {
    let order = ascending ? "n ASC, word ASC" : "n DESC, word ASC"
    let statement = try prepare(
      db,
      "SELECT word, SUM(count) AS n FROM word_days WHERE day >= ? GROUP BY word ORDER BY \(order) LIMIT ?"
    )
    defer { sqlite3_finalize(statement) }
    bind(statement, 1, sinceDay)
    sqlite3_bind_int(statement, 2, Int32(wordListLimit))
    var rows: [StatsWordCount] = []
    var status = sqlite3_step(statement)
    while status == SQLITE_ROW {
      rows.append(
        StatsWordCount(word: text(statement, 0), count: Int(sqlite3_column_int64(statement, 1))))
      status = sqlite3_step(statement)
    }
    guard status == SQLITE_DONE else { throw StatsRepositoryError.queryFailed }
    return rows
  }

  private static func distinctWords(_ db: OpaquePointer, sinceDay: String) throws -> Int {
    let statement = try prepare(
      db, "SELECT COUNT(*) FROM (SELECT word FROM word_days WHERE day >= ? GROUP BY word)")
    defer { sqlite3_finalize(statement) }
    bind(statement, 1, sinceDay)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw StatsRepositoryError.queryFailed }
    return Int(sqlite3_column_int64(statement, 0))
  }

  /// Runs `body` on the queue with an open connection. Without `create`, a missing
  /// database file yields nil so reads can answer with empty results.
  private func withDatabase<Value: Sendable>(
    create: Bool, _ body: @escaping @Sendable (OpaquePointer?) throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do {
          let path = self.url.path
          let exists = FileManager.default.fileExists(atPath: path)
          guard exists || create else {
            continuation.resume(returning: try body(nil))
            return
          }
          if !exists {
            try FileManager.default.createDirectory(
              at: self.url.deletingLastPathComponent(), withIntermediateDirectories: true,
              attributes: [.posixPermissions: 0o700])
          }
          var handle: OpaquePointer?
          let flags =
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX | (create ? SQLITE_OPEN_CREATE : 0)
          guard sqlite3_open_v2(path, &handle, flags, nil) == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close(handle) }
            throw StatsRepositoryError.databaseUnavailable
          }
          defer { sqlite3_close(db) }
          if !exists { chmod(path, 0o600) }
          sqlite3_busy_timeout(db, 2000)
          try Self.execute(db, "PRAGMA journal_mode=WAL;")
          try Self.execute(db, Self.schema)
          continuation.resume(returning: try body(db))
        } catch { continuation.resume(throwing: error) }
      }
    }
  }

  private static func counts(_ words: [String]) -> [String: Int] {
    words.reduce(into: [:]) { $0[$1, default: 0] += 1 }
  }
  private static func execute(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
      throw StatsRepositoryError.queryFailed
    }
  }
  private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw StatsRepositoryError.queryFailed
    }
    return statement
  }
  private static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String?) {
    if let value {
      sqlite3_bind_text(statement, index, value, -1, transient)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }
  private static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double?) {
    if let value, value.isFinite {
      sqlite3_bind_double(statement, index, value)
    } else {
      sqlite3_bind_null(statement, index)
    }
  }
  private static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
    guard let bytes = sqlite3_column_text(statement, index) else { return "" }
    return String(
      decoding: UnsafeBufferPointer(
        start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
  }
  private static func number(_ statement: OpaquePointer, _ index: Int32) -> Double? {
    sqlite3_column_type(statement, index) == SQLITE_NULL
      ? nil : sqlite3_column_double(statement, index)
  }
}
