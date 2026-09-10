import XCTest

@testable import TokEngine

final class StatsCalculatorTests: XCTestCase {
  private var calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    calendar.firstWeekday = 2
    return calendar
  }()
  /// Thursday 10 September 2026, 15:30 local.
  private var now: Date { date(2026, 9, 10, 15, 30) }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0)
    -> Date
  {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
  }

  private func turn(
    _ date: Date, words: Int, audio: Double? = nil, latency: Double? = nil, app: String = "Notes",
    success: Bool = true
  ) -> StatsTurn {
    StatsTurn(
      date: date, success: success, words: words, characters: words * 5, audioSeconds: audio,
      totalMs: latency, app: app)
  }

  func testWeekReportAggregatesSuccessesOnly() {
    let turns = [
      turn(date(2026, 9, 7, 9), words: 100, audio: 60, latency: 500, app: "Slack"),
      turn(date(2026, 9, 9, 14), words: 50, audio: 30, latency: 300),
      turn(date(2026, 9, 9, 15), words: 0, audio: 1, success: false),
    ]
    let report = StatsCalculator.report(
      .init(
        range: .week, turns: turns, previousWords: 100, successDays: ["2026-09-07", "2026-09-09"],
        typingWordsPerMinute: 40, now: now, calendar: calendar))
    XCTAssertEqual(report.words, 150)
    XCTAssertEqual(report.dictations, 2)
    XCTAssertEqual(report.attempts, 3)
    XCTAssertEqual(report.characters, 750)
    XCTAssertEqual(report.speakingSeconds, 90)
    XCTAssertEqual(report.latencySeconds, 0.8, accuracy: 0.0001)
    XCTAssertEqual(report.wordsPerMinute!, 100, accuracy: 0.0001)
    XCTAssertEqual(report.typingSeconds, 225)
    XCTAssertEqual(report.savedSeconds, 225 - 90.8, accuracy: 0.0001)
    XCTAssertEqual(report.longestWords, 100)
    XCTAssertEqual(report.averageWords, 75)
    XCTAssertEqual(report.medianLatencyMs, 400)
    XCTAssertEqual(report.wordsChange!, 0.5, accuracy: 0.0001)
    XCTAssertEqual(report.activeDays, 2)
    XCTAssertEqual(report.hours[9], 100)
    XCTAssertEqual(report.hours[14], 50)
    XCTAssertEqual(report.hours[15], 0)
    XCTAssertEqual(report.apps.map(\.name), ["Slack", "Notes"])
    XCTAssertEqual(report.apps.map(\.words), [100, 50])
    XCTAssertEqual(report.bucket, .day)
    XCTAssertEqual(report.series.count, 7)
    XCTAssertEqual(report.series.first?.date, date(2026, 9, 7, 0))
    XCTAssertEqual(report.series.map(\.words), [100, 0, 50, 0, 0, 0, 0])
    XCTAssertEqual(report.series[2].dictations, 1)
    XCTAssertEqual(report.firstDate, turns[0].date)
  }

  func testEmptyInputProducesZerosNotCrashes() {
    let report = StatsCalculator.report(
      .init(
        range: .all, turns: [], previousWords: nil, successDays: [], typingWordsPerMinute: 40,
        now: now, calendar: calendar))
    XCTAssertEqual(report.words, 0)
    XCTAssertNil(report.wordsPerMinute)
    XCTAssertNil(report.averageWords)
    XCTAssertNil(report.wordsChange)
    XCTAssertEqual(report.savedSeconds, 0)
    XCTAssertEqual(report.series.count, 1)
    XCTAssertEqual(report.currentStreakDays, 0)
  }

  func testTodayUsesHourBucketsAndAllTimeSwitchesToMonths() {
    let today = StatsCalculator.report(
      .init(
        range: .today, turns: [turn(date(2026, 9, 10, 8), words: 10)], previousWords: 0,
        successDays: [], typingWordsPerMinute: 40, now: now, calendar: calendar))
    XCTAssertEqual(today.bucket, .hour)
    XCTAssertEqual(today.series.count, 24)
    XCTAssertEqual(today.series[8].words, 10)
    let recent = StatsCalculator.report(
      .init(
        range: .all, turns: [turn(date(2026, 8, 1), words: 10)], previousWords: nil,
        successDays: [], typingWordsPerMinute: 40, now: now, calendar: calendar))
    XCTAssertEqual(recent.bucket, .day)
    XCTAssertEqual(recent.series.count, 41)
    let long = StatsCalculator.report(
      .init(
        range: .all, turns: [turn(date(2025, 11, 20), words: 10)], previousWords: nil,
        successDays: [], typingWordsPerMinute: 40, now: now, calendar: calendar))
    XCTAssertEqual(long.bucket, .month)
    XCTAssertEqual(long.series.count, 11)
    XCTAssertEqual(long.series.first?.date, date(2025, 11, 1, 0))
  }

  func testStreaksCountBackFromTodayOrYesterday() {
    let days = ["2026-09-10", "2026-09-09", "2026-09-08", "2026-09-05", "2026-09-04"]
    let withToday = StatsCalculator.streaks(successDays: days, now: now, calendar: calendar)
    XCTAssertEqual(withToday.current, 3)
    XCTAssertEqual(withToday.best, 3)
    let withoutToday = StatsCalculator.streaks(
      successDays: Array(days.dropFirst()), now: now, calendar: calendar)
    XCTAssertEqual(withoutToday.current, 2)
    XCTAssertEqual(withoutToday.best, 2)
    let broken = StatsCalculator.streaks(
      successDays: ["2026-09-05", "2026-09-04", "2026-09-03", "2026-09-02"], now: now,
      calendar: calendar)
    XCTAssertEqual(broken.current, 0)
    XCTAssertEqual(broken.best, 4)
  }

  func testDayKeyRoundTrips() {
    let key = StatsCalculator.dayKey(for: date(2026, 1, 5, 23, 59), calendar: calendar)
    XCTAssertEqual(key, "2026-01-05")
    XCTAssertEqual(StatsCalculator.date(fromDayKey: key, calendar: calendar), date(2026, 1, 5, 0))
    XCTAssertNil(StatsCalculator.date(fromDayKey: "garbage", calendar: calendar))
  }

  func testRangeWindowsAreCalendarAligned() {
    let week = StatsRange.week.interval(now: now, calendar: calendar)!
    XCTAssertEqual(week.start, date(2026, 9, 7, 0))
    XCTAssertEqual(
      StatsRange.week.previousStart(now: now, calendar: calendar), date(2026, 8, 31, 0))
    XCTAssertEqual(
      StatsRange.month.interval(now: now, calendar: calendar)?.start, date(2026, 9, 1, 0))
    XCTAssertEqual(StatsRange.year.previousStart(now: now, calendar: calendar), date(2025, 1, 1, 0))
    XCTAssertNil(StatsRange.all.interval(now: now, calendar: calendar))
    XCTAssertNil(StatsRange.all.previousStart(now: now, calendar: calendar))
  }
}
