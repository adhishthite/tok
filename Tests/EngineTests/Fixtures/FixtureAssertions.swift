// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

func check(
  _ condition: @autoclosure () -> Bool, _ label: String, file: StaticString = #filePath,
  line: UInt = #line
) {
  XCTAssertTrue(condition(), label, file: file, line: line)
}
