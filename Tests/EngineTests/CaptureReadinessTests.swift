// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3
import XCTest

@testable import TokEngine

/// Self-describing rows and key-down readiness. Covers EXPERIMENT_TAG parsing, the
/// additive migration, TurnRecord round-tripping the new columns through HistoryStore, and
/// the onset_db pure function.
final class CaptureReadinessTests: XCTestCase {

  // MARK: - EXPERIMENT_TAG

  func testExperimentTagIsTrimmed() {
    let config = EngineConfiguration.load(values: ["EXPERIMENT_TAG": "  night-run  "])
    XCTAssertEqual(config.experimentTag, "night-run")
  }

  func testExperimentTagEmptyBecomesNil() {
    XCTAssertNil(EngineConfiguration.load(values: ["EXPERIMENT_TAG": ""]).experimentTag)
    XCTAssertNil(EngineConfiguration.load(values: ["EXPERIMENT_TAG": "   "]).experimentTag)
    XCTAssertNil(EngineConfiguration.load(values: [:]).experimentTag)
  }

  func testExperimentTagIsCappedAt64Characters() {
    let long = String(repeating: "x", count: 100)
    let config = EngineConfiguration.load(values: ["EXPERIMENT_TAG": long])
    XCTAssertEqual(config.experimentTag?.count, 64)
    XCTAssertEqual(config.experimentTag, String(repeating: "x", count: 64))
  }

  func testExperimentTagIsHot() {
    XCTAssertEqual(SettingCatalog.all.first { $0.key == "EXPERIMENT_TAG" }?.restartsEngine, false)
  }

  // MARK: - onset_db (pure function)

  func testOnsetDbExcludesPreRollAndTakesMaxOfFirstFiveFrames() {
    // Two pre-roll frames, then five post-start frames: only the post-start frames count.
    let frames: [Double] = [-10, -10, -55, -20, -60, -15, -50, -90]
    XCTAssertEqual(
      AudioCaptureEngine.onsetDb(frames: frames, preRollFrameCount: 2), -15,
      "max of the five frames starting at index 2 (-55,-20,-60,-15,-50), ignoring the sixth")
  }

  func testOnsetDbUsesFewerFramesWhenClipIsShort() {
    let frames: [Double] = [-40, -40, -30]
    XCTAssertEqual(AudioCaptureEngine.onsetDb(frames: frames, preRollFrameCount: 1), -30)
  }

  func testOnsetDbIsNilWithNoPostPreRollFrames() {
    XCTAssertNil(AudioCaptureEngine.onsetDb(frames: [-40, -40], preRollFrameCount: 2))
    XCTAssertNil(AudioCaptureEngine.onsetDb(frames: [], preRollFrameCount: 0))
  }

  func testOnsetDbWithNoPreRoll() {
    XCTAssertEqual(AudioCaptureEngine.onsetDb(frames: [-30, -10, -50], preRollFrameCount: 0), -10)
  }

  // MARK: - Migration

  func testMigrationAddsItemABColumns() throws {
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
      "key_down_epoch", "key_up_epoch", "keep_mic_warm", "mic_idle_timeout_s", "pre_roll_ms",
      "post_roll_ms", "post_roll_max_ms", "trail_silence_db", "experiment_tag",
      "mic_state_at_keydown", "ms_since_prev_capture", "preroll_ms_used",
      "starting_notice_shown", "onset_db",
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
    config.keepMicrophoneWarm = true
    config.micIdleTimeoutSec = 120
    config.preRollMs = 350
    config.postRollMs = 200
    config.postRollMaxMs = 1200
    config.trailSilenceDb = -35.0
    let store = HistoryStore(config: config)
    defer { store.close() }

    var record = Self.turn("round trip")
    record.keyDownEpoch = 1_757_500_000.5
    record.keyUpEpoch = 1_757_500_001.25
    record.experimentTag = "ab-1"
    record.micStateAtKeydown = "warm"
    record.msSincePrevCapture = 4200.0
    record.prerollMsUsed = 300.0
    record.startingNoticeShown = true
    record.onsetDb = -22.5
    store.record(record)
    store.queue.sync {}

    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(config.historyDbPath, &db), SQLITE_OK)
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    let sql = """
      SELECT key_down_epoch, key_up_epoch, keep_mic_warm, mic_idle_timeout_s, pre_roll_ms,
        post_roll_ms, post_roll_max_ms, trail_silence_db, experiment_tag, mic_state_at_keydown,
        ms_since_prev_capture, preroll_ms_used, starting_notice_shown, onset_db
      FROM transcriptions WHERE text = 'round trip'
      """
    XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &statement, nil), SQLITE_OK)
    defer { sqlite3_finalize(statement) }
    XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
    XCTAssertEqual(sqlite3_column_double(statement, 0), 1_757_500_000.5, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 1), 1_757_500_001.25, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_int(statement, 2), 1)
    XCTAssertEqual(sqlite3_column_int(statement, 3), 120)
    XCTAssertEqual(sqlite3_column_int(statement, 4), 350)
    XCTAssertEqual(sqlite3_column_int(statement, 5), 200)
    XCTAssertEqual(sqlite3_column_int(statement, 6), 1200)
    XCTAssertEqual(sqlite3_column_double(statement, 7), -35.0, accuracy: 0.001)
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 8)), "ab-1")
    XCTAssertEqual(String(cString: sqlite3_column_text(statement, 9)), "warm")
    XCTAssertEqual(sqlite3_column_double(statement, 10), 4200.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_double(statement, 11), 300.0, accuracy: 0.001)
    XCTAssertEqual(sqlite3_column_int(statement, 12), 1)
    XCTAssertEqual(sqlite3_column_double(statement, 13), -22.5, accuracy: 0.001)
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
        "SELECT experiment_tag, onset_db, starting_notice_shown FROM transcriptions WHERE text = 'bare'",
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
