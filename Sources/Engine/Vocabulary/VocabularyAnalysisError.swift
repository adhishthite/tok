import Foundation

public enum VocabularyAnalysisError: LocalizedError {
  case noAPIKey
  case historyUnavailable
  case insufficientHistory
  case invalidResponse
  case http(Int)
  public var errorDescription: String? {
    switch self {
    case .noAPIKey: "Add an API key in Settings before requesting suggestions."
    case .historyUnavailable: "Could not read history. Check the history location in Settings."
    case .insufficientHistory: "Save at least five dictations before requesting suggestions."
    case .invalidResponse: "Gemini did not return usable suggestions. Try again later."
    case .http(let status):
      "Gemini returned HTTP \(status). Check your connection and API settings."
    }
  }
}
