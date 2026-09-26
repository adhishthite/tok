// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum ServiceProbe {
  /// The lightest authenticated call the service offers. Validating used to open a full live
  /// session and wait up to twelve seconds for setupComplete, which could not tell a bad key
  /// from a bad network and reported both with one message. This is the same endpoint the
  /// engine already warms, so a success here is the same access the engine needs.
  static let probeURLString = "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1"
  static let timeoutSeconds = 10.0

  /// models.get for one configured model: the cheapest call that fails for a mistyped,
  /// retired, or inaccessible model. The key check alone would pass such a model and the
  /// first real dictation would then fail to open its live session. A name with a "models/"
  /// prefix or any other slash is refused: the runtime clients prepend "models/" themselves,
  /// so accepting it here would pass a name that fails at dictation time.
  static func modelURL(for model: String) -> URL? {
    guard !model.isEmpty, model.allSatisfy({ $0.isLetter || $0.isNumber || "-._".contains($0) })
    else { return nil }
    return URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model)")
  }

  public static func validate(configuration: EngineConfiguration) async throws {
    guard !configuration.geminiApiKey.isEmpty else {
      throw NSError(
        domain: "Tok.Setup", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Enter an API key first."])
    }
    guard let url = URL(string: probeURLString) else {
      throw failure(code: 2, message: "Could not reach Gemini. Try again.")
    }
    // Key first, so a bad key is reported as a bad key and not as a missing model.
    let keyStatus = try await status(of: url, apiKey: configuration.geminiApiKey)
    if let problem = message(forStatus: keyStatus) {
      throw failure(code: keyStatus, message: problem)
    }
    // Then each model the engine will actually call, in the order a dictation uses them. A
    // REST-only configuration never opens a live session, so its live model is not checked.
    for model in modelsToProbe(configuration) {
      guard let modelURL = modelURL(for: model) else {
        throw failure(code: 5, message: "The model name \"\(model)\" is not valid.")
      }
      let modelStatus = try await status(of: modelURL, apiKey: configuration.geminiApiKey)
      if let problem = message(forModel: model, status: modelStatus) {
        throw failure(code: modelStatus, message: problem)
      }
    }
  }

  static func modelsToProbe(_ configuration: EngineConfiguration) -> [String] {
    var models: [String] = []
    if configuration.enableLiveWebSocket { models.append(configuration.geminiLiveModel) }
    models.append(configuration.geminiModel)
    return models.filter { !$0.isEmpty }
  }

  private static func status(of url: URL, apiKey: String) async throws -> Int {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
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
    return http.statusCode
  }

  /// nil means the model exists for this key. 403 and 404 name the model, because the key
  /// itself already passed.
  static func message(forModel model: String, status: Int) -> String? {
    switch status {
    case 200...299: return nil
    case 403, 404: return "The model \"\(model)\" is not available for this key."
    default: return message(forStatus: status)
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
