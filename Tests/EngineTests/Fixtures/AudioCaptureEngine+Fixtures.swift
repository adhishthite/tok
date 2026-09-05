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

extension AudioCaptureEngine {
  func fixtureConversionFailure() {
    audioProcessingQueue.sync {
      lock.lock()
      isRecording = true
      turnInterrupted = false
      lock.unlock()
      discardFailedBuffer()
      check(turnInterrupted, "single conversion failure invalidates captured audio")
      isRecording = false
    }
  }
  func fixtureInterruptedCapture() {
    audioProcessingQueue.sync {
      lock.lock()
      isRecording = true
      turnInterrupted = true
      recordingStartTime = ProcessInfo.processInfo.systemUptime - 1
      recordedPCMData = Data(count: 32000)
      lock.unlock()
    }
  }
}
extension AudioCaptureEngine {
  func fixtureRejectedCapture(silent: Bool) {
    audioProcessingQueue.sync {
      lock.lock()
      isRecording = true
      turnInterrupted = false
      recordingStartTime = ProcessInfo.processInfo.systemUptime - (silent ? 1 : 0.01)
      recordedPCMData = Data(count: silent ? 32000 : 320)
      statSampleCount = silent ? 16000 : 0
      turnMaxAbsSample = 0
      frameDbValues = silent ? [-120] : []
      lock.unlock()
    }
  }
}
