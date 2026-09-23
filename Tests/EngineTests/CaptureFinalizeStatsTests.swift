import Foundation
import SQLite3
import XCTest

@testable import TokEngine

/// Capture finalization diagnostics. Covers the noise-floor percentile pure function,
/// the trail-exit classification pure function, the additive migration, and TurnRecord
/// round-tripping the new columns through HistoryStore.
final class CaptureFinalizeStatsTests: XCTestCase {

  // MARK: - noiseFloorDb (pure function)

  func testNoiseFloorDbIsNilBelowTenFrames() {
    XCTAssertNil(AudioCaptureEngine.noiseFloorDb(frames: Array(repeating: -40.0, count: 9)))
    XCTAssertNil(AudioCaptureEngine.noiseFloorDb(frames: []))
  }

  func testNoiseFloorDbIsTenthPercentileOfSortedFrames() {
    // 11 frames. Sorted: -90, -85, -40, -35, ..., 0. Rank = 0.10 * (11-1) = 1.0, landing
    // exactly on sorted[1] (-85), no interpolation needed.
    let frames: [Double] = [-90, -85, -40, -35, -30, -25, -20, -15, -10, -5, 0]
    XCTAssertEqual(AudioCaptureEngine.noiseFloorDb(frames: frames)!, -85, accuracy: 1e-9)
  }

  func testNoiseFloorDbInterpolatesBetweenRanks() {
    // 10 frames, sorted: -90, -85, -40, ..., 0. Rank = 0.10 * (10-1) = 0.9, 90% of the way
    // from sorted[0] (-90) to sorted[1] (-85): -90 + (-85 - -90) * 0.9 = -85.5.
    let frames: [Double] = [-90, -85, -40, -35, -30, -25, -20, -15, -10, -5]
    XCTAssertEqual(AudioCaptureEngine.noiseFloorDb(frames: frames)!, -85.5, accuracy: 1e-9)
  }

  func testNoiseFloorDbIsOrderIndependent() {
    let a = AudioCaptureEngine.noiseFloorDb(
      frames: [-10, -60, -20, -50, -30, -40, -70, -80, -90, -100])
    let b = AudioCaptureEngine.noiseFloorDb(
      frames: [-100, -90, -80, -70, -60, -50, -40, -30, -20, -10])
    XCTAssertEqual(a, b)
  }

  // MARK: - trailExitReason (pure function)

  func testTrailExitReasonIsCapWhenCapRemainingIsGone() {
    // Still speaking (quietStart nil) when the hard ceiling is reached.
    XCTAssertEqual(
      AudioCaptureEngine.trailExitReason(
        now: 2.0, entryTime: 0, quietStart: nil, graceSec: 0.25, minTrailSec: 0.06,
        maxTrailSec: 2.0, quietIsStale: false), "cap")
  }

  func testTrailExitReasonIsQuietWhenGraceAndFloorAreBothSatisfied() {
    XCTAssertEqual(
      AudioCaptureEngine.trailExitReason(
        now: 0.5, entryTime: 0, quietStart: 0.1, graceSec: 0.25, minTrailSec: 0.06,
        maxTrailSec: 2.0, quietIsStale: false), "quiet")
  }

  func testTrailExitReasonIsQuietStaleWhenTheFinalReadingWasStale() {
    XCTAssertEqual(
      AudioCaptureEngine.trailExitReason(
        now: 0.5, entryTime: 0, quietStart: 0.1, graceSec: 0.25, minTrailSec: 0.06,
        maxTrailSec: 2.0, quietIsStale: true), "quiet_stale")
  }

  func testTrailExitReasonPrefersCapOverQuietWhenBothWouldBeSatisfied() {
    // Cap reached at the same instant quiet would also be satisfied: cap wins, matching
    // postRollWakeDelay's own check order (capRemaining is tested first).
    XCTAssertEqual(
      AudioCaptureEngine.trailExitReason(
        now: 2.0, entryTime: 0, quietStart: 0.1, graceSec: 0.25, minTrailSec: 0.06,
        maxTrailSec: 2.0, quietIsStale: false), "cap")
  }

  // MARK: - Migration

  func testMigrationAddsItemCColumns() throws {
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
      "finalize_exit", "finalize_drain_ms", "trail_wait_ms", "banked_quiet_ms", "quiet_resets",
      "trail_peak_db", "noise_floor_db",
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
    record.finalizeExit = "quiet_stale"
    record.finalizeDrainMs = 3.5
    record.trailWaitMs = 210.0
    record.bankedQuietMs = 80.0
    record.quietResets = 2
    record.trailPeakDb = -18.5
    record.noiseFloorDb = -62.0
    store.record(record)
    store.queue.sync {}

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let sql = """
      SELECT finalize_exit, finalize_drain_ms, trail_wait_ms, banked_quiet_ms, quiet_resets,
        trail_peak_db, noise_floor_db
      FROM transcriptions WHERE text = 'round trip'
      """
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 0)), "quiet_stale")
    XCTAssertEqual(sqlite3_column_double(statement, 1), 3.5, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 2), 210.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 3), 80.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_int(statement, 4), 2)
    XCTAssertEqual(sqlite3_column_double(statement, 5), -18.5, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 6), -62.0, accuracy: 0.001)
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
        "SELECT finalize_exit, quiet_resets, noise_floor_db FROM transcriptions WHERE text = 'bare'",
        -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_type(statement, 0), SQLITE_NULL)
    XCTAssertEqual(sqlite3_column_type(statement, 1), SQLITE_NULL)
    XCTAssertEqual(sqlite3_column_type(statement, 2), SQLITE_NULL)
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
