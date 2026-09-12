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

extension DictationEngine {
  func fixtureInterruptedTurn() {
    audioCapture.fixtureInterruptedCapture()
    isProcessing = true
    runTurnPipeline(keyUpTime: ProcessInfo.processInfo.systemUptime)
    check(turnSettled && !isProcessing, "interrupted capture settles and releases busy state")
    check(
      pendingRestRequest == nil && restAttemptStart == nil,
      "interrupted capture never enters REST fallback")
    history?.close()
  }
}
extension DictationEngine {
  func fixtureRejectedTurn(silent: Bool) {
    audioCapture.fixtureRejectedCapture(silent: silent)
    isProcessing = true
    var callbacks = 0
    scheduleRejectedTurnUI = { action in
      callbacks += 1
      self.processingLock.lock()
      let busy = self.isProcessing
      self.processingLock.unlock()
      check(!busy, "rejected turn clears busy before main cleanup can run")
      action()
    }
    runTurnPipeline(keyUpTime: ProcessInfo.processInfo.systemUptime)
    check(callbacks == 1 && micIdleWorkItem != nil, "rejected turn arms microphone idle release")
    check(pendingRestRequest == nil, "rejected turn avoids transcription")
    micIdleWorkItem?.cancel()
    micIdleWorkItem = nil
  }
}
extension DictationEngine {
  /// audit F21: a REST hedge that fails while the live commit is in flight must leave the
  /// turn open, and the live result that arrives afterwards must still settle it once.
  /// A fresh engine's turn #0 is already live, so no capture or network call is needed.
  func fixtureRestHedgeFailure(expectSettle: Bool) {
    let done = DispatchSemaphore(value: 0)
    sessionQueue.async {
      self.wsCommitInFlight = true
      self.handleRestFailure(turnId: 0, error: NSError(domain: "fixture", code: 1))
      check(
        self.turnSettled == expectSettle,
        expectSettle
          ? "REST failure settles the turn when no live result can arrive"
          : "REST failure leaves a live WebSocket turn open")
      check(self.restTerminal, "REST failure is recorded as terminal for its route")
      if !expectSettle {
        // The live result wins the race the REST failure was not allowed to end.
        self.settle(turnId: 0, route: "WS", outcome: .empty(audioDuration: 1.0))
        check(self.turnSettled, "the live result settles the turn the REST failure kept open")
        self.handleRestFailure(turnId: 0, error: NSError(domain: "fixture", code: 2))
        check(self.turnSettled, "a settled turn cannot be re-settled by a late REST failure")
      }
      done.signal()
    }
    check(done.wait(timeout: .now() + 2) == .success, "turn arbiter fixture completes")
  }
}
