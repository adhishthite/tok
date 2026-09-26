// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import TokEngine

final class WindowSearchTests: XCTestCase {
  func testTenThousandIndependentWindowCases() {
    var seed: UInt64 = 20_260_905
    func next(_ limit: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 32) % UInt64(limit))
    }
    let alphabet = ["", "a", "b", "c", "d"]
    for _ in 0..<10000 {
      let count = 1 + next(19)
      let pasted = (0..<count).map { _ in alphabet[next(alphabet.count)] }
      let field = (0..<(count + 1 + next(79))).map { _ in alphabet[next(alphabet.count)] }
      let target = Set(pasted.filter { !$0.isEmpty })
      var bestScore = 0.0
      var expected: [String] = []
      for start in 0...(field.count - count) {
        let candidate = Array(field[start..<start + count])
        let words = Set(candidate.filter { !$0.isEmpty })
        let score =
          target.isEmpty || words.isEmpty
          ? 0 : Double(target.intersection(words).count) / Double(target.union(words).count)
        if score > bestScore {
          bestScore = score
          expected = candidate
        }
      }
      if bestScore < 0.5 { expected = [] }
      XCTAssertEqual(CorrectionWatcher.bestWindow(pasted: pasted, field: field), expected)
    }
  }
}
