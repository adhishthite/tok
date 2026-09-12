import Foundation
import SQLite3
import XCTest

@testable import TokEngine

/// Audit F29. A single busy database used to latch HistoryStore.failed for the lifetime of
/// the engine, silently, so every later dictation went unrecorded.
final class HistoryStoreResilienceTests: XCTestCase {
  func testBusyDatabaseRetriesThenReportsAndRecovers() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    var config = EngineConfiguration()
    config.historyDbPath = directory.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }

    let reportLock = NSLock()
    var messages: [String?] = []
    let failure = expectation(description: "Lost row reported")
    let recovery = expectation(description: "Recovery reported")
    store.onError = { message in
      reportLock.lock()
      messages.append(message)
      reportLock.unlock()
      if message == nil { recovery.fulfill() } else { failure.fulfill() }
    }

    store.record(Self.turn("first"))
    store.queue.sync {}
    XCTAssertEqual(rowCount(config.historyDbPath), 1)

    // A lock shorter than the connection's 2 s busy timeout: the row must still land and
    // nothing is reported.
    let transient = try WriteLock(path: config.historyDbPath)
    DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { transient.release() }
    store.record(Self.turn("transient"))
    store.queue.sync {}
    XCTAssertEqual(rowCount(config.historyDbPath), 2)
    reportLock.lock()
    XCTAssertTrue(messages.isEmpty, "a lock that clears in time is not a user-visible error")
    reportLock.unlock()

    // A lock held past the busy timeout and both retries: this row is lost, and only this
    // row.
    let sustained = try WriteLock(path: config.historyDbPath)
    store.record(Self.turn("lost"))
    wait(for: [failure], timeout: 30)
    reportLock.lock()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(
      messages.first ?? nil, "History could not be saved. The database is busy or unavailable.")
    reportLock.unlock()

    sustained.release()
    store.record(Self.turn("after"))
    wait(for: [recovery], timeout: 30)
    store.queue.sync {}
    XCTAssertEqual(rowCount(config.historyDbPath), 3, "history keeps working after a lost row")
  }

  func testOpenFailureDoesNotLatchOnTheFirstAttempt() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // A plain file where the history directory belongs: creating the directory fails.
    let blocker = directory.appendingPathComponent("blocked")
    try Data().write(to: blocker)
    var config = EngineConfiguration()
    config.historyDbPath = blocker.appendingPathComponent("history.db").path
    let store = HistoryStore(config: config)
    defer { store.close() }
    let failure = expectation(description: "Open failure reported")
    let recovery = expectation(description: "Recovery reported")
    store.onError = { if $0 == nil { recovery.fulfill() } else { failure.fulfill() } }

    store.record(Self.turn("before"))
    wait(for: [failure], timeout: 5)
    store.queue.sync { XCTAssertFalse(store.failed, "one bad open must not latch") }

    try FileManager.default.removeItem(at: blocker)
    store.record(Self.turn("after"))
    wait(for: [recovery], timeout: 5)
    store.queue.sync {}
    XCTAssertEqual(rowCount(config.historyDbPath), 1)
  }

  // Holds the database's single write slot from a second connection, the way another
  // process browsing history would.
  private final class WriteLock {
    private var db: OpaquePointer?
    init(path: String) throws {
      var handle: OpaquePointer?
      guard sqlite3_open(path, &handle) == SQLITE_OK, let opened = handle else {
        throw CocoaError(.fileReadUnknown)
      }
      db = opened
      guard sqlite3_exec(opened, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
        throw CocoaError(.fileWriteNoPermission)
      }
    }
    func release() {
      guard let db = db else { return }
      sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
      sqlite3_close(db)
      self.db = nil
    }
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
