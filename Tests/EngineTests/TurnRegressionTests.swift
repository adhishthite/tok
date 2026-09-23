import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3
import XCTest

@testable import TokEngine

final class TurnRegressionTests: XCTestCase {
  func testReferenceFixtures() throws {

    let toggleFixture = HotkeyManager(binding: .fKey(0x69), mode: "toggle")
    var starts = 0
    var stops = 0
    toggleFixture.onKeyDown = { starts += 1 }
    toggleFixture.onKeyUp = { stops += 1 }
    toggleFixture.fixturePress(true)
    toggleFixture.fixturePress(true)
    check(starts == 1 && stops == 0, "toggle ignores held-key repeats")
    toggleFixture.resetToggle()
    toggleFixture.fixturePress(false)
    toggleFixture.fixturePress(true)
    check(starts == 2 && stops == 0, "toggle starts immediately after external interruption")
    toggleFixture.fixturePress(false)
    toggleFixture.fixturePress(true)
    check(stops == 1, "toggle still finishes on next physical press")

    AudioCaptureEngine().fixtureConversionFailure()
    let historyFixtureURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString + ".db")
    var appFixtureConfig = EngineConfiguration()
    appFixtureConfig.showHUD = false
    appFixtureConfig.soundFeedback = false
    appFixtureConfig.enableLiveWebSocket = false
    appFixtureConfig.learnCorrections = false
    appFixtureConfig.postRollMs = 0
    appFixtureConfig.micIdleTimeoutSec = 0
    appFixtureConfig.historyEnabled = true
    appFixtureConfig.historyDbPath = historyFixtureURL.path
    let interruptedApp = DictationEngine(config: appFixtureConfig)
    interruptedApp.fixtureInterruptedTurn()
    var fixtureDB: OpaquePointer?
    check(
      sqlite3_open_v2(historyFixtureURL.path, &fixtureDB, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      "history fixture readable")
    var fixtureStatement: OpaquePointer?
    let fixtureSQL =
      "SELECT COUNT(*) FROM transcriptions WHERE transport='microphone' AND outcome='error' AND text IS NULL AND total_ms >= 0 AND capture_finalize_ms >= 0 AND event_queue_ms = 0"
    check(
      sqlite3_prepare_v2(fixtureDB, fixtureSQL, -1, &fixtureStatement, nil) == SQLITE_OK,
      "history metrics schema and insert align")
    check(
      sqlite3_step(fixtureStatement) == SQLITE_ROW && sqlite3_column_int(fixtureStatement, 0) == 1,
      "interrupted history keeps timing and never claims delivered text")
    sqlite3_finalize(fixtureStatement)
    sqlite3_close(fixtureDB)
    try? FileManager.default.removeItem(at: historyFixtureURL)

    // An immediate dispatcher models main winning the race against the pipeline worker.

    var rejectedConfig = appFixtureConfig
    rejectedConfig.historyEnabled = false
    rejectedConfig.micIdleTimeoutSec = 300
    rejectedConfig.keepMicrophoneWarm = true
    DictationEngine(config: rejectedConfig).fixtureRejectedTurn(silent: false)
    DictationEngine(config: rejectedConfig).fixtureRejectedTurn(silent: true)

    // audit F21: the REST-failure decision, and the turn arbiter that applies it.
    check(
      DictationEngine.shouldSettleOnRestFailure(wsViable: false),
      "REST failure ends the turn when the live route cannot answer")
    check(
      !DictationEngine.shouldSettleOnRestFailure(wsViable: true),
      "REST failure defers to a live route that can still answer")
    var hedgeConfig = appFixtureConfig
    hedgeConfig.historyEnabled = false
    hedgeConfig.micIdleTimeoutSec = 0
    hedgeConfig.enableLiveWebSocket = true
    hedgeConfig.geminiApiKey = "fixture-key"
    DictationEngine(config: hedgeConfig).fixtureRestHedgeFailure(expectSettle: false)
    var restOnlyConfig = hedgeConfig
    restOnlyConfig.enableLiveWebSocket = false
    DictationEngine(config: restOnlyConfig).fixtureRestHedgeFailure(expectSettle: true)

    // audit F11: a cancelled turn is settled without a paste, and the next turn is clean.
    let cancelRecorder = EngineEventRecorder()
    let cancelEngine = DictationEngine(config: hedgeConfig)
    cancelEngine.delegate = cancelRecorder
    cancelEngine.fixtureCancelledTurn(recorder: cancelRecorder)

    // hedge_fired and hedge_winner, stamped in settle() from sessionQueue-only state.
    let noHedgeRecorder = EngineEventRecorder()
    let noHedgeEngine = DictationEngine(config: restOnlyConfig)
    noHedgeEngine.delegate = noHedgeRecorder
    noHedgeEngine.fixtureHedgeStamping(recorder: noHedgeRecorder, hedgeFired: false, route: "REST")

    let restWinsRecorder = EngineEventRecorder()
    let restWinsEngine = DictationEngine(config: restOnlyConfig)
    restWinsEngine.delegate = restWinsRecorder
    restWinsEngine.fixtureHedgeStamping(recorder: restWinsRecorder, hedgeFired: true, route: "REST")

    let wsWinsRecorder = EngineEventRecorder()
    let wsWinsEngine = DictationEngine(config: restOnlyConfig)
    wsWinsEngine.delegate = wsWinsRecorder
    wsWinsEngine.fixtureHedgeStamping(recorder: wsWinsRecorder, hedgeFired: true, route: "WS")
  }
}
