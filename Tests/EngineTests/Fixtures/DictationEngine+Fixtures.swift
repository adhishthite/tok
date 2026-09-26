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
extension DictationEngine {
  /// audit F11: cancelling retires the turn, so the live result that arrives afterwards is
  /// stale and never pastes, exactly one "cancelled" row is written, and the next turn
  /// settles normally. A fresh engine's turn #0 is already live, so no capture is needed,
  /// and the cancel makes turn #1 the current one.
  func fixtureCancelledTurn(recorder: EngineEventRecorder) {
    let done = DispatchSemaphore(value: 0)
    processingLock.lock()
    isProcessing = true
    processingLock.unlock()
    sessionQueue.async {
      self.wsCommitInFlight = true
      self.turnSettled = false
      self.cancelTurn(source: "escape")
      check(self.turnSettled, "cancel closes the turn so no route can still paste it")
      self.processingLock.lock()
      let busy = self.isProcessing
      self.processingLock.unlock()
      check(!busy, "cancel clears the busy flag")
      check(self.pendingRestRequest == nil, "cancel drops the REST request")
      // The live result loses a race it was cancelled out of: turn #0 is retired.
      self.settle(turnId: 0, route: "WS", outcome: .empty(audioDuration: 1.0))
      // A turn started after the cancel still settles.
      self.turnSettled = false
      self.settle(turnId: 1, route: "WS", outcome: .empty(audioDuration: 1.0))
      check(self.turnSettled, "a turn started after a cancel settles normally")
      // A second cancel with no turn in flight writes nothing.
      self.cancelTurn(source: "escape")
      done.signal()
    }
    check(done.wait(timeout: .now() + 2) == .success, "cancel fixture completes")
    let outcomes = recorder.events.compactMap { event -> String? in
      if case .turnSettled(let record) = event { return record.outcome }
      return nil
    }
    check(
      outcomes == ["cancelled", "empty"],
      "cancel records one cancelled row and never a stale one: \(outcomes)")
  }
}
extension DictationEngine {
  /// hedge_fired and hedge_winner are stamped in settle(), from sessionQueue-only
  /// arbiter state, not from a main-thread turn* var. A fresh engine's turn #0 is already
  /// live, so no capture or network call is needed; enableLiveWebSocket is off so liveClient
  /// stays nil and reconnectedDuringTurn/the round-trip fields settle to NULL, exactly the
  /// values a REST-only configuration should record.
  func fixtureHedgeStamping(recorder: EngineEventRecorder, hedgeFired: Bool, route: String) {
    let done = DispatchSemaphore(value: 0)
    sessionQueue.async {
      if hedgeFired { self.turnHedgeFired = true }
      self.settle(turnId: 0, route: route, outcome: .empty(audioDuration: 1.0))
      done.signal()
    }
    check(done.wait(timeout: .now() + 2) == .success, "hedge stamping fixture completes")
    let record = recorder.events.compactMap { event -> TurnRecord? in
      if case .turnSettled(let record) = event { return record }
      return nil
    }.first
    check(record?.hedgeFired == hedgeFired, "hedge_fired reflects whether a hedge/fallback ran")
    if hedgeFired {
      check(
        record?.hedgeWinner == (route == "WS" ? "ws" : "rest"),
        "hedge_winner names the route that settled the turn")
    } else {
      check(record?.hedgeWinner == nil, "no hedge means hedge_winner is NULL")
    }
    check(
      record?.reconnectedDuringTurn == nil && record?.commitToLastSendMs == nil,
      "no live client means the connection/round-trip fields stay NULL")
  }
}
