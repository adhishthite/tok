import Foundation

enum RESTResponse {
  static func dailyQuotaError() -> NSError {
    NSError(
      domain: "GeminiAPI", code: 429,
      userInfo: [
        NSLocalizedDescriptionKey: "Daily Gemini quota reached. Try again after your quota resets."
      ])
  }

  static func decode(_ data: Data) throws -> [String: Any] {
    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw NSError(
        domain: "GeminiAPI", code: -5,
        userInfo: [
          NSLocalizedDescriptionKey: "Gemini returned an unreadable response. Try again."
        ])
    }
    if let failure = json["error"] as? [String: Any] {
      throw error(code: failure["code"] as? Int ?? -1)
    }
    return json
  }

  static func error(code: Int) -> NSError {
    let message: String
    switch code {
    case 400: message = "Gemini rejected the request. Check the API key and model in Tok Settings."
    case 401, 403: message = "API key rejected. Review the Gemini connection in Tok Settings."
    case 404: message = "Model unavailable. Review the model in Tok Settings."
    case 429: message = "Too many requests. Try again shortly."
    case 500...599: message = "Gemini is temporarily unavailable. Try again."
    default: message = "Gemini could not finish this request. Try again."
    }
    return NSError(domain: "GeminiAPI", code: code, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
