import Foundation

/// Totals for one bucket of the words-over-time chart.
public struct StatsSeriesPoint: Sendable, Equatable, Identifiable {
  public var date: Date
  public var words: Int
  public var dictations: Int
  public var speakingSeconds: Double
  public var id: Date { date }
  public var wordsPerMinute: Double? {
    speakingSeconds > 0 && words > 0 ? Double(words) / (speakingSeconds / 60) : nil
  }
  public init(date: Date, words: Int, dictations: Int, speakingSeconds: Double) {
    self.date = date
    self.words = words
    self.dictations = dictations
    self.speakingSeconds = speakingSeconds
  }
}
