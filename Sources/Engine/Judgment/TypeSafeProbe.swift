import Foundation

/// The Settings "Test and save" probe for the TypeSafe key, mirroring `ServiceProbe` for
/// Gemini: the lightest authenticated call the service offers (`GET /v1/models`), run directly
/// from an `async` Settings action rather than through `JudgmentService`'s gate (which is
/// built for the running engine, not a one-off UI check).
public enum TypeSafeProbe {
  static let timeoutSeconds = 10.0

  public static func validate(apiKey: String) async throws {
    let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw failure("Enter a TypeSafe API key first.")
    }
    var request = URLRequest(url: TypeSafeClient.modelsURL)
    request.httpMethod = "GET"
    request.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = timeoutSeconds
    request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    let response: URLResponse
    do {
      (_, response) = try await URLSession.shared.data(for: request)
    } catch let error as URLError {
      try Task.checkCancellation()
      throw failure(message(for: error))
    }
    try Task.checkCancellation()
    guard let http = response as? HTTPURLResponse else {
      throw failure("TypeSafe is unavailable right now.")
    }
    guard (200...299).contains(http.statusCode) else {
      throw failure(message(forStatus: http.statusCode))
    }
  }

  private static func message(forStatus status: Int) -> String {
    switch status {
    case 401, 403: return "The TypeSafe API key was rejected. Check the key and try again."
    case 429: return "Rate limited. Try again in a minute."
    case 500...599: return "TypeSafe is unavailable right now."
    default: return "TypeSafe could not verify the key. Try again."
    }
  }

  private static func message(for error: URLError) -> String {
    switch error.code {
    case .timedOut: return "TypeSafe did not respond in time. Try again."
    default: return "No network connection."
    }
  }

  private static func failure(_ message: String) -> NSError {
    NSError(domain: "Tok.Setup", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
