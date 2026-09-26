// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

/// How often one word was dictated.
public struct StatsWordCount: Sendable, Equatable, Identifiable {
  public var word: String
  public var count: Int
  public var id: String { word }
  public init(word: String, count: Int) {
    self.word = word
    self.count = count
  }
}
