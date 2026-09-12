import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import IOKit.hidsystem
import Network
import SQLite3

final class HotkeyManager {

  let binding: KeyBinding
  let mode: String
  private var isKeyDown: Bool = false
  private var physicalKeyDown = false
  var lastStateChangeTime: CFAbsoluteTime = 0
  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?

  private(set) var lastEventUptime: TimeInterval?

  var onKeyDown: (() -> Void)?
  var onKeyUp: (() -> Void)?
  // Another key was pressed while the shortcut was held: Fn plus Delete, Fn plus arrow.
  // Fires once per hold; the release that follows delivers no onKeyUp (audit F10).
  var onChord: (() -> Void)?
  // Escape was pressed. Observed, never swallowed: the tap is listen-only, so the
  // destination app receives the same Escape (audit F11).
  var onCancelKey: (() -> Void)?
  var readKeyState: (CGKeyCode) -> Bool = {
    CGEventSource.keyState(.combinedSessionState, key: $0)
  }

  init(binding: KeyBinding, mode: String) {
    self.binding = binding
    self.mode = mode
    // A modifier binding reports itself through flagsChanged only, so chord and Escape
    // detection are what put key-downs in its mask. An F-key or custom binding already
    // subscribes to key-downs, so nothing widens for it.
    switch binding {
    case .fKey, .custom: detectsChords = false
    default: detectsChords = true
    }
  }

  // Chord detection ("another key pressed while the shortcut is held") needs key-downs for
  // a modifier binding too; init turns it on for exactly those. It only widens the mask.
  var detectsChords = false

  // Set when a chord fired during the current hold, cleared when the hold ends.
  private var chordLatched = false

  static let escapeKeyCode: CGKeyCode = 53

  /// True while the shortcut key is physically down. Deliberately not the toggle mode's
  /// armed state: a toggle turn is dictated hands-free, and typing during it (Cmd plus Tab,
  /// say) is not a chord against a key nobody is holding.
  var isPhysicallyHeld: Bool { physicalKeyDown }

  /// The key code the binding itself reports, so the shortcut's own events are never read
  /// as a chord against it.
  private var bindingKeyCode: CGKeyCode {
    switch binding {
    case .rightOption: return 61
    case .leftOption: return 58
    case .rightControl: return 62
    case .leftControl: return 59
    case .rightCmd: return 54
    case .leftCmd: return 55
    case .fn: return 63
    case .fKey(let code), .custom(let code): return code
    }
  }

