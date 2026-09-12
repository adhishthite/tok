import AppKit
import XCTest

@testable import TokHUD

@MainActor
final class HUDCopyTests: XCTestCase {
  private func makeHUD() -> FloatingHUD {
    // Reduced motion keeps every state change synchronous, so no display tick is needed.
    FloatingHUD(reduceMotion: { true })
  }

  private func tearDown(_ hud: FloatingHUD) {
    hud.hideWorkItem?.cancel()
    hud.stopTick()
    hud.hostPanel.orderOut(nil)
    hud.notchPanel.orderOut(nil)
  }

  func testListeningPlaceholderFollowsHotkeyMode() {
    let hud = makeHUD()
    defer { tearDown(hud) }

    hud.hotkeyMode = "push_to_talk"
    hud.shortcutLabel = "Fn"
    hud.showListening()
    XCTAssertEqual(hud.currentTranscriptText, "Speak, then release to paste")

    hud.hotkeyMode = "toggle"
    hud.shortcutLabel = "Right Option"
    hud.showListening()
    XCTAssertEqual(hud.currentTranscriptText, "Speak, then press Right Option to paste")
  }

  func testProcessingReplacesTheModeAwarePlaceholder() {
    let hud = makeHUD()
    defer { tearDown(hud) }

    hud.hotkeyMode = "toggle"
    hud.shortcutLabel = "Right Option"
    hud.showListening()
    hud.showProcessing()
    XCTAssertEqual(hud.currentTranscriptText, "Finishing…")
  }

  func testErrorLingerStretchesForRecoveryInstructions() {
    XCTAssertEqual(FloatingHUD.errorLinger(for: "Microphone busy."), 1.4)
    XCTAssertEqual(FloatingHUD.errorLinger(for: "Copied."), 3.0)
    XCTAssertEqual(
      FloatingHUD.errorLinger(for: "Transcription failed after the backup route timed out."), 3.0)
  }

  func testErrorWidensThePillToTheMessage() {
    let hud = makeHUD()
    defer { tearDown(hud) }

    hud.showListening()
    XCTAssertEqual(hud.widthSpring.target, HUDMetrics.minPillWidth)
    hud.showError(message: "Copied. Press Command V outside the password field.")
    XCTAssertGreaterThan(hud.widthSpring.target, HUDMetrics.minPillWidth)
    XCTAssertLessThanOrEqual(hud.widthSpring.target, HUDMetrics.maxPillWidth)
  }

  func testPrivacyErrorShowsOnlyTheLeadingWord() {
    let hud = makeHUD()
    defer { tearDown(hud) }

    hud.showListening()
    hud.privacyMode = true
    hud.showError(message: "Copied. Press Command V outside the password field.")
    XCTAssertEqual(hud.currentTranscriptText, "Copied")
    XCTAssertEqual(FloatingHUD.shortErrorWord("Cancelled."), "Cancelled")
    XCTAssertEqual(FloatingHUD.shortErrorWord("  "), "Error")
    XCTAssertEqual(FloatingHUD.shortErrorWord("No speech detected"), "Error")
  }

  func testProcessingStatusOnlyChangesTheHeaderDuringProcessing() {
    let hud = makeHUD()
    defer { tearDown(hud) }

    hud.showListening()
    hud.updateLiveText("Synthetic fixture words")
    hud.showProcessing()
    hud.updateProcessingStatus("Still working")
    XCTAssertEqual(hud.currentTranscriptText, "Synthetic fixture words")

    hud.showSuccess(text: "Synthetic fixture words")
    hud.updateProcessingStatus("Using backup route")
    XCTAssertEqual(hud.currentTranscriptText, "Synthetic fixture words")
  }
}
