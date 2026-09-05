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
