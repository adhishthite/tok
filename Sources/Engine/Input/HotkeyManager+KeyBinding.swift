import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

extension HotkeyManager {
  enum KeyBinding {
    case rightOption
    case leftOption
    case rightControl
    case leftControl
    case rightCmd
    case leftCmd
    case fn
    case fKey(CGKeyCode)
    case custom(CGKeyCode)

    static func from(string: String) -> KeyBinding {
      switch string.lowercased() {
      case "right_option", "right_alt", "roption": return .rightOption
      case "left_option", "left_alt", "loption": return .leftOption
      case "right_control", "right_ctrl", "rctrl": return .rightControl
      case "left_control", "left_ctrl", "lctrl": return .leftControl
      case "right_cmd", "right_command", "rcmd": return .rightCmd
      case "left_cmd", "left_command", "lcmd": return .leftCmd
      case "fn", "globe": return .fn
      case "f13": return .fKey(0x69)
      case "f14": return .fKey(0x6B)
      case "f15": return .fKey(0x71)
      case "f16": return .fKey(0x6A)
      case "f17": return .fKey(0x40)
      case "f18": return .fKey(0x4F)
      case "f19": return .fKey(0x50)
      case "f20": return .fKey(0x5A)
      default:
        if let code = UInt16(string) {
          return .custom(CGKeyCode(code))
        }
        return .fn
      }
    }

    var name: String {
      switch self {
      case .rightOption: return "Right Option (⌥ Right)"
      case .leftOption: return "Left Option (⌥ Left)"
      case .rightControl: return "Right Control (⌃ Right)"
      case .leftControl: return "Left Control (⌃ Left)"
      case .rightCmd: return "Right Command (⌘ Right)"
      case .leftCmd: return "Left Command (⌘ Left)"
      case .fn: return "Fn / Globe (🌐)"
      case .fKey(let code): return "F-Key (keyCode: \(code))"
      case .custom(let code): return "Custom Key (keyCode: \(code))"
      }
    }
  }
}
