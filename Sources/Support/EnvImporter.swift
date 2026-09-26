// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum EnvImporter {
  static func parse(_ content: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let separator = trimmed.firstIndex(of: "=")
      else { continue }
      let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces)
      var value = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(
        in: .whitespaces)
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value = String(value.dropFirst().dropLast())
      }
      values[key] = value
    }
    return values
  }
  static func read(_ url: URL) throws -> [String: String] {
    parse(try ImportTextFile.read(url))
  }
}
