import Foundation

public enum ServiceProbe {
  /// The lightest authenticated call the service offers. Validating used to open a full live
  /// session and wait up to twelve seconds for setupComplete, which could not tell a bad key
  /// from a bad network and reported both with one message. This is the same endpoint the
  /// engine already warms, so a success here is the same access the engine needs.
  static let probeURLString = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
  static let timeoutSeconds = 10.0

  public static func validate(configuration: EngineConfiguration) async throws {
    guard !configuration.geminiApiKey.isEmpty else {
      throw NSError(
        domain: "Tok.Setup", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Enter an API key first."])
    }
    guard let url = URL(string: probeURLString) else {
      throw failure(code: 2, message: "Could not reach Gemini. Try again.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(configuration.geminiApiKey, forHTTPHeaderField: "x-goog-api-key")
    request.timeoutInterval = timeoutSeconds
    // A cached 200 from an earlier key would validate a key that was never sent.
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

    let response: URLResponse
    do {
      (_, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
      try Task.checkCancellation()
      throw failure(code: 3, message: message(for: error))
    }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw failure(code: 4, message: "Gemini is unavailable right now.")
    }
    if let problem = message(forStatus: http.statusCode) {
      throw failure(code: http.statusCode, message: problem)
    }
  }

  /// nil means the key works. Every other status maps to one short, actionable line.
  static func message(forStatus status: Int) -> String? {
    switch status {
    case 200...299: return nil
    case 400, 401, 403: return "The API key was rejected. Check the key and try again."
    case 429: return "Rate limited. Try again in a minute."
    case 500...599: return "Gemini is unavailable right now."
    default: return "Gemini could not verify the key. Try again."
    }
  }

  /// Transport failures are a local network problem far more often than a key problem, so
  /// they never accuse the key.
  static func message(for error: URLError) -> String {
    switch error.code {
    case .timedOut: return "Gemini did not respond in time. Try again."
    default: return "No network connection."
    }
  }

  private static func failure(code: Int, message: String) -> NSError {
    NSError(domain: "Tok.Setup", code: code, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
