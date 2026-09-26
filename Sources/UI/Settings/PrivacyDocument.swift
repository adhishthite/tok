// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// Opens the bundled PRIVACY.md, the same file the repository carries.
enum PrivacyDocument {
  static var url: URL? { Bundle.main.url(forResource: "PRIVACY", withExtension: "md") }
  static func open() {
    guard let url else { return }
    NSWorkspace.shared.open(url)
  }
}
