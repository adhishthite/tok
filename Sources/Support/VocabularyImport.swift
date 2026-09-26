// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum VocabularyImport {
  static func containedURL(path: String, configuration: URL) -> URL? {
    let folder = configuration.deletingLastPathComponent().resolvingSymlinksInPath()
      .standardizedFileURL
    let expanded = NSString(string: path).expandingTildeInPath
    let candidate =
      (expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded) : folder.appendingPathComponent(expanded))
      .resolvingSymlinksInPath().standardizedFileURL
    let root = folder.pathComponents
    guard candidate.pathComponents.count > root.count, candidate.pathComponents.starts(with: root)
    else { return nil }
    return candidate
  }

  static func merging(_ imported: String, into existing: String) -> String {
    var seen = Set(
      existing.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) })
    let additions = imported.components(separatedBy: .newlines).filter {
      let line = $0.trimmingCharacters(in: .whitespaces)
      return !line.isEmpty && seen.insert(line).inserted
    }
    guard !additions.isEmpty else { return existing }
    return existing + (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n")
      + additions.joined(separator: "\n") + "\n"
  }
}
