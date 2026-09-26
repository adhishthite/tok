// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One bounded reader for `generateContent` response envelopes, shared by the REST
/// transcription fallback and by post-processing. The two routes used to read the envelope
/// differently: the REST client took `parts.first` and never looked at finishReason, so a
/// truncated or policy-blocked answer reached the paste path as if it were complete.
enum GenerateContentDecoder {
  enum Outcome: Equatable {
    /// Joined text of every non-thought part of the first candidate.
    case text(String)
    /// A readable envelope that carries no usable text.
    case empty
    /// The service withheld the answer. `reason` is the service's own enum name.
    case blocked(reason: String)
    /// The answer stopped early, so the text on hand is incomplete and must not be used.
    case truncated
    /// No candidates and no stated reason: not an envelope we can read.
    case malformed
  }

  /// Finish reasons that mean the service refused the content rather than finishing it.
  private static let blockingReasons: Set<String> = [
    "SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "IMAGE_SAFETY",
  ]

  static func decode(_ json: [String: Any]) -> Outcome {
    // promptFeedback records a block decided before generation started. In that case there
    // is usually no candidate at all, so it has to be read before the candidate list.
    if let feedback = json["promptFeedback"] as? [String: Any],
      let reason = feedback["blockReason"] as? String, !reason.isEmpty
    {
      return .blocked(reason: reason)
    }
    guard let candidate = (json["candidates"] as? [[String: Any]])?.first else {
      return .malformed
    }
    let parts = (candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
    // Thought parts are the model's reasoning, never the answer. Joining every remaining
    // text part keeps an answer whole when the service splits it across parts.
    let text =
      parts
      .filter { $0["thought"] as? Bool != true }
      .compactMap { $0["text"] as? String }
      .joined()
    let finishReason = (candidate["finishReason"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    switch finishReason {
    case "STOP":
      return text.isEmpty ? .empty : .text(text)
    case nil:
      // Both callers use non-streaming requests, where every finished candidate states a
      // reason. No reason means the envelope is incomplete, so its text must not be pasted.
      return text.isEmpty ? .malformed : .truncated
    case "MAX_TOKENS":
      return .truncated
    case let reason? where blockingReasons.contains(reason):
      return .blocked(reason: reason)
    default:
      // Any other stated reason is a stop we do not model. Partial text is still partial.
      return text.isEmpty ? .empty : .truncated
    }
  }
}
