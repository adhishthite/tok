import Foundation

/// The width of one bar in the words-over-time chart.
public enum StatsBucket: Sendable, Equatable {
  case hour
  case day
  case month

  public var component: Calendar.Component {
    switch self {
    case .hour: .hour
    case .day: .day
    case .month: .month
    }
  }

  /// Hours within a day, days within a week or month, months across longer spans.
  static func forRange(_ range: StatsRange, spanDays: Int) -> StatsBucket {
    switch range {
    case .today: .hour
    case .week, .month: .day
    case .year: .month
    case .all: spanDays <= 92 ? .day : .month
    }
  }
}
