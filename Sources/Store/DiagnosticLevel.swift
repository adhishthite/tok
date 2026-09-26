// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum DiagnosticLevel: String {
  case info = "Info"
  case warning = "Warning"
  case error = "Error"
  case debug = "Debug"
  var isIssue: Bool { self == .warning || self == .error }
  var symbol: String {
    switch self {
    case .info: "info.circle"
    case .warning: "exclamationmark.triangle"
    case .error: "xmark.octagon"
    case .debug: "ant"
    }
  }
}
