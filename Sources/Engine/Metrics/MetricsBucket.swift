/// Bucketing and allowlists that keep measurements coarse and categories closed.
public enum MetricsBucket {
  public static func latency(_ milliseconds: Double?) -> MetricValue {
    guard let milliseconds, milliseconds.isFinite else { return .null }
    switch milliseconds {
    case ..<500: return .string("<500")
    case ..<1000: return .string("500-1000")
    case ..<2000: return .string("1000-2000")
    case ..<4000: return .string("2000-4000")
    default: return .string("4000+")
    }
  }
  public static func audio(_ seconds: Double?) -> MetricValue {
    guard let seconds, seconds.isFinite else { return .null }
    switch seconds {
    case ..<2: return .string("<2")
    case ..<5: return .string("2-5")
    case ..<15: return .string("5-15")
    case ..<60: return .string("15-60")
    default: return .string("60+")
    }
  }
  public static func days(_ days: Int) -> MetricValue {
    switch days {
    case ...0: .string("0")
    case 1...7: .string("1-7")
    case 8...30: .string("8-30")
    case 31...90: .string("31-90")
    default: .string("90+")
    }
  }
  /// Values outside the allowlist collapse to "other" so free text never leaks.
  public static func category(_ value: String?, allowed: Set<String>, empty: String = "none")
    -> MetricValue
  {
    guard let value, !value.isEmpty else { return .string(empty) }
    return .string(allowed.contains(value) ? value : "other")
  }
}
