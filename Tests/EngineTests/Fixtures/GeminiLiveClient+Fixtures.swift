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

extension GeminiLiveClient {
  func recoveryFixture(_ probe: LiveWriteProbe) {
    webSocketTask = urlSession.webSocketTask(with: URL(string: "wss://example.invalid")!)
    writeTransport = { _, text, completion in probe.accept(text, completion) }
  }
  func recoveryReady() {
    let data = try! JSONSerialization.data(withJSONObject: ["setupComplete": [:]])
    handleIncomingMessage(.data(data), epoch: connectionID)
    recoveryDrain()
  }
  func recoveryDrain() {
    sendQueue.sync {}
    sendQueue.sync {}
  }
  var recoveryPending: Int {
    lock.lock()
    defer { lock.unlock() }
    return pendingWrites.count
  }
  var recoveryGap: Bool {
    lock.lock()
    defer { lock.unlock() }
    return turnHasAudioGap
  }
  func recoveryExpire() {
    lock.lock()
    let work = writeDeadline
    lock.unlock()
    work?.perform()
    recoveryDrain()
  }
  func recoveryConnectionFailure() {
    connectionFailed(epoch: connectionID, error: NSError(domain: "fixture", code: 2))
    recoveryDrain()
  }
  func recoverySend(_ text: String) {
    sendTurnMessage(text)
    recoveryDrain()
  }
}
extension GeminiLiveClient {
  func recoveryForceSettleAge() {
    lock.lock()
    turnCommitTime = ProcessInfo.processInfo.systemUptime - 10
    commitWritesCompletedAt = turnCommitTime
    let current = turnID
    lock.unlock()
    attemptSettle(turn: current)
  }
}
extension GeminiLiveClient {
  func fixtureOpen() {
    lock.lock()
    turnID &+= 1
    turnOpen = true
    readyState = true
    turnHasAudioGap = false
    hasFiredTurnCompletion = false
    currentTurnText = ""
    committedTranscript = ""
    interimTranscript = ""
    lock.unlock()
  }
  func fixtureMessage(_ fields: [String: Any], oldConnection: Bool = false) {
    let bytes = try! JSONSerialization.data(withJSONObject: ["serverContent": fields])
    lock.lock()
    let epoch = connectionID
    lock.unlock()
    handleIncomingMessage(.data(bytes), epoch: oldConnection ? epoch &- 1 : epoch)
  }
  func fixtureCompletion(
    _ completion:
      @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void
  ) {
    lock.lock()
    isCommitting = true
    turnCommitTime = ProcessInfo.processInfo.systemUptime
    commitWritesComplete = true
    commitWritesCompletedAt = turnCommitTime
    turnCompletion = completion
    lock.unlock()
  }
  func fixtureMeteredUsage() {
    lock.lock()
    lastSeenPromptTokens = 20
    lastSeenResponseTokens = 3
    lock.unlock()
  }
  func fixtureSetupComplete() {
    let bytes = try! JSONSerialization.data(withJSONObject: ["setupComplete": [:]])
    handleIncomingMessage(.data(bytes), epoch: connectionID)
  }
  func fixtureIdleRotation() { connect(onlyWhenIdle: true, expectedConnection: connectionID) }
  func fixtureText() -> String {
    lock.lock()
    defer { lock.unlock() }
    return currentTurnText
  }
  func fixtureGap() {
    lock.lock()
    turnHasAudioGap = true
    lock.unlock()
  }
  func fixtureBeginCommit(
    _ completion:
      @escaping (Result<(text: String, firstTokenMs: Double, totalMs: Double), Error>) -> Void
  ) {
    beginCommit(turn: turnID, completion: completion)
  }
}
