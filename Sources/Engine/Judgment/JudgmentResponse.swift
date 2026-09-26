// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The decoded body of a TypeSafe `/v1/systemone` response.
struct JudgmentResponse: Decodable {
  let model: String
  let answers: [String: JudgmentAnswer]
  let usage: Usage

  struct Usage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    private enum CodingKeys: String, CodingKey {
      case inputTokens = "input_tokens"
      case outputTokens = "output_tokens"
    }
  }
}
