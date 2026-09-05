import XCTest

@testable import Tok

final class CSVFieldTests: XCTestCase {
  func testQuotesAndFormulaPrefixes() {
    XCTAssertEqual(CSVField.encode("hello,\"world\""), "\"hello,\"\"world\"\"\"")
    XCTAssertEqual(CSVField.encode("=1+1"), "\"'=1+1\"")
    XCTAssertEqual(CSVField.encode("मराठी\ntext"), "\"मराठी\ntext\"")
  }
}
