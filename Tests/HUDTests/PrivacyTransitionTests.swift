import AppKit
import QuartzCore
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

  func testReduceMotionChangeSettlesActiveHUDAndResumesWhenDisabled() {
    var reduced = false
    let notifications = NotificationCenter()
    let hud = FloatingHUD(
      reduceMotion: { reduced }, accessibilityNotifications: notifications)
    defer {
      hud.hideWorkItem?.cancel()
      hud.stopTick()
      hud.hostPanel.orderOut(nil)
      hud.notchPanel.orderOut(nil)
    }
    hud.showListening(lockAfter: 2)
    hud.updateLiveText("Synthetic fixture with enough words to expand the listening pill")
    XCTAssertTrue(hud.isTicking)
    XCTAssertFalse(hud.presence.settled)
    reduced = true
    notifications.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    XCTAssertFalse(hud.isTicking)
    XCTAssertTrue(hud.presence.settled)
    XCTAssertTrue(hud.widthSpring.settled)
    XCTAssertEqual(hud.hostView.alphaValue, 1)
    XCTAssertTrue(hud.hostPanel.isVisible)

    reduced = false
    notifications.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    XCTAssertTrue(hud.isTicking)
    XCTAssertTrue(hud.hostPanel.isVisible)
  }

  func testReduceMotionChangeFlushesLockedTextAndPreservesPrivacy() {
    var reduced = false
    let notifications = NotificationCenter()
    let hud = FloatingHUD(
      reduceMotion: { reduced }, accessibilityNotifications: notifications)
    defer {
      hud.hideWorkItem?.cancel()
      hud.stopTick()
      hud.hostPanel.orderOut(nil)
      hud.notchPanel.orderOut(nil)
    }
    hud.showListening(lockAfter: 2)
    hud.showLocked()
    hud.updateLiveText("Synthetic queued words")
    XCTAssertNotEqual(hud.currentTranscriptText, "Synthetic queued words")
    reduced = true
    notifications.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    XCTAssertEqual(hud.currentTranscriptText, "Synthetic queued words")
    XCTAssertFalse(hud.isTicking)
    hud.privacyMode = true
    reduced = false
    notifications.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    XCTAssertFalse(hud.hostPanel.isVisible)
    XCTAssertEqual(hud.hostView.alphaValue, 0)
  }

  func testEnablingReduceMotionDuringExitHidesPanelsImmediately() {
    var reduced = false
    let notifications = NotificationCenter()
    let hud = FloatingHUD(
      reduceMotion: { reduced }, accessibilityNotifications: notifications)
    defer { hud.stopTick() }
    hud.showListening()
    hud.presence.snap()
    hud.applyFrame()
    hud.hide()
    XCTAssertTrue(hud.isTicking)
    reduced = true
    notifications.post(
      name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    XCTAssertFalse(hud.isTicking)
    XCTAssertEqual(hud.presence.value, 0)
    XCTAssertFalse(hud.hostPanel.isVisible)
    XCTAssertFalse(hud.notchPanel.isVisible)
  }

  func testStoppingAuraMotionRemovesAnActiveRipple() {
    let aura = AuraView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
    let ripple = CAShapeLayer()
    aura.layer?.addSublayer(ripple)
    let animation = CABasicAnimation(keyPath: "opacity")
    animation.duration = 10
    ripple.add(animation, forKey: "successRipple")
    XCTAssertNotNil(ripple.animation(forKey: "successRipple"))
    aura.stopMotion()
    XCTAssertNil(ripple.superlayer)
    XCTAssertNil(ripple.animation(forKey: "successRipple"))
  }

}
