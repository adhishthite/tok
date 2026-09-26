// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

public enum SettingKind: Sendable {
  case toggle
  case text
  case microphone
  case integer(ClosedRange<Int>)
  case decimal(ClosedRange<Double>)
  case choice([String])
}
