import AppKit
import XCTest

@testable import TokHUD

@MainActor
final class HUDPrivacyTransitionTests: XCTestCase {
  func testPrivacyHidesCachedTextWithoutWaitingForAnotherFrame() {
    for reduced in [false, true] {
      let hud = FloatingHUD(reduceMotion: { reduced })
      defer {
        hud.hideWorkItem?.cancel()
        hud.stopTick()
        hud.hostPanel.orderOut(nil)
        hud.notchPanel.orderOut(nil)
      }
      hud.showListening()
      hud.showSuccess(text: "Private fixture words")
      hud.stopTick()
      hud.hostView.alphaValue = 1
      XCTAssertEqual(hud.currentTranscriptText, "Private fixture words")
      hud.privacyMode = true
      XCTAssertEqual(hud.hostView.alphaValue, 0)
      XCTAssertFalse(hud.hostPanel.isVisible)
      XCTAssertTrue(hud.currentTranscriptText.isEmpty)
    }
  }
}
