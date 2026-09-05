import XCTest

@testable import TokEngine

final class MicrophonePolicyTests: XCTestCase {
  func testOnDemandSetupLeavesMicrophoneClosed() {
    let audio = AudioCaptureEngine()
    XCTAssertTrue(audio.setup(startImmediately: false))
    XCTAssertFalse(audio.isEngineRunning)
    XCTAssertFalse(EngineConfiguration().keepMicrophoneWarm)
  }

  func testWarmCaptureIsExplicitlySelectable() {
    XCTAssertTrue(
      EngineConfiguration.load(values: ["KEEP_MICROPHONE_WARM": "true"]).keepMicrophoneWarm)
  }
}
