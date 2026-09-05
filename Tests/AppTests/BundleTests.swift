import XCTest

final class BundleTests: XCTestCase {
  func testAppHasItsOwnPermissionIdentity() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.adhishthite.tok")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    let microphoneReason =
      Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
    XCTAssertFalse(microphoneReason?.isEmpty ?? true)
  }
}
