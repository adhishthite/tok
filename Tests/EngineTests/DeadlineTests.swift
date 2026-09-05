import XCTest

@testable import TokEngine

final class DeadlineTests: XCTestCase {
  func testReferenceDeadlineBounds() {
    for timeout in [-10.0, 0, 2.5, 4, 100] {
      let budget = TurnDeadline.budget(fallbackTimeout: timeout)
      XCTAssertGreaterThanOrEqual(budget, 10)
      XCTAssertLessThanOrEqual(budget, 30)
      for elapsed in [0.0, 2, 15, 40] {
        XCTAssertEqual(
          TurnDeadline.remaining(budget: budget, elapsed: elapsed), max(0, budget - elapsed))
      }
    }
  }
}
