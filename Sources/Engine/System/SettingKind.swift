public enum SettingKind: Sendable {
  case toggle
  case text
  case microphone
  case integer(ClosedRange<Int>)
  case decimal(ClosedRange<Double>)
  case choice([String])
}
