import Foundation

/// A calendar-aligned window for the stats dashboard, plus the equal window before it.
public enum StatsRange: String, CaseIterable, Identifiable, Sendable {
  case today
  case week
  case month
  case year
  case all

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .today: "Today"
    case .week: "This week"
    case .month: "This month"
    case .year: "This year"
    case .all: "All time"
    }
  }

  /// How the equal window before this one is named in a comparison, or nil for all time.
  public var previousTitle: String? {
    switch self {
    case .today: "yesterday"
    case .week: "last week"
    case .month: "last month"
    case .year: "last year"
    case .all: nil
    }
  }

  private var component: Calendar.Component? {
    switch self {
    case .today: .day
    case .week: .weekOfYear
    case .month: .month
    case .year: .year
    case .all: nil
    }
  }

  /// The window that contains `now`, or nil for all time.
  public func interval(now: Date, calendar: Calendar) -> DateInterval? {
    guard let component else { return nil }
    return calendar.dateInterval(of: component, for: now)
  }

  /// Start of the equal window before this one, or nil for all time.
  public func previousStart(now: Date, calendar: Calendar) -> Date? {
    guard let component, let interval = interval(now: now, calendar: calendar) else { return nil }
    return calendar.date(byAdding: component, value: -1, to: interval.start)
  }
}
