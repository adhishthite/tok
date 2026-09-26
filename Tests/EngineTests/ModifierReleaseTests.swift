// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import IOKit.hidsystem
import XCTest

@testable import TokEngine

final class ModifierReleaseTests: XCTestCase {
  func testReleasingConfiguredSideWhileOtherSideIsHeldFinishesCapture() throws {
    let cases: [(HotkeyManager.KeyBinding, CGKeyCode, CGEventFlags, Int32, Int32)] = [
      (.rightOption, 61, .maskAlternate, NX_DEVICERALTKEYMASK, NX_DEVICELALTKEYMASK),
      (.leftOption, 58, .maskAlternate, NX_DEVICELALTKEYMASK, NX_DEVICERALTKEYMASK),
      (.rightControl, 62, .maskControl, NX_DEVICERCTLKEYMASK, NX_DEVICELCTLKEYMASK),
      (.leftControl, 59, .maskControl, NX_DEVICELCTLKEYMASK, NX_DEVICERCTLKEYMASK),
      (.rightCmd, 54, .maskCommand, NX_DEVICERCMDKEYMASK, NX_DEVICELCMDKEYMASK),
      (.leftCmd, 55, .maskCommand, NX_DEVICELCMDKEYMASK, NX_DEVICERCMDKEYMASK),
    ]
    for (binding, code, family, own, other) in cases {
      let manager = HotkeyManager(binding: binding, mode: "push_to_talk")
      var starts = 0
      var releases = 0
      manager.onKeyDown = { starts += 1 }
      manager.onKeyUp = { releases += 1 }
      manager.readKeyState = { _ in
        XCTFail("Complete device flags should be sufficient")
        return false
      }
      let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
      event.flags = CGEventFlags(rawValue: family.rawValue | UInt64(own | other))
      manager.handleCGEvent(type: .flagsChanged, event: event)
      event.flags = CGEventFlags(rawValue: family.rawValue | UInt64(other))
      manager.handleCGEvent(type: .flagsChanged, event: event)
      XCTAssertEqual(starts, 1)
      XCTAssertEqual(releases, 1, "Configured modifier release must not depend on the other side.")
    }
  }

  // audit F10: Fn plus another key is a system chord, not a dictation.
  func testChordDuringHoldFiresOnceAndSuppressesTheRelease() throws {
    let manager = HotkeyManager(binding: .fn, mode: "push_to_talk")
    var starts = 0
    var releases = 0
    var chords = 0
    manager.onKeyDown = { starts += 1 }
    manager.onKeyUp = { releases += 1 }
    manager.onChord = { chords += 1 }

    try hold(manager, pressed: true)
    XCTAssertEqual(starts, 1)
    // Fn plus Delete, then Fn plus Home inside the same hold.
    try press(manager, keyCode: 51)
    try press(manager, keyCode: 115)
    XCTAssertEqual(chords, 1, "a chord fires once per hold")
    try hold(manager, pressed: false)
    XCTAssertEqual(releases, 0, "the release of a chord must not run the pipeline")

    // The next hold is a clean one again.
    try hold(manager, pressed: true)
    try hold(manager, pressed: false)
    XCTAssertEqual(starts, 2)
    XCTAssertEqual(releases, 1, "a plain hold still starts and finishes a turn")
    XCTAssertEqual(chords, 1, "the chord latch resets with the hold")
  }

  // A toggle turn is dictated hands-free, so typing after the press must not abandon it.
  func testToggleChordOnlyCountsWhileTheKeyIsPhysicallyDown() throws {
    let manager = HotkeyManager(binding: .fn, mode: "toggle")
    var chords = 0
    manager.onChord = { chords += 1 }

    try hold(manager, pressed: true)
    try press(manager, keyCode: 51)
    XCTAssertEqual(chords, 1, "a key pressed during the toggle press is still a chord")
    try hold(manager, pressed: false)
    try press(manager, keyCode: 51)
    XCTAssertEqual(chords, 1, "typing while a toggle turn runs is not a chord")
  }

  // audit F11: Escape is observed at any time, and the hold it interrupts ends silently.
  func testEscapeReportsCancelAndEndsTheHold() throws {
    let manager = HotkeyManager(binding: .fn, mode: "push_to_talk")
    var releases = 0
    var cancels = 0
    var chords = 0
    manager.onKeyUp = { releases += 1 }
    manager.onCancelKey = { cancels += 1 }
    manager.onChord = { chords += 1 }

    try press(manager, keyCode: HotkeyManager.escapeKeyCode)
    XCTAssertEqual(cancels, 1, "Escape is reported with no turn in progress too")
    try hold(manager, pressed: true)
    try press(manager, keyCode: HotkeyManager.escapeKeyCode)
    XCTAssertEqual(cancels, 2)
    XCTAssertEqual(chords, 0, "Escape is a cancel, not a chord")
    try hold(manager, pressed: false)
    XCTAssertEqual(releases, 0, "the release after Escape must not run the pipeline")
  }

  // An F-key binding keeps its own key-down and key-up semantics.
  func testKeyBindingIsUnchangedByChordDetection() throws {
    let manager = HotkeyManager(binding: .fKey(0x69), mode: "push_to_talk")
    var starts = 0
    var releases = 0
    var chords = 0
    manager.onKeyDown = { starts += 1 }
    manager.onKeyUp = { releases += 1 }
    manager.onChord = { chords += 1 }
    XCTAssertFalse(manager.detectsChords, "a key binding does not widen its own mask")

    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x69, keyDown: true))
    manager.handleCGEvent(type: .keyDown, event: event)
    try press(manager, keyCode: 51)
    manager.handleCGEvent(type: .keyUp, event: event)
    XCTAssertEqual(starts, 1)
    XCTAssertEqual(releases, 1, "an F-key hold still finishes its turn")
    XCTAssertEqual(chords, 0)
  }

  /// Fn down or up, as flagsChanged carrying the secondary-Fn flag. The press-edge debounce
  /// is stood down, the way fixturePress does, so back-to-back synthetic holds still land.
  private func hold(_ manager: HotkeyManager, pressed: Bool) throws {
    manager.lastStateChangeTime = 0
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: pressed))
    event.flags = pressed ? .maskSecondaryFn : []
    manager.handleCGEvent(type: .flagsChanged, event: event)
  }

  /// A plain key-down for some other key.
  private func press(_ manager: HotkeyManager, keyCode: CGKeyCode) throws {
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true))
    manager.handleCGEvent(type: .keyDown, event: event)
  }

  func testEventsWithoutDeviceBitsUsePerKeyState() throws {
    let manager = HotkeyManager(binding: .rightOption, mode: "push_to_talk")
    var pressed = true
    var releases = 0
    manager.readKeyState = { key in
      XCTAssertEqual(key, 61)
      return pressed
    }
    manager.onKeyUp = { releases += 1 }
    let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true))
    event.flags = .maskAlternate
    manager.handleCGEvent(type: .flagsChanged, event: event)
    pressed = false
    manager.handleCGEvent(type: .flagsChanged, event: event)
    XCTAssertEqual(releases, 1)
  }
}
