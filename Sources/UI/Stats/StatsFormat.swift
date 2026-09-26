// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Number and duration formatting for the stats dashboard.
enum StatsFormat {
  static func count(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }

  /// "45 s", "12 min", "1 h 42 min", or "3 h". Whole units only; this is a summary.
  static func duration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0 s" }
    let whole = Int(seconds.rounded())
    switch whole {
    case ..<60: return "\(whole) s"
    case ..<3600: return "\(whole / 60) min"
    default:
      let hours = whole / 3600
      let minutes = (whole % 3600) / 60
      return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
    }
  }

  static func rate(_ wordsPerMinute: Double?) -> String {
    guard let wordsPerMinute, wordsPerMinute.isFinite else { return "Not measured" }
    return "\(Int(wordsPerMinute.rounded())) wpm"
  }

  static func decimal(_ value: Double, digits: Int = 1) -> String {
    value.formatted(.number.precision(.fractionLength(0...digits)))
  }

  /// "18% more than last week", "12% fewer than last week", or "Same as last week".
  static func change(_ fraction: Double?, against period: String?) -> String? {
    guard let fraction, let period, fraction.isFinite else { return nil }
    let percent = Int((abs(fraction) * 100).rounded())
    if percent == 0 { return "Same as \(period)" }
    return "\(percent)% \(fraction > 0 ? "more" : "fewer") than \(period)"
  }
}
