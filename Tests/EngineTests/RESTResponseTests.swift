// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import TokEngine

final class RESTResponseTests: XCTestCase {
  func testMalformedResponseDoesNotExposeItsContents() {
    XCTAssertThrowsError(try RESTResponse.decode(Data("Private fixture response".utf8))) {
      XCTAssertFalse($0.localizedDescription.contains("Private fixture"))
      XCTAssertEqual(($0 as NSError).code, -5)
    }
  }

  func testProviderErrorsKeepStatusWithoutCopyingPrivateMessage() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "error": ["code": 403, "message": "Private fixture response"]
    ])
    XCTAssertThrowsError(try RESTResponse.decode(data)) {
      XCTAssertEqual(($0 as NSError).code, 403)
      XCTAssertTrue($0.localizedDescription.contains("Tok Settings"))
      XCTAssertFalse($0.localizedDescription.contains("Private fixture"))
    }
  }

  func testSuccessfulEnvelopePassesThroughUnchanged() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "candidates": [["content": ["parts": [["text": "Hello"]]]]]
    ])
    let decoded = try RESTResponse.decode(data)
    XCTAssertNotNil(decoded["candidates"])
    for code in [400, 401, 403, 404] {
      XCTAssertTrue(RESTResponse.error(code: code).localizedDescription.contains("Tok Settings"))
    }
  }
}
