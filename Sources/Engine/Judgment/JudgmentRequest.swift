// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The request body for TypeSafe's `/v1/systemone` endpoint.
struct JudgmentRequest: Encodable {
  let model: String
  let state: JudgmentValue
  let questions: [String: JudgmentQuestion]
}
