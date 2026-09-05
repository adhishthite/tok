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

final class MicrophoneRegressionTests: XCTestCase {
  func testReferenceFixtures() throws {

    let recoverMissingTap = FakeMicDriver()
    recoverMissingTap.failures = 1
    var micReady: [Bool] = []
    recoverMissingTap.controller.ensureReady { micReady.append($0) }
    check(!recoverMissingTap.tap && micReady.isEmpty, "failed rebuild cannot announce ready")
    recoverMissingTap.advance(0.25)
    check(
      recoverMissingTap.rebuilds == 2 && recoverMissingTap.tap, "recovery reconstructs removed tap")
    check(micReady.isEmpty, "engine start alone cannot announce ready")
    recoverMissingTap.buffer()
    check(
      micReady == [true] && recoverMissingTap.controller.healthy,
      "converted buffer establishes readiness")

    let missingBuffers = FakeMicDriver()
    var noBufferReady: [Bool] = []
    missingBuffers.controller.ensureReady { noBufferReady.append($0) }
    missingBuffers.advance(3)
    check(missingBuffers.rebuilds == 3, "no-buffer retries are bounded")
    check(
      noBufferReady == [false] && !missingBuffers.running,
      "no-buffer timeout rejects capture and stops engine")
    missingBuffers.controller.ensureReady { noBufferReady.append($0) }
    missingBuffers.buffer()
    check(noBufferReady == [false, true], "new request can recover after exhausted retry budget")

    let obsoleteMic = FakeMicDriver()
    _ = obsoleteMic.controller.start()
    obsoleteMic.buffer()
    let oldMicGeneration = obsoleteMic.controller.generation
    obsoleteMic.controller.configurationChanged()
    for _ in 0..<100 { obsoleteMic.controller.configurationChanged() }
    check(obsoleteMic.rebuilds == 1, "configuration notification burst coalesces before rebuild")
    obsoleteMic.advance(0.1)
    check(obsoleteMic.rebuilds == 2, "configuration burst performs one rebuild")
    obsoleteMic.controller.receivedBuffer(generation: oldMicGeneration, at: obsoleteMic.now)
    check(!obsoleteMic.controller.healthy, "obsolete device callbacks cannot establish readiness")
    obsoleteMic.controller.receivedBuffer(generation: obsoleteMic.controller.generation, at: -1)
    check(!obsoleteMic.controller.healthy, "delayed buffers cannot fake current microphone health")
    obsoleteMic.buffer()
    check(obsoleteMic.controller.healthy, "current device callbacks establish readiness")
    obsoleteMic.advance(1)
    check(
      obsoleteMic.interruptions >= 2 && !obsoleteMic.controller.healthy,
      "missing ongoing audio triggers recovery")

    let suspendedMic = FakeMicDriver()
    suspendedMic.failures = 10
    var suspendedReady: [Bool] = []
    suspendedMic.controller.ensureReady { suspendedReady.append($0) }
    suspendedMic.controller.suspend()
    suspendedMic.advance(10)
    check(
      suspendedMic.rebuilds == 1 && suspendedReady == [false],
      "suspend cancels retries and pending readiness")
    suspendedMic.controller.configurationChanged()
    suspendedMic.advance(1)
    check(suspendedMic.rebuilds == 1, "configuration changes do not reawaken suspended microphone")

    let cancelledMic = FakeMicDriver()
    var cancelledReady: [Bool] = []
    cancelledMic.controller.ensureReady { cancelledReady.append($0) }
    cancelledMic.controller.cancelPendingReadiness()
    cancelledMic.buffer()
    check(cancelledReady == [false], "released hotkey cannot receive late readiness success")

    let configurationStorm = FakeMicDriver()
    configurationStorm.failures = 100
    _ = configurationStorm.controller.start()
    for _ in 0..<20 {
      configurationStorm.controller.configurationChanged()
      configurationStorm.advance(0.1)
    }
    check(
      configurationStorm.rebuilds == 3, "configuration storms cannot reset bounded failure retries")

    let flickeringMic = FakeMicDriver()
    _ = flickeringMic.controller.start()
    for _ in 0..<10 {
      flickeringMic.buffer()
      flickeringMic.controller.configurationChanged()
      flickeringMic.advance(0.1)
    }
    check(
      flickeringMic.rebuilds == 3 && !flickeringMic.running,
      "brief audio between configuration events does not reset recovery budget")

  }
}
