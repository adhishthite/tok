import Foundation

/// Everything the stats dashboard shows for one range, computed from the stats database.
public struct StatsReport: Sendable, Equatable {
  public var range: StatsRange
  public var bucket: StatsBucket
  /// The typing speed the time-saved estimate assumes.
  public var typingWordsPerMinute: Int
  public var words = 0
  /// Words in the matching elapsed window of the previous period, or nil if unavailable.
  public var previousWords: Int? = nil
  /// Successful dictations, the only ones that produced words.
  public var dictations = 0
  /// Every recorded turn, including empty and failed ones.
  public var attempts = 0
  public var characters = 0
  public var speakingSeconds = 0.0
  /// Key release to delivery, summed over successful dictations.
  public var latencySeconds = 0.0
  public var longestWords = 0
  public var medianLatencyMs: Double? = nil
  public var activeDays = 0
  public var currentStreakDays = 0
  public var bestStreakDays = 0
  public var firstDate: Date? = nil
  public var series: [StatsSeriesPoint] = []
  /// Words by local hour of day, 24 entries.
  public var hours = [Int](repeating: 0, count: 24)
  public var apps: [StatsAppShare] = []
  public var topWords: [StatsWordCount] = []
  public var rareWords: [StatsWordCount] = []
  public var distinctWords = 0

  public init(range: StatsRange, bucket: StatsBucket, typingWordsPerMinute: Int) {
    self.range = range
    self.bucket = bucket
    self.typingWordsPerMinute = typingWordsPerMinute
  }

  public static func empty(_ range: StatsRange, typingWordsPerMinute: Int = 40) -> StatsReport {
    StatsReport(
      range: range, bucket: StatsBucket.forRange(range, spanDays: 0),
      typingWordsPerMinute: typingWordsPerMinute)
  }

  public var wordsPerMinute: Double? {
    speakingSeconds > 0 && words > 0 ? Double(words) / (speakingSeconds / 60) : nil
  }
  /// How long the same words would take to type at the configured speed.
  public var typingSeconds: Double {
    Double(words) / Double(max(1, typingWordsPerMinute)) * 60
  }
  /// Speaking plus waiting for delivery.
  public var spentSeconds: Double { speakingSeconds + latencySeconds }
  public var savedSeconds: Double { max(0, typingSeconds - spentSeconds) }
  public var averageWords: Double? { dictations > 0 ? Double(words) / Double(dictations) : nil }
  /// Fractional change against the previous window, or nil when there is nothing to compare.
  public var wordsChange: Double? {
    guard let previousWords, previousWords > 0 else { return nil }
    return Double(words - previousWords) / Double(previousWords)
  }
}
