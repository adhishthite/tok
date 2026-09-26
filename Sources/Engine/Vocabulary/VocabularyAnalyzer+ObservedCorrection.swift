// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

extension VocabularyAnalyzer {
  struct ObservedCorrection: Sendable {
    let ts: Double
    let wrong: String
    let right: String
    let app: String
  }
}