  /// Only the events the binding needs (audit F12). A modifier binding is reported through
  /// flagsChanged, plus keyDown when chord detection is on (the default for modifiers); an
  /// F-key or custom key needs keyDown and keyUp. keyUp is never subscribed for a modifier.
  /// A listen-only tap is woken for every event it subscribes to, so the mask stays minimal.
  var eventMask: CGEventMask {
    func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << CGEventMask(type.rawValue) }
    switch binding {
    case .fKey, .custom:
      return bit(.keyDown) | bit(.keyUp)
    default:
      return detectsChords ? bit(.flagsChanged) | bit(.keyDown) : bit(.flagsChanged)
    }
  }

  func start() -> Bool {
    let selfPointer = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

    guard
      let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .listenOnly,
        eventsOfInterest: eventMask,
        callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
          guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
          let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()

          // Auto-recover tap if disabled by macOS timeout
          if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = manager.eventTap {
              CGEvent.tapEnable(tap: t, enable: true)
            }
            return Unmanaged.passUnretained(event)
          }

          manager.handleCGEvent(type: type, event: event)
          return Unmanaged.passUnretained(event)
        },
        userInfo: selfPointer
      )
    else {
      return false
    }

    self.eventTap = tap
    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    self.runLoopSource = source
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    return true
  }

  func handleCGEvent(type: CGEventType, event: CGEvent) {
    lastEventUptime = Double(event.timestamp) / 1_000_000_000
    let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags

    if type == .keyDown, keyCode == Self.escapeKeyCode {
      // Escape during a hold also ends that hold: the engine abandons the turn, so the
      // release must not run the finish pipeline either.
      if isPhysicallyHeld { chordLatched = true }
      onCancelKey?()
      return
    }

    // A second key pressed while the shortcut is held is a system chord (Fn plus Delete,
    // Fn plus Home), not a dictation. Only the binding's own key is exempt.
    if type == .keyDown, detectsChords, isPhysicallyHeld, keyCode != bindingKeyCode {
      guard !chordLatched else { return }
      chordLatched = true
      onChord?()
      return
    }

    switch binding {
    case .rightOption:
      if type == .flagsChanged && keyCode == 61 {
        let isPressed = modifierPressed(
          keyCode, flags, family: .maskAlternate,
          own: NX_DEVICERALTKEYMASK, other: NX_DEVICELALTKEYMASK)
        updateKeyState(pressed: isPressed)
      }
    case .leftOption:
      if type == .flagsChanged && keyCode == 58 {
        let isPressed = modifierPressed(
          keyCode, flags, family: .maskAlternate,
          own: NX_DEVICELALTKEYMASK, other: NX_DEVICERALTKEYMASK)
        updateKeyState(pressed: isPressed)
      }
    case .rightControl:
      if type == .flagsChanged && keyCode == 62 {
        let isPressed = modifierPressed(
          keyCode, flags, family: .maskControl,
          own: NX_DEVICERCTLKEYMASK, other: NX_DEVICELCTLKEYMASK)
        updateKeyState(pressed: isPressed)
      }
    case .leftControl:
      if type == .flagsChanged && keyCode == 59 {
        let isPressed = modifierPressed(
          keyCode, flags, family: .maskControl,
          own: NX_DEVICELCTLKEYMASK, other: NX_DEVICERCTLKEYMASK)
        updateKeyState(pressed: isPressed)
      }
    case .rightCmd:
      if type == .flagsChanged && keyCode == 54 {
        let isPressed = modifierPressed(
          keyCode, flags, family: .maskCommand,
          own: NX_DEVICERCMDKEYMASK, other: NX_DEVICELCMDKEYMASK)
        updateKeyState(pressed: isPressed)
      }
    case .leftCmd:
      if type == .flagsChanged && keyCode == 55 {
        let isPressed = modifierPressed(
          keyCode, flags, family: .maskCommand,
          own: NX_DEVICELCMDKEYMASK, other: NX_DEVICERCMDKEYMASK)
        updateKeyState(pressed: isPressed)
      }
    case .fn:
      if type == .flagsChanged && keyCode == 63 {
        let isPressed = flags.contains(.maskSecondaryFn)
        updateKeyState(pressed: isPressed)
      }
    case .fKey(let targetCode), .custom(let targetCode):
      if keyCode == targetCode {
        if type == .keyDown {
          updateKeyState(pressed: true)
        } else if type == .keyUp {
          updateKeyState(pressed: false)
        }
      }
    }
  }

  private func modifierPressed(
    _ code: CGKeyCode, _ flags: CGEventFlags, family: CGEventFlags, own: Int32, other: Int32
  ) -> Bool {
    guard flags.contains(family) else { return false }
    // Aggregate flags stay set while either side is down. Prefer the event's
    // side-specific state; query the individual key for events that omit it.
    if flags.rawValue & UInt64(own | other) != 0 {
      return flags.rawValue & UInt64(own) != 0
    }
    return readKeyState(code)
  }

  func updateKeyState(pressed: Bool) {
    let now = ProcessInfo.processInfo.systemUptime
    let wasPhysicallyDown = physicalKeyDown
    // Physical state is tracked in both modes: chord detection asks whether the shortcut
    // is held, and only the toggle branch below reads the press edge.
    physicalKeyDown = pressed
    // The latch lives for one hold. Read it before the release clears it.
    let chorded = chordLatched
    if !pressed { chordLatched = false }

    if mode == "toggle" {
      let pressEdge = pressed && !wasPhysicallyDown
      guard pressEdge else { return }
      // Both toggle transitions fire on a press edge, so the 80ms debounce applies to both.
      guard (now - lastStateChangeTime) > 0.08 else { return }  // 80ms debounce
      if pressed && !isKeyDown {
        isKeyDown = true
        lastStateChangeTime = now
        onKeyDown?()
      } else if pressed && isKeyDown {
        isKeyDown = false
        lastStateChangeTime = now
        onKeyUp?()
      }
    } else {
      // Push-to-Talk (Hold): debounce only the press edge. A release must never be
      // swallowed - dropping it would leave isKeyDown stuck true (mic stuck recording)
      // after a press+release faster than the debounce window.
      if pressed && !isKeyDown {
        guard (now - lastStateChangeTime) > 0.08 else { return }  // 80ms debounce
        isKeyDown = true
        lastStateChangeTime = now
        onKeyDown?()
      } else if !pressed && isKeyDown {
        isKeyDown = false
        lastStateChangeTime = now
        // The chord already abandoned this hold's capture; running the pipeline on its
        // release would finish a turn the user never dictated (audit F10).
        guard !chorded else { return }
        onKeyUp?()
      }
    }
  }

  // External completion or refused startup must reset toggle intent, not physical state.
  func resetToggle() {
    if mode == "toggle" { isKeyDown = false }
  }

  func stop() {
    if let tap = eventTap {
      CGEvent.tapEnable(tap: tap, enable: false)
      // A disabled tap still holds its Mach port and run loop source. Without this a
      // settings change leaks one tap per engine restart (audit F33).
      CFMachPortInvalidate(tap)
    }
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    eventTap = nil
    runLoopSource = nil
  }
}
