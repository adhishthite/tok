import XCTest

func check(
  _ condition: @autoclosure () -> Bool, _ label: String, file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertTrue(condition(), label, file: file, line: line)
}
