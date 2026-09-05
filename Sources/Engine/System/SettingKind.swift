public enum SettingKind: Sendable {
  case toggle
  case text
  case integer(ClosedRange<Int>)
  case decimal(ClosedRange<Double>)
  case choice([String])
}
