// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One answer from TypeSafe's `/v1/systemone` endpoint, decoded by its `type` discriminator.
/// Only the fields Tok consumes are decoded; `probabilities` and `legend` stay on the wire
/// (extra JSON keys are simply ignored by a keyed container).
enum JudgmentAnswer: Decodable {
  case noul(Double)
  case choice(String, confidence: Double?)
  case score(Double, confidence: Double?)
  case unknown

  private enum CodingKeys: String, CodingKey { case type, noul, choice, score, confidence }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
    switch type {
    case "noul":
      self = .noul(try container.decode(Double.self, forKey: .noul))
    case "choice":
      self = .choice(
        try container.decode(String.self, forKey: .choice),
        confidence: try container.decodeIfPresent(Double.self, forKey: .confidence))
    case "score":
      self = .score(
        try container.decode(Double.self, forKey: .score),
        confidence: try container.decodeIfPresent(Double.self, forKey: .confidence))
    default:
      self = .unknown
    }
  }
}
