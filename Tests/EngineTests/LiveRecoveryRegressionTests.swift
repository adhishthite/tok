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

final class LiveRecoveryRegressionTests: XCTestCase {
  func testReferenceFixtures() throws {
    // Transport callbacks are controlled without opening a network connection.

    let startupProbe = LiveWriteProbe()
    let startupClient = GeminiLiveClient(apiKey: "")
    startupClient.recoveryFixture(startupProbe)
    startupClient.startNewTurn()
    startupClient.sendAudioChunk(Data([1, 2]))
    startupClient.sendAudioChunk(Data([3, 4]))
    startupClient.recoveryDrain()
    check(startupProbe.sent.isEmpty, "startup audio waits for setup")
    check(
      startupClient.recoveryPending == 3 && !startupClient.recoveryGap,
      "entire startup prefix retained")
    startupClient.recoveryConnectionFailure()
    check(
      !startupClient.recoveryGap && startupClient.recoveryPending == 3,
      "unsent prefix survives setup failure")
    startupClient.recoveryReady()
    check(
      startupProbe.sent.count == 1 && startupProbe.sent[0].contains("activityStart"),
      "activity start precedes replay")
    startupProbe.finish(0)
    startupClient.recoveryDrain()
    check(
      startupProbe.sent.count == 2 && startupProbe.sent[1].contains("AQI="),
      "first startup audio ordered")
    startupProbe.finish(1)
    startupClient.recoveryDrain()
    check(
      startupProbe.sent.count == 3 && startupProbe.sent[2].contains("AwQ="),
      "second startup audio ordered")
    var recoveryCommitResults = 0
    startupClient.commitTurn { _ in recoveryCommitResults += 1 }
    startupClient.recoveryDrain()
    check(startupProbe.sent.count == 3, "commit waits for final audio send completion")
    startupProbe.finish(2)
    startupClient.recoveryDrain()
    check(
      startupProbe.sent.count == 4 && startupProbe.sent[3].contains("audioStreamEnd"),
      "commit begins after replay")
    startupClient.disconnect()
    check(
      recoveryCommitResults == 1 && startupClient.recoveryPending == 0,
      "disconnect settles once and releases writes")
    startupProbe.finish(3)
    startupClient.recoveryDrain()
    check(recoveryCommitResults == 1, "late write callback cannot settle twice")

    let boundedClient = GeminiLiveClient(apiKey: "")
    boundedClient.startNewTurn()
    boundedClient.recoverySend(String(repeating: "x", count: 256 * 1024))
    check(
      boundedClient.recoveryGap && boundedClient.recoveryPending == 0,
      "overflow rejects incomplete Live turn")
    boundedClient.startNewTurn()
    check(
      !boundedClient.recoveryGap && boundedClient.recoveryPending == 1,
      "next turn clears failed backlog")
    boundedClient.recoveryExpire()
    check(
      boundedClient.recoveryGap && boundedClient.recoveryPending == 0,
      "startup timeout releases backlog")
    boundedClient.abandonTurn()

    let failureProbe = LiveWriteProbe()
    let failureClient = GeminiLiveClient(apiKey: "")
    failureClient.recoveryFixture(failureProbe)
    failureClient.startNewTurn()
    failureClient.recoveryReady()
    failureClient.sendAudioChunk(Data([8]))
    failureClient.recoveryDrain()
    let pendingCommitFinished = DispatchSemaphore(value: 0)
    var pendingCommitCount = 0
    failureClient.commitTurn { result in
      if case .success = result { XCTFail("incomplete stream succeeded") }
      pendingCommitCount += 1
      pendingCommitFinished.signal()
    }
    failureProbe.finish(0, error: NSError(domain: "fixture", code: 1))
    failureClient.recoveryDrain()
    check(
      pendingCommitFinished.wait(timeout: .now() + 1) == .success && pendingCommitCount == 1,
      "pending commit fails once on send error")
    check(
      failureClient.recoveryGap && failureClient.recoveryPending == 0,
      "transport failure invalidates whole stream")
    failureClient.startNewTurn()
    failureProbe.finish(0)
    failureClient.recoveryDrain()
    check(
      !failureClient.recoveryGap && failureClient.recoveryPending == 1,
      "stale callback cannot consume next turn")
    failureClient.disconnect()

    let endingProbe = LiveWriteProbe()
    let endingClient = GeminiLiveClient(apiKey: "")
    endingClient.recoveryFixture(endingProbe)
    endingClient.startNewTurn()
    endingClient.recoveryReady()
    endingProbe.finish(0)
    endingClient.recoveryDrain()
    endingClient.fixtureMessage(["inputTranscription": ["text": "Complete words."]])
    var endingResults = 0
    var endingText = ""
    endingClient.commitTurn { result in
      endingResults += 1
      if case .success(let value) = result { endingText = value.text }
    }
    endingClient.recoveryDrain()
    endingClient.recoveryForceSettleAge()
    check(
      endingResults == 0 && endingClient.recoveryPending == 3,
      "timer cannot settle while terminators are pending")
    endingClient.fixtureMessage(["turnComplete": true])
    check(
      endingResults == 0 && endingClient.recoveryPending == 3,
      "server completion waits for terminators without dropping them")
    endingProbe.finish(1)
    endingClient.recoveryDrain()
    endingProbe.finish(2)
    endingClient.recoveryDrain()
    check(endingResults == 0, "partial terminator completion cannot settle")
    endingProbe.finish(3)
    endingClient.recoveryDrain()
    check(
      endingResults == 1 && endingText == "Complete words.",
      "early server completion retained until all terminators finish")
    endingProbe.finish(3)
    endingClient.recoveryDrain()
    check(endingResults == 1, "duplicate terminal callback cannot settle twice")
    endingClient.disconnect()

    let expiredEndProbe = LiveWriteProbe()
    let expiredEndClient = GeminiLiveClient(apiKey: "")
    expiredEndClient.recoveryFixture(expiredEndProbe)
    expiredEndClient.startNewTurn()
    expiredEndClient.recoveryReady()
    expiredEndProbe.finish(0)
    expiredEndClient.recoveryDrain()
    expiredEndClient.fixtureMessage([
      "inputTranscription": ["text": "Never paste this partial turn."]
    ])
    var expiredEndResults = 0
    expiredEndClient.commitTurn { result in
      if case .success = result { XCTFail("expired terminator succeeded") }
      expiredEndResults += 1
    }
    expiredEndClient.recoveryDrain()
    expiredEndClient.fixtureMessage(["turnComplete": true])
    expiredEndClient.recoveryExpire()
    check(
      expiredEndResults == 1 && expiredEndClient.recoveryGap,
      "expired terminator fails even after early server completion")
    expiredEndProbe.finish(1)
    expiredEndClient.recoveryDrain()
    check(expiredEndResults == 1, "expired terminator late callback does not settle twice")
    expiredEndClient.disconnect()

  }
}
