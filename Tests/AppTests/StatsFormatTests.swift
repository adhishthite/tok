import XCTest

@testable import Tok

final class StatsFormatTests: XCTestCase {
  func testDurationsUseWholeUnits() {
    XCTAssertEqual(StatsFormat.duration(0), "0 s")
    XCTAssertEqual(StatsFormat.duration(45.4), "45 s")
    XCTAssertEqual(StatsFormat.duration(90), "1 min")
    XCTAssertEqual(StatsFormat.duration(3600), "1 h")
    XCTAssertEqual(StatsFormat.duration(3725), "1 h 2 min")
    XCTAssertEqual(StatsFormat.duration(-5), "0 s")
    XCTAssertEqual(StatsFormat.duration(.nan), "0 s")
  }

  func testChangeAgainstThePreviousPeriod() {
    XCTAssertEqual(StatsFormat.change(0.18, against: "last week"), "18% more than last week")
    XCTAssertEqual(StatsFormat.change(-0.12, against: "last month"), "12% fewer than last month")
    XCTAssertEqual(StatsFormat.change(0.001, against: "yesterday"), "Same as yesterday")
    XCTAssertNil(StatsFormat.change(nil, against: "yesterday"))
    XCTAssertNil(StatsFormat.change(0.5, against: nil))
  }

  func testRatesAndCounts() {
    XCTAssertEqual(StatsFormat.rate(151.6), "152 wpm")
    XCTAssertEqual(StatsFormat.rate(nil), "Not measured")
    XCTAssertEqual(StatsFormat.count(12480), "12,480")
  }
}
