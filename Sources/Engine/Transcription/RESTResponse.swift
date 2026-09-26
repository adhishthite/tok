// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

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

  /// The answer stopped before the model finished, so the transcript on hand is a fragment.
  static func truncatedError() -> NSError {
    NSError(
      domain: "GeminiAPI", code: -20,
      userInfo: [NSLocalizedDescriptionKey: "Transcription was cut short. Nothing pasted."])
  }

  /// The service refused the audio or the answer. The service's reason enum stays in the
  /// log; the HUD line stays short.
  static func blockedError() -> NSError {
    NSError(
      domain: "GeminiAPI", code: -21,
      userInfo: [
        NSLocalizedDescriptionKey: "Transcription blocked by the service. Nothing pasted."
      ])
  }

  /// The recording is longer than one inline request can carry (see
  /// GeminiRestClient.maxInlineAudioBytes).
  static func recordingTooLongError() -> NSError {
    NSError(
      domain: "GeminiAPI", code: -22,
      userInfo: [
        NSLocalizedDescriptionKey: "Recording too long for the backup route. Nothing pasted."
      ])
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
