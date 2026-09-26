// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A JSON value for a TypeSafe request's `state`, which the API accepts as a string, object,
/// or array (see docs/api.md). Nested fields inside an object or array may also be numbers or
/// booleans, so the full case set lives here rather than only at the top level.
enum JudgmentValue: Encodable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case array([JudgmentValue])
  case object([String: JudgmentValue])

  func encode(to encoder: Encoder) throws {
    switch self {
    case .string(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .number(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .bool(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .array(let values):
      var container = encoder.unkeyedContainer()
      for value in values { try container.encode(value) }
    case .object(let values):
      var container = encoder.container(keyedBy: JudgmentCodingKey.self)
      for (key, value) in values {
        try container.encode(value, forKey: JudgmentCodingKey(stringValue: key))
      }
    }
  }
}
