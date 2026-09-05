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
}
