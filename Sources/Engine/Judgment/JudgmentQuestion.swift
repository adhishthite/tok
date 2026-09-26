// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One question sent to TypeSafe's `/v1/systemone` endpoint. Question ids are the caller's
/// dictionary keys (`JudgmentService.ask(questions:)`); they are for code only and are never
/// shown to the model, so `instructions` must carry the full meaning on its own.
enum JudgmentQuestion: Encodable {
  /// A yes/no judgment as a probability in 0...1. `criteria` is optional; when present it
  /// should give a one-line true/false example each.
  case noul(instructions: String, criteria: [String: String]? = nil)
  /// A pick-one judgment. `criteria` maps each option name to a short description.
  case choice(instructions: String, criteria: [String: String])
  /// A graded judgment. `criteria` is an ordered array of 2 to 10 level descriptions, lowest
  /// to highest.
  case score(instructions: String, criteria: [String])

  private enum CodingKeys: String, CodingKey { case type, instructions, criteria }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .noul(let instructions, let criteria):
      try container.encode("noul", forKey: .type)
      try container.encode(instructions, forKey: .instructions)
      if let criteria { try container.encode(criteria, forKey: .criteria) }
    case .choice(let instructions, let criteria):
      try container.encode("choice", forKey: .type)
      try container.encode(instructions, forKey: .instructions)
      try container.encode(criteria, forKey: .criteria)
    case .score(let instructions, let criteria):
      try container.encode("score", forKey: .type)
      try container.encode(instructions, forKey: .instructions)
      try container.encode(criteria, forKey: .criteria)
    }
  }
}
