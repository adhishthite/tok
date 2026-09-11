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
    case .today: "the same elapsed time yesterday"
    case .week: "the same elapsed time last week"
    case .month: "the same elapsed time last month"
    case .year: "the same elapsed time last year"
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

  /// Match the elapsed duration of this period, not the entire previous period.
  /// Omit the comparison if the previous period is shorter than the elapsed duration
  /// (for example, March 31 compared with February). There is no equal window then.
  public func previousComparisonInterval(now: Date, calendar: Calendar) -> DateInterval? {
    guard let current = interval(now: now, calendar: calendar),
      let start = previousStart(now: now, calendar: calendar)
    else { return nil }
    let elapsed = now.timeIntervalSince(current.start)
    guard elapsed > 0, elapsed <= current.start.timeIntervalSince(start) else { return nil }
    return DateInterval(start: start, duration: elapsed)
  }

  /// Start of the calendar period before this one, or nil for all time.
  public func previousStart(now: Date, calendar: Calendar) -> Date? {
    guard let component, let interval = interval(now: now, calendar: calendar) else { return nil }
    return calendar.date(byAdding: component, value: -1, to: interval.start)
  }
}
