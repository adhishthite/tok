// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A dynamic `CodingKey` for `JudgmentValue.object`, whose keys are runtime strings (state
/// field names) rather than a fixed enum. Every string is a valid key, so `init?` never fails.
struct JudgmentCodingKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { nil }
}
