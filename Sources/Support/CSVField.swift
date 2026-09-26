// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum CSVField {
  static func encode(_ text: String) -> String {
    let safe = text.first.map { "=+-@\t\r".contains($0) } == true ? "'" + text : text
    return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
  }
}
