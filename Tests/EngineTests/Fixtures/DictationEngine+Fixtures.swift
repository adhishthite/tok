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
