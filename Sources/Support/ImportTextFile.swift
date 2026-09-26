// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum ImportTextFile {
  static let maximumBytes = 1_048_576

  static func read(_ url: URL) throws -> String {
    let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
    guard properties.isRegularFile == true,
      (properties.fileSize ?? maximumBytes + 1) <= maximumBytes
    else {
      throw CocoaError(.fileReadTooLarge)
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    guard data.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
    guard let text = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    return text
  }
}
