import Foundation
import SQLite3
import XCTest

@testable import TokEngine

/// Connection state, hedge, and round-trip split. Covers the additive migration,
/// TurnRecord round-tripping the new transcriptions columns through HistoryStore, and the
/// new connection_events table: insert, retention pruning, and the delete-all-history path.
final class ConnectionStateHistoryTests: XCTestCase {

  // MARK: - Migration

  func testMigrationAddsItemDColumns() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    store.record(Self.turn("seed"))
    store.queue.sync {}
    store.close()

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    let expectedColumns = [
      "socket_state_at_keydown", "socket_age_ms", "reconnected_during_turn", "hedge_fired",
      "hedge_winner", "commit_to_last_send_ms", "commit_to_first_msg_ms", "commit_to_final_ms",
      "commit_to_turn_complete_ms",
    ]
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(db, "PRAGMA table_info(transcriptions)", -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    var found = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 1) else { continue }
      found.insert(String(cString: name))
    }
    for column in expectedColumns {
      XCTAssertTrue(found.contains(column), "missing column \(column)")
    }
  }

  func testConnectionEventsTableIsCreated() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    store.record(Self.turn("seed"))
    store.queue.sync {}
    store.close()

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(db, "PRAGMA table_info(connection_events)", -1, &statement, nil),
      SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    var found = Set<String>()
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let name = sqlite3_column_text(statement, 1) else { continue }
      found.insert(String(cString: name))
    }
    for column in ["id", "ts_epoch", "kind", "turn_open", "socket_age_s", "build_id"] {
      XCTAssertTrue(found.contains(column), "missing column \(column)")
    }
  }

  // MARK: - Round trip through HistoryStore

  func testNewFieldsRoundTripThroughHistoryStore() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }

    var record = Self.turn("round trip")
    record.socketStateAtKeydown = "ready"
    record.socketAgeMs = 4200.0
    record.reconnectedDuringTurn = true
    record.hedgeFired = true
    record.hedgeWinner = "rest"
    record.commitToLastSendMs = 12.0
    record.commitToFirstMsgMs = 88.0
    record.commitToFinalMs = 340.0
    record.commitToTurnCompleteMs = 360.0
    store.record(record)
    store.queue.sync {}

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let sql = """
      SELECT socket_state_at_keydown, socket_age_ms, reconnected_during_turn, hedge_fired,
        hedge_winner, commit_to_last_send_ms, commit_to_first_msg_ms, commit_to_final_ms,
        commit_to_turn_complete_ms
      FROM transcriptions WHERE text = 'round trip'
      """
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "ready")
    XCTAssertEqual(sqlite3_column_double(statement, 1), 4200.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_int(statement, 2), 1)
    XCTAssertEqual(sqlite3_column_int(statement, 3), 1)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 4)), "rest")
    XCTAssertEqual(sqlite3_column_double(statement, 5), 12.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 6), 88.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 7), 340.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 8), 360.0, accuracy: 0.001)
  }

  func testUnsetNewFieldsStoreNull() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }
    store.record(Self.turn("bare"))
    store.queue.sync {}

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        db,
        "SELECT hedge_fired, hedge_winner, commit_to_final_ms FROM transcriptions WHERE text = 'bare'",
        -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_type(statement, 0), SQLITE_NULL)
    XCTAssertEqual(sqlite3_column_type(statement, 1), SQLITE_NULL)
    XCTAssertEqual(sqlite3_column_type(statement, 2), SQLITE_NULL)
  }

  // MARK: - connection_events: insert, retention, delete-all

  func testConnectionEventInsertsAsynchronouslyWithBuildId() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    config.buildId = "fixture-build"
    let store = HistoryStore(config: config)
    defer { store.close() }
    store.recordConnectionEvent(kind: "connect_wake", turnOpen: false, socketAgeS: nil)
    store.recordConnectionEvent(kind: "lost_keepalive", turnOpen: true, socketAgeS: 42.5)
    store.queue.sync {}

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(
        db, "SELECT kind, turn_open, socket_age_s, build_id FROM connection_events ORDER BY id",
        -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "connect_wake")
    XCTAssertEqual(sqlite3_column_int(statement, 1), 0)
    XCTAssertEqual(sqlite3_column_type(statement, 2), SQLITE_NULL)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 3)), "fixture-build")
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "lost_keepalive")
    XCTAssertEqual(sqlite3_column_int(statement, 1), 1)
    XCTAssertEqual(sqlite3_column_double(statement, 2), 42.5, accuracy: 0.001)
    XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
  }

  func testRetentionPrunesConnectionEventsAlongsideTranscriptions() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let writer = HistoryStore(config: config)
    writer.record(Self.turn("keep"))
    writer.recordConnectionEvent(kind: "connect_startup", turnOpen: false, socketAgeS: nil)
    writer.queue.sync {}
    writer.close()

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    XCTAssertEqual(
      sqlite3_exec(
        db, "UPDATE transcriptions SET ts_epoch=1; UPDATE connection_events SET ts_epoch=1;", nil,
        nil, nil), SQLITE_OK)

    let repository = HistoryRepository(path: config.historyDbPath)
    try await repository.prune(before: Date(timeIntervalSince1970: 100))

    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM connection_events", -1, &statement, nil),
      SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_int(statement, 0), 0, "expired connection events are pruned too")
  }

  func testClearDeletesConnectionEventsToo() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let writer = HistoryStore(config: config)
    writer.record(Self.turn("row"))
    writer.recordConnectionEvent(kind: "connect_startup", turnOpen: false, socketAgeS: nil)
    writer.queue.sync {}
    writer.close()

    let repository = HistoryRepository(path: config.historyDbPath)
    try await repository.clear()

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    XCTAssertEqual(
      sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM connection_events", -1, &statement, nil),
      SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(
      sqlite3_column_int(statement, 0), 0, "delete-all-history clears connection_events too")
  }

  func testPruneAndClearToleratePreexistingDatabaseMissingConnectionEvents() async throws {
    // A database this process has not opened with HistoryStore yet (so its connection_events
    // table was never created) must not fail prune/clear outright.
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("history.db").path
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true)
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
    XCTAssertEqual(
      sqlite3_exec(
        db,
        "CREATE TABLE transcriptions (id INTEGER PRIMARY KEY, ts_epoch REAL); "
          + "CREATE TABLE corrections (id INTEGER PRIMARY KEY, ts_epoch REAL);", nil, nil, nil),
      SQLITE_OK)
    sqlite3_close(db)

    let repository = HistoryRepository(path: path)
    try await repository.prune(before: Date())
    try await repository.clear()
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
}
