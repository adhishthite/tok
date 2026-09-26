// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

public enum ShortcutSupport {
  public static func keyCode(for name: String) -> UInt16 {
    switch HotkeyManager.KeyBinding.from(string: name) {
    case .fn: 63
    case .rightOption: 61
    case .leftOption: 58
    case .rightControl: 62
    case .leftControl: 59
    case .rightCmd: 54
    case .leftCmd: 55
    case .fKey(let code), .custom(let code): code
    }
  }
}
