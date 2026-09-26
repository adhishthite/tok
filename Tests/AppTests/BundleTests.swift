// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Tok

final class BundleTests: XCTestCase {
  func testAppHasItsOwnPermissionIdentity() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.adhishthite.tok")
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    let microphoneReason =
      Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") as? String
    XCTAssertFalse(microphoneReason?.isEmpty ?? true)
  }

  func testBundleCarriesLicenseTextsForTheAboutPane() {
    for name in ["Tok-LICENSE", "Sparkle-LICENSE", "Attributions"] {
      XCTAssertNotNil(Bundle.main.url(forResource: name, withExtension: "txt"), name)
    }
    let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
    XCTAssertEqual(copyright?.contains("Adhish Thite"), true)
    XCTAssertNotNil(Bundle.main.url(forResource: "PRIVACY", withExtension: "md"))
    XCTAssertFalse(BuildIdentity.version.isEmpty)
    XCTAssertTrue(BuildIdentity.report.hasPrefix("Tok "))
  }
}
