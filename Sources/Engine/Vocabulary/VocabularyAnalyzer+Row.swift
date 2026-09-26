// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

extension VocabularyAnalyzer {
  struct Row: Sendable {
    let ts: Double
    let app: String
    let text: String
  }
}
