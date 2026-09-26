// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Observation
import TokEngine

@MainActor
@Observable
final class VocabularyEditorModel {
  var contents = "" { didSet { if contents != oldValue { didEdit?() } } }
  var suggestions: [VocabularySuggestion] = []
  var selected: Set<String> = []
  var analyzing = false
  var message: String?
  @ObservationIgnored var didEdit: (() -> Void)?
}
