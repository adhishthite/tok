import CoreGraphics
import Foundation
import XCTest

@testable import TokEngine

final class LifecycleTests: XCTestCase {
  func testStopRejectsSettlementAlreadyQueuedAheadOfCleanup() {
    var config = EngineConfiguration()
    config.historyEnabled = false
    config.soundFeedback = false
    config.enableLiveWebSocket = false
    let engine = DictationEngine(config: config)
    let recorder = EngineEventRecorder()
    engine.delegate = recorder
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    engine.sessionQueue.async {
      entered.signal()
      release.wait()
      engine.settle(
        turnId: 0, route: "fixture", outcome: .failure(NSError(domain: "fixture", code: 1)))
    }
    XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
    engine.stop()
    release.signal()
    engine.sessionQueue.sync {}
    XCTAssertTrue(
      recorder.events.isEmpty,
      "Stopping must reject queued settlement before asynchronous cleanup runs")
  }

  // audit F12: the listen-only tap subscribes only to the events its binding can produce.
  func testEventMaskFollowsBinding() {
    func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(type.rawValue) }
    let modifier = HotkeyManager(binding: .fn, mode: "push_to_talk")
    XCTAssertEqual(modifier.eventMask, bit(.flagsChanged), "a modifier binding needs flags only")
    modifier.detectsChords = true
    XCTAssertEqual(
      modifier.eventMask, bit(.flagsChanged) | bit(.keyDown),
      "chord detection adds key-downs and still leaves key-ups out")
    let key = HotkeyManager(binding: .fKey(0x69), mode: "push_to_talk")
    XCTAssertEqual(
      key.eventMask, bit(.keyDown) | bit(.keyUp), "a key binding needs key-down and key-up only")
  }
}
