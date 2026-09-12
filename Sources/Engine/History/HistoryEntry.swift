import Foundation

public struct HistoryEntry: Identifiable, Sendable {
  public let id: Int64
  public let date: Date
  public let text: String
  public let outcome: String
  public let app: String
  public let route: String
  public let model: String
  public let words: Int
  public let cost: Double?
  public let inputTokens: Int?
  public let outputTokens: Int?
  public let metered: Bool
  public let audioSeconds: Double?
  public let eventQueueMs: Double?
  public let captureMs: Double?
  public let firstTokenMs: Double?
  public let apiMs: Double?
  public let injectionMs: Double?
  public let totalMs: Double?
  public let readyMs: Double?
  public let delivery: String
  public let finishMode: String
  public let error: String
  public var postProcessing: PostProcessingMetrics? = nil
  public var transcriptionCost: Double? = nil
  public var captureStartMs: Double? = nil
  public var firstInterimMs: Double? = nil
  public var preview: String { String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ") }
}
