// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The only value shapes a usage metric may carry. Free text is not one of them.
public enum MetricValue: Equatable, Sendable {
  case string(String)
  case int(Int)
  case bool(Bool)
  case null

  var json: Any {
    switch self {
    case .string(let value): value
    case .int(let value): value
    case .bool(let value): value
    case .null: NSNull()
    }
  }
}
