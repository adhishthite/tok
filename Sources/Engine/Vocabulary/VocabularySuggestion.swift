// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

public struct VocabularySuggestion: Identifiable, Sendable {
  public let line: String
  public let reason: String
  public var id: String { line.lowercased() }
}
