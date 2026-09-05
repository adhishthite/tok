public struct HistoryStatistics: Sendable {
  public let count: Int
  public let words: Int
  public let cost: Double
  public let medianMs: Double?
  public let p95Ms: Double?
  public static let empty = HistoryStatistics(
    count: 0, words: 0, cost: 0, medianMs: nil, p95Ms: nil)
}
