import Foundation

public struct PostProcessingMetrics: Sendable {
  public var status: String
  public var model: String? = nil
  public var latencyMs: Double? = nil
  public var inputTokens: Int? = nil
  public var outputTokens: Int? = nil
  public var thinkingTokens: Int? = nil
  public var costUSD: Double? = nil
  public var errorCode: String? = nil
  public var appContextUsed = false

  public static let off = PostProcessingMetrics(status: "off", costUSD: 0)

  public var displayStatus: String {
    switch status {
    case "off": "Off"
    case "completed": "Applied"
    case "timed_out": "Timed out; original used"
    case "skipped": "Skipped; original used"
    default: "Failed; original used"
    }
  }

  public var failureDescription: String? {
    switch errorCode {
    case "timeout": "Cleanup reached its time limit."
    case "input_limit": "The dictation is too long for the cleanup pass."
    case "invalid_configuration", "http_400": "Review the cleanup model in Settings."
    case "http_401", "http_403": "Review the Gemini API key and model access."
    case "http_404": "The cleanup model is unavailable."
    case "http_429": "Gemini is limiting requests."
    case "network": "The cleanup request could not connect."
    case "invalid_response", "empty_response": "Gemini returned an incomplete or unusable result."
    case nil: nil
    default: "Gemini could not complete cleanup."
    }
  }
}
