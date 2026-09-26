// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

enum ConnectionCheckStatus {
  case unchecked, checking, connected, failed

  var label: String {
    switch self {
    case .unchecked: "Not checked"
    case .checking: "Checking…"
    case .connected: "Connected"
    case .failed: "Not connected"
    }
  }

  var symbol: String {
    switch self {
    case .unchecked: "questionmark.circle"
    case .checking: "arrow.triangle.2.circlepath"
    case .connected: "checkmark.circle.fill"
    case .failed: "xmark.circle.fill"
    }
  }

  var color: Color {
    switch self {
    case .unchecked, .checking: .secondary
    case .connected: .green
    case .failed: .red
    }
  }
}
