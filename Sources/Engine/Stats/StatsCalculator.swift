// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pure aggregation over rows the stats repository read. No SQLite, so tests can
/// check every number without a database.
enum StatsCalculator {
  struct Input {
    var range: StatsRange
    /// Turns inside the range, oldest first.
    var turns: [StatsTurn]
    var previousWords: Int?
    /// Day keys with at least one successful dictation, all time.
    var successDays: [String]
    var topWords: [StatsWordCount] = []
    var rareWords: [StatsWordCount] = []
    var distinctWords = 0
    var typingWordsPerMinute: Int
    var now: Date
    var calendar: Calendar
  }

  static let seriesLimit = 400

  static func report(_ input: Input) -> StatsReport {
    let calendar = input.calendar
    let successes = input.turns.filter(\.success)
    let firstDate = input.turns.first?.date
    let spanDays =
      firstDate.map { calendar.dateComponents([.day], from: $0, to: input.now).day ?? 0 } ?? 0
    var report = StatsReport(
      range: input.range, bucket: StatsBucket.forRange(input.range, spanDays: spanDays),
      typingWordsPerMinute: input.typingWordsPerMinute)
    report.attempts = input.turns.count
    report.dictations = successes.count
    report.previousWords = input.previousWords
    report.firstDate = firstDate
    report.topWords = input.topWords
    report.rareWords = input.rareWords
    report.distinctWords = input.distinctWords

    var latencies: [Double] = []
    var apps: [String: StatsAppShare] = [:]
    var days: Set<String> = []
    for turn in successes {
      report.words += turn.words
      report.characters += turn.characters
      report.speakingSeconds += turn.audioSeconds ?? 0
      report.latencySeconds += (turn.totalMs ?? 0) / 1000
      report.longestWords = max(report.longestWords, turn.words)
      if let total = turn.totalMs, total.isFinite { latencies.append(total) }
      report.hours[calendar.component(.hour, from: turn.date)] += turn.words
      let name = turn.app.isEmpty ? "Unknown" : turn.app
      var share = apps[name] ?? StatsAppShare(name: name, words: 0, dictations: 0)
      share.words += turn.words
      share.dictations += 1
      apps[name] = share
      days.insert(dayKey(for: turn.date, calendar: calendar))
    }
    latencies.sort()
    report.medianLatencyMs = percentile(latencies, 0.5)
    report.activeDays = days.count
    report.apps = Array(
      apps.values.sorted { ($0.words, $0.name) > ($1.words, $1.name) }.prefix(8))
    report.series = series(
      successes, range: input.range, bucket: report.bucket, now: input.now, calendar: calendar)
    let streaks = streaks(successDays: input.successDays, now: input.now, calendar: calendar)
    report.currentStreakDays = streaks.current
    report.bestStreakDays = streaks.best
    return report
  }

  /// One point per bucket across the whole window, zeros included, so the chart keeps
  /// its shape on quiet days.
  static func series(
    _ turns: [StatsTurn], range: StatsRange, bucket: StatsBucket, now: Date, calendar: Calendar
  ) -> [StatsSeriesPoint] {
    let window = range.interval(now: now, calendar: calendar)
    let start = window?.start ?? turns.first?.date ?? now
    let last = window.map { $0.end - 1 } ?? now
    guard let firstBucket = calendar.dateInterval(of: bucket.component, for: start)?.start,
      let lastBucket = calendar.dateInterval(of: bucket.component, for: max(start, last))?.start
    else { return [] }
    var totals: [Date: StatsSeriesPoint] = [:]
    for turn in turns {
      guard let key = calendar.dateInterval(of: bucket.component, for: turn.date)?.start else {
        continue
      }
      var point =
        totals[key] ?? StatsSeriesPoint(date: key, words: 0, dictations: 0, speakingSeconds: 0)
      point.words += turn.words
      point.dictations += 1
      point.speakingSeconds += turn.audioSeconds ?? 0
      totals[key] = point
    }
    var points: [StatsSeriesPoint] = []
    var cursor = firstBucket
    while cursor <= lastBucket, points.count < seriesLimit {
      points.append(
        totals[cursor]
          ?? StatsSeriesPoint(date: cursor, words: 0, dictations: 0, speakingSeconds: 0))
      guard let next = calendar.date(byAdding: bucket.component, value: 1, to: cursor) else {
        break
      }
      cursor = next
    }
    return points
  }

  /// Current streak counts back from today, or from yesterday when today has no
  /// dictation yet, so a streak is not shown as broken before the day is over.
  static func streaks(successDays: [String], now: Date, calendar: Calendar) -> (
    current: Int, best: Int
  ) {
    let days = Set(successDays.compactMap { date(fromDayKey: $0, calendar: calendar) })
    guard !days.isEmpty else { return (0, 0) }
    let today = calendar.startOfDay(for: now)
    var cursor = days.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
    var current = 0
    while days.contains(cursor) {
      current += 1
      cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
    }
    var best = 0
    var run = 0
    var previous: Date?
    for day in days.sorted() {
      if let previous, calendar.dateComponents([.day], from: previous, to: day).day == 1 {
        run += 1
      } else {
        run = 1
      }
      best = max(best, run)
      previous = day
    }
    return (current, best)
  }

  /// Local calendar day as a sortable key, such as 2026-09-10.
  static func dayKey(for date: Date, calendar: Calendar) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
    let parts = key.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return nil }
    return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
  }

  static func percentile(_ sorted: [Double], _ quantile: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let position = Double(sorted.count - 1) * quantile
    let lower = Int(position)
    let upper = min(sorted.count - 1, Int(position.rounded(.up)))
    return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
  }
}
