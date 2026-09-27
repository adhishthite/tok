// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class HistoryStore {
  private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  let queue = DispatchQueue(label: "com.adhishthite.tok.history", qos: .utility)
  var db: OpaquePointer?
  // Latched only by open and schema failures, and only after a second attempt. A single bad
  // insert must never silence history for the rest of the session.
  var failed = false
  private var openFailures = 0
  private var reportedError = false
  /// Called on `queue` with a short human message when a row is finally lost, and with nil
  /// after the next successful write. Set it before the first record().
  var onError: ((String?) -> Void)?
  private static let busyMessage =
    "History could not be saved. The database is busy or unavailable."
  private let dbPath: String
  private let sessionId = UUID().uuidString
  private static let isoFormatter = ISO8601DateFormatter()

  // A/B knob values, constant per process, stamped onto every row so experiment eras are
  // separable by config rather than by timestamp archaeology; buildId adds the git commit
  // for slicing bug reports by exactly which code produced a row.
  let endpointAligned: Bool
  let chunkMs: Int
  let silenceFlushMs: Int
  private let buildId: String?
  // Effective capture-timing knobs for this engine instance, stamped on every row
  // the same way endpointAligned/chunkMs/silenceFlushMs are: constant per process, so
  // measurements can be sliced by exactly which config produced them without restarting.
  let keepMicWarm: Bool
  let micIdleTimeoutSec: Int
  let preRollMs: Int
  let postRollMs: Int
  let postRollMaxMs: Int
  let trailSilenceDb: Double

  var path: String { dbPath }

  static func resolvedPath(_ config: EngineConfiguration) -> String {
    let rawPath =
      config.historyDbPath.isEmpty
      ? "~/Library/Application Support/Tok/history.db" : config.historyDbPath
    return (rawPath as NSString).expandingTildeInPath
  }

  init(config: EngineConfiguration) {
    self.dbPath = Self.resolvedPath(config)
    self.endpointAligned = config.wsEndpointAligned
    self.chunkMs = config.chunkMs
    self.silenceFlushMs = config.silenceFlushMs
    self.buildId = config.buildId.isEmpty ? nil : config.buildId
    self.keepMicWarm = config.keepMicrophoneWarm
    self.micIdleTimeoutSec = config.micIdleTimeoutSec
    self.preRollMs = config.preRollMs
    self.postRollMs = config.postRollMs
    self.postRollMaxMs = config.postRollMaxMs
    self.trailSilenceDb = config.trailSilenceDb
  }

  // Called on-queue from record(). No-ops once already open or once opening has failed.
  private func openIfNeeded() {
    guard db == nil, !failed else { return }

    let dir = (dbPath as NSString).deletingLastPathComponent
    do {
      try FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    } catch {
      markOpenFailure("Failed to create history directory \(dir): \(error.localizedDescription)")
      return
    }

    var handle: OpaquePointer?
    let openResult = sqlite3_open_v2(
      dbPath, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
    guard openResult == SQLITE_OK, let opened = handle else {
      let msg =
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite3_open_v2 error"
      markOpenFailure("Failed to open history DB at \(dbPath): \(msg)")
      if let handle = handle { sqlite3_close(handle) }
      return
    }
    chmod(dbPath, 0o600)

    if sqlite3_exec(opened, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=2000;", nil, nil, nil)
      != SQLITE_OK
    {
      markOpenFailure(
        "Failed to set history DB pragmas: \(String(cString: sqlite3_errmsg(opened)))")
      sqlite3_close(opened)
      return
    }

    let schema = """
      CREATE TABLE IF NOT EXISTS transcriptions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_utc TEXT NOT NULL,
        ts_epoch REAL NOT NULL,
        session_id TEXT NOT NULL,
        outcome TEXT NOT NULL,
        text TEXT,
        char_count INTEGER NOT NULL DEFAULT 0,
        word_count INTEGER NOT NULL DEFAULT 0,
        transport TEXT,
        model TEXT,
        is_live_route INTEGER,
        fallback_reason TEXT,
        audio_seconds REAL,
        first_token_ms REAL,
        roundtrip_ms REAL,
        capture_finalize_ms REAL,
        inject_ms REAL,
        total_ms REAL,
        injected INTEGER,
        input_tokens INTEGER,
        output_tokens INTEGER,
        tokens_metered INTEGER,
        cost_usd REAL,
        language_codes TEXT,
        smart_mode INTEGER,
        vad_mode TEXT,
        error TEXT,
        app_bundle_id TEXT,
        app_name TEXT,
        peak_db REAL,
        speech_frames INTEGER,
        settle_path TEXT,
        endpoint_aligned INTEGER,
        chunk_ms INTEGER,
        silence_flush_ms INTEGER,
        build_id TEXT,
        input_device TEXT,
        input_transport TEXT,
        finish_mode TEXT,
        event_queue_ms REAL,
        ready_ms REAL,
        delivery_outcome TEXT,
        capture_start_ms REAL,
        first_interim_ms REAL,
        key_down_epoch REAL,
        key_up_epoch REAL,
        keep_mic_warm INTEGER,
        mic_idle_timeout_s INTEGER,
        pre_roll_ms INTEGER,
        post_roll_ms INTEGER,
        post_roll_max_ms INTEGER,
        trail_silence_db REAL,
        experiment_tag TEXT,
        mic_state_at_keydown TEXT,
        ms_since_prev_capture REAL,
        preroll_ms_used REAL,
        starting_notice_shown INTEGER,
        onset_db REAL,
        finalize_exit TEXT,
        finalize_drain_ms REAL,
        trail_wait_ms REAL,
        banked_quiet_ms REAL,
        quiet_resets INTEGER,
        trail_peak_db REAL,
        noise_floor_db REAL,
        socket_state_at_keydown TEXT,
        socket_age_ms REAL,
        reconnected_during_turn INTEGER,
        hedge_fired INTEGER,
        hedge_winner TEXT,
        commit_to_last_send_ms REAL,
        commit_to_first_msg_ms REAL,
        commit_to_final_ms REAL,
        commit_to_turn_complete_ms REAL,
        quiet_threshold_db REAL
      );
      CREATE INDEX IF NOT EXISTS idx_transcriptions_ts ON transcriptions(ts_epoch);
      CREATE INDEX IF NOT EXISTS idx_transcriptions_session ON transcriptions(session_id);
      CREATE TABLE IF NOT EXISTS connection_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_epoch REAL NOT NULL,
        kind TEXT NOT NULL,
        turn_open INTEGER,
        socket_age_s REAL,
        build_id TEXT
      );
      -- Never shown in UI; a diagnostics-only lifecycle trace for the Live socket
      -- (connect/reconnect/rotate/wake, lost, closed). Included in retention pruning and
      -- the delete-all-history path alongside transcriptions/corrections.
      CREATE INDEX IF NOT EXISTS idx_connection_events_ts ON connection_events(ts_epoch);
      CREATE TABLE IF NOT EXISTS corrections (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        ts_utc TEXT NOT NULL,
        ts_epoch REAL NOT NULL,
        session_id TEXT NOT NULL,
        wrong_text TEXT NOT NULL,
        right_text TEXT NOT NULL,
        app_name TEXT,
        source TEXT NOT NULL DEFAULT 'ax_readback',
        build_id TEXT
      );
      CREATE INDEX IF NOT EXISTS idx_corrections_ts ON corrections(ts_epoch);
      """
    if sqlite3_exec(opened, schema, nil, nil, nil) != SQLITE_OK {
      markOpenFailure(
        "Failed to create history schema: \(String(cString: sqlite3_errmsg(opened)))")
      sqlite3_close(opened)
      return
    }

    // Columns added after the table first shipped. CREATE TABLE IF NOT EXISTS won't touch
    // an existing DB, so each new column is a best-effort ALTER whose "duplicate column"
    // failure on an already-migrated DB is expected and deliberately ignored.
    for migration in [
      "ALTER TABLE transcriptions ADD COLUMN app_bundle_id TEXT",
      "ALTER TABLE transcriptions ADD COLUMN app_name TEXT",
      "ALTER TABLE transcriptions ADD COLUMN peak_db REAL",
      "ALTER TABLE transcriptions ADD COLUMN speech_frames INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN settle_path TEXT",
      "ALTER TABLE transcriptions ADD COLUMN endpoint_aligned INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN chunk_ms INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN silence_flush_ms INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN build_id TEXT",
      "ALTER TABLE corrections ADD COLUMN build_id TEXT",
      "ALTER TABLE transcriptions ADD COLUMN input_device TEXT",
      "ALTER TABLE transcriptions ADD COLUMN input_transport TEXT",
      "ALTER TABLE transcriptions ADD COLUMN finish_mode TEXT",
      "ALTER TABLE transcriptions ADD COLUMN event_queue_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN ready_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN delivery_outcome TEXT",
      "ALTER TABLE transcriptions ADD COLUMN capture_start_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN first_interim_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN key_down_epoch REAL",
      "ALTER TABLE transcriptions ADD COLUMN key_up_epoch REAL",
      "ALTER TABLE transcriptions ADD COLUMN keep_mic_warm INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN mic_idle_timeout_s INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN pre_roll_ms INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN post_roll_ms INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN post_roll_max_ms INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN trail_silence_db REAL",
      "ALTER TABLE transcriptions ADD COLUMN experiment_tag TEXT",
      "ALTER TABLE transcriptions ADD COLUMN mic_state_at_keydown TEXT",
      "ALTER TABLE transcriptions ADD COLUMN ms_since_prev_capture REAL",
      "ALTER TABLE transcriptions ADD COLUMN preroll_ms_used REAL",
      "ALTER TABLE transcriptions ADD COLUMN starting_notice_shown INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN onset_db REAL",
      "ALTER TABLE transcriptions ADD COLUMN finalize_exit TEXT",
      "ALTER TABLE transcriptions ADD COLUMN finalize_drain_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN trail_wait_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN banked_quiet_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN quiet_resets INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN trail_peak_db REAL",
      "ALTER TABLE transcriptions ADD COLUMN noise_floor_db REAL",
      "ALTER TABLE transcriptions ADD COLUMN socket_state_at_keydown TEXT",
      "ALTER TABLE transcriptions ADD COLUMN socket_age_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN reconnected_during_turn INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN hedge_fired INTEGER",
      "ALTER TABLE transcriptions ADD COLUMN hedge_winner TEXT",
      "ALTER TABLE transcriptions ADD COLUMN commit_to_last_send_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN commit_to_first_msg_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN commit_to_final_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN commit_to_turn_complete_ms REAL",
      "ALTER TABLE transcriptions ADD COLUMN quiet_threshold_db REAL",
    ] {
      sqlite3_exec(opened, migration, nil, nil, nil)
    }

    HistoryRetiredColumns.remove(from: opened)

    do { try HistoryPostProcessingSchema.migrate(opened) } catch {
      markOpenFailure("Could not prepare cleanup metrics in history.")
      sqlite3_close(opened)
      return
    }
    db = opened
  }

  // Open and schema failures still latch, but the next record() gets one more attempt: a
  // directory or file that was unavailable at launch is often available a moment later.
  private func markOpenFailure(_ message: String) {
    openFailures += 1
    failed = openFailures > 1
    Log.warn("HISTORY", message)
  }

  // SQLITE_BUSY and SQLITE_LOCKED mean another connection holds the write lock, which is
  // transient: retry the row on this queue before giving up on it alone. Runs after the
  // connection's own 2 s busy timeout has already expired, so the backoff is short.
  private func withInsertRetry(_ attempt: () -> Int32) -> Bool {
    let backoffMicroseconds: [UInt32] = [50_000, 200_000]
    for index in 0...backoffMicroseconds.count {
      let code = attempt()
      if code == SQLITE_DONE { return true }
      guard code == SQLITE_BUSY || code == SQLITE_LOCKED, index < backoffMicroseconds.count else {
        return false
      }
      usleep(backoffMicroseconds[index])
    }
    return false
  }

  // Only transitions are reported, so a healthy session stays silent and a broken one
  // reports once.
  private func report(success: Bool) {
    if success {
      guard reportedError else { return }
      reportedError = false
      onError?(nil)
    } else {
      guard !reportedError else { return }
      reportedError = true
      onError?(Self.busyMessage)
    }
  }

  private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
    if let value = value {
      sqlite3_bind_text(stmt, idx, value, -1, Self.sqliteTransient)
    } else {
      sqlite3_bind_null(stmt, idx)
    }
  }

  private func bindDouble(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
    if let value = value {
      sqlite3_bind_double(stmt, idx, value)
    } else {
      sqlite3_bind_null(stmt, idx)
    }
  }

  private func bindInt(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
    if let value = value {
      sqlite3_bind_int64(stmt, idx, Int64(value))
    } else {
      sqlite3_bind_null(stmt, idx)
    }
  }

  private func bindBool(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Bool?) {
    if let value = value {
      sqlite3_bind_int(stmt, idx, value ? 1 : 0)
    } else {
      sqlite3_bind_null(stmt, idx)
    }
  }

  func record(_ r: TurnRecord) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.openIfNeeded()
      guard let db = self.db else {
        self.report(success: false)
        return
      }
      let ok = self.withInsertRetry { self.insertTranscription(db, r) }
      self.report(success: ok)
    }
  }

  // Returns the sqlite result code of the step (or of a failed prepare) so the caller can
  // decide whether the failure is worth retrying.
  private func insertTranscription(_ db: OpaquePointer, _ r: TurnRecord) -> Int32 {
    let sql = """
      INSERT INTO transcriptions (
        ts_utc, ts_epoch, session_id, outcome, text, char_count, word_count,
        transport, model, is_live_route, fallback_reason, audio_seconds,
        first_token_ms, roundtrip_ms, capture_finalize_ms, inject_ms, total_ms,
        injected, input_tokens, output_tokens, tokens_metered, cost_usd,
        language_codes, smart_mode, vad_mode, error, app_bundle_id, app_name,
        peak_db, speech_frames, settle_path, endpoint_aligned, chunk_ms, silence_flush_ms,
        build_id, input_device, input_transport, finish_mode, event_queue_ms, ready_ms, delivery_outcome,
        post_process_status, post_process_model, post_process_ms, post_process_input_tokens,
        post_process_output_tokens, post_process_thinking_tokens, post_process_cost_usd,
        post_process_error, post_process_app_context, transcription_cost_usd,
        capture_start_ms, first_interim_ms,
        key_down_epoch, key_up_epoch, keep_mic_warm, mic_idle_timeout_s, pre_roll_ms,
        post_roll_ms, post_roll_max_ms, trail_silence_db, experiment_tag, mic_state_at_keydown,
        ms_since_prev_capture, preroll_ms_used, starting_notice_shown, onset_db,
        finalize_exit, finalize_drain_ms, trail_wait_ms, banked_quiet_ms, quiet_resets,
        trail_peak_db, noise_floor_db,
        socket_state_at_keydown, socket_age_ms, reconnected_during_turn, hedge_fired,
        hedge_winner, commit_to_last_send_ms, commit_to_first_msg_ms, commit_to_final_ms,
        commit_to_turn_complete_ms, quiet_threshold_db
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """

    var stmt: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepared == SQLITE_OK else {
      Log.warn(
        "HISTORY", "Failed to prepare history insert: \(String(cString: sqlite3_errmsg(db)))")
      sqlite3_finalize(stmt)
      return prepared
    }

    let now = Date()
    self.bindText(stmt, 1, HistoryStore.isoFormatter.string(from: now))
    self.bindDouble(stmt, 2, now.timeIntervalSince1970)
    self.bindText(stmt, 3, self.sessionId)
    self.bindText(stmt, 4, r.outcome)
    self.bindText(stmt, 5, r.text)
    self.bindInt(stmt, 6, r.charCount)
    self.bindInt(stmt, 7, r.wordCount)
    self.bindText(stmt, 8, r.transport)
    self.bindText(stmt, 9, r.model)
    self.bindBool(stmt, 10, r.isLiveRoute)
    self.bindText(stmt, 11, r.fallbackReason)
    self.bindDouble(stmt, 12, r.audioSeconds)
    self.bindDouble(stmt, 13, r.firstTokenMs)
    self.bindDouble(stmt, 14, r.roundtripMs)
    self.bindDouble(stmt, 15, r.captureFinalizeMs)
    self.bindDouble(stmt, 16, r.injectMs)
    self.bindDouble(stmt, 17, r.totalMs)
    self.bindBool(stmt, 18, r.injected)
    self.bindInt(stmt, 19, r.inputTokens)
    self.bindInt(stmt, 20, r.outputTokens)
    self.bindBool(stmt, 21, r.tokensMetered)
    self.bindDouble(stmt, 22, r.costUSD)
    self.bindText(stmt, 23, r.languageCodes)
    self.bindBool(stmt, 24, r.smartMode)
    self.bindText(stmt, 25, r.vadMode)
    self.bindText(stmt, 26, r.error)
    self.bindText(stmt, 27, r.appBundleId)
    self.bindText(stmt, 28, r.appName)
    self.bindDouble(stmt, 29, r.peakDb)
    self.bindInt(stmt, 30, r.speechFrames)
    self.bindText(stmt, 31, r.settlePath)
    self.bindBool(stmt, 32, self.endpointAligned)
    self.bindInt(stmt, 33, self.chunkMs)
    self.bindInt(stmt, 34, self.silenceFlushMs)
    self.bindText(stmt, 35, self.buildId)
    self.bindText(stmt, 36, r.inputDevice)
    self.bindText(stmt, 37, r.inputTransport)
    self.bindText(stmt, 38, r.finishMode)
    self.bindDouble(stmt, 39, r.eventQueueMs)
    self.bindDouble(stmt, 40, r.readyMs)
    self.bindText(stmt, 41, r.deliveryOutcome)
    self.bindText(stmt, 42, r.postProcessing?.status)
    self.bindText(stmt, 43, r.postProcessing?.model)
    self.bindDouble(stmt, 44, r.postProcessing?.latencyMs)
    self.bindInt(stmt, 45, r.postProcessing?.inputTokens)
    self.bindInt(stmt, 46, r.postProcessing?.outputTokens)
    self.bindInt(stmt, 47, r.postProcessing?.thinkingTokens)
    self.bindDouble(stmt, 48, r.postProcessing?.costUSD)
    self.bindText(stmt, 49, r.postProcessing?.errorCode)
    self.bindBool(stmt, 50, r.postProcessing?.appContextUsed)
    self.bindDouble(stmt, 51, r.transcriptionCostUSD)
    self.bindDouble(stmt, 52, r.captureStartMs)
    self.bindDouble(stmt, 53, r.firstInterimMs)
    self.bindDouble(stmt, 54, r.keyDownEpoch)
    self.bindDouble(stmt, 55, r.keyUpEpoch)
    self.bindBool(stmt, 56, self.keepMicWarm)
    self.bindInt(stmt, 57, self.micIdleTimeoutSec)
    self.bindInt(stmt, 58, self.preRollMs)
    self.bindInt(stmt, 59, self.postRollMs)
    self.bindInt(stmt, 60, self.postRollMaxMs)
    self.bindDouble(stmt, 61, self.trailSilenceDb)
    self.bindText(stmt, 62, r.experimentTag)
    self.bindText(stmt, 63, r.micStateAtKeydown)
    self.bindDouble(stmt, 64, r.msSincePrevCapture)
    self.bindDouble(stmt, 65, r.prerollMsUsed)
    self.bindBool(stmt, 66, r.startingNoticeShown)
    self.bindDouble(stmt, 67, r.onsetDb)
    self.bindText(stmt, 68, r.finalizeExit)
    self.bindDouble(stmt, 69, r.finalizeDrainMs)
    self.bindDouble(stmt, 70, r.trailWaitMs)
    self.bindDouble(stmt, 71, r.bankedQuietMs)
    self.bindInt(stmt, 72, r.quietResets)
    self.bindDouble(stmt, 73, r.trailPeakDb)
    self.bindDouble(stmt, 74, r.noiseFloorDb)
    self.bindText(stmt, 75, r.socketStateAtKeydown)
    self.bindDouble(stmt, 76, r.socketAgeMs)
    self.bindBool(stmt, 77, r.reconnectedDuringTurn)
    self.bindBool(stmt, 78, r.hedgeFired)
    self.bindText(stmt, 79, r.hedgeWinner)
    self.bindDouble(stmt, 80, r.commitToLastSendMs)
    self.bindDouble(stmt, 81, r.commitToFirstMsgMs)
    self.bindDouble(stmt, 82, r.commitToFinalMs)
    self.bindDouble(stmt, 83, r.commitToTurnCompleteMs)
    self.bindDouble(stmt, 84, r.quietThresholdDb)

    let stepped = sqlite3_step(stmt)
    if stepped != SQLITE_DONE {
      Log.warn("HISTORY", "Failed to insert history row: \(String(cString: sqlite3_errmsg(db)))")
    }
    sqlite3_finalize(stmt)
    return stepped
  }

  // Typed-correction observation from CorrectionWatcher: only the changed word pair is
  // stored, never the surrounding field content. Fire-and-forget like record().
  func recordCorrection(wrong: String, right: String, appName: String) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.openIfNeeded()
      guard let db = self.db else { return }
      // Corrections share the row-level retry but never raise onError: they are a learning
      // signal, not the user's transcript.
      _ = self.withInsertRetry {
        self.insertCorrection(db, wrong: wrong, right: right, appName: appName)
      }
    }
  }

  private func insertCorrection(
    _ db: OpaquePointer, wrong: String, right: String, appName: String
  ) -> Int32 {
    let sql = """
      INSERT INTO corrections (ts_utc, ts_epoch, session_id, wrong_text, right_text, app_name, build_id)
      VALUES (?, ?, ?, ?, ?, ?, ?)
      """
    var stmt: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepared == SQLITE_OK else {
      Log.warn(
        "HISTORY", "Failed to prepare correction insert: \(String(cString: sqlite3_errmsg(db)))")
      sqlite3_finalize(stmt)
      return prepared
    }
    let now = Date()
    bindText(stmt, 1, HistoryStore.isoFormatter.string(from: now))
    bindDouble(stmt, 2, now.timeIntervalSince1970)
    bindText(stmt, 3, sessionId)
    bindText(stmt, 4, wrong)
    bindText(stmt, 5, right)
    bindText(stmt, 6, appName.isEmpty ? nil : appName)
    bindText(stmt, 7, buildId)
    let stepped = sqlite3_step(stmt)
    if stepped != SQLITE_DONE {
      Log.warn(
        "HISTORY", "Failed to insert correction row: \(String(cString: sqlite3_errmsg(db)))")
    }
    sqlite3_finalize(stmt)
    return stepped
  }

  // Connection lifecycle telemetry: never shown in UI, so it never raises onError
  // and never touches PRIVACY_MODE (transcriptions do not gate on it either; there is no
  // transcript text or app/device name in a connection_events row to begin with).
  // Fire-and-forget on the history queue, exactly like record(): the caller (GeminiLiveClient,
  // through DictationEngine's callback) may be running on main or a client-internal queue,
  // and must never block waiting for this write.
  func recordConnectionEvent(kind: String, turnOpen: Bool, socketAgeS: Double?) {
    queue.async { [weak self] in
      guard let self = self else { return }
      self.openIfNeeded()
      guard let db = self.db else { return }
      _ = self.withInsertRetry {
        self.insertConnectionEvent(db, kind: kind, turnOpen: turnOpen, socketAgeS: socketAgeS)
      }
    }
  }

  private func insertConnectionEvent(
    _ db: OpaquePointer, kind: String, turnOpen: Bool, socketAgeS: Double?
  ) -> Int32 {
    let sql = """
      INSERT INTO connection_events (ts_epoch, kind, turn_open, socket_age_s, build_id)
      VALUES (?, ?, ?, ?, ?)
      """
    var stmt: OpaquePointer?
    let prepared = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
    guard prepared == SQLITE_OK else {
      Log.warn(
        "HISTORY",
        "Failed to prepare connection event insert: \(String(cString: sqlite3_errmsg(db)))")
      sqlite3_finalize(stmt)
      return prepared
    }
    bindDouble(stmt, 1, Date().timeIntervalSince1970)
    bindText(stmt, 2, kind)
    bindBool(stmt, 3, turnOpen)
    bindDouble(stmt, 4, socketAgeS)
    bindText(stmt, 5, buildId)
    let stepped = sqlite3_step(stmt)
    if stepped != SQLITE_DONE {
      Log.warn(
        "HISTORY", "Failed to insert connection event: \(String(cString: sqlite3_errmsg(db)))")
    }
    sqlite3_finalize(stmt)
    return stepped
  }

  func close() {
    queue.sync {
      guard let db = self.db else { return }
      sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
      sqlite3_close(db)
      self.db = nil
    }
  }
}
