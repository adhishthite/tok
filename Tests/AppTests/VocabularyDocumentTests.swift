// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import XCTest

@testable import Tok

@MainActor
final class VocabularyDocumentTests: XCTestCase {
  func testNativeDocumentSaveAndReload() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("vocabulary.txt")
    try "Initial term\n".write(to: url, atomically: true, encoding: .utf8)
    let document = try VocabularyDocument(contentsOf: url, ofType: "public.plain-text")
    XCTAssertFalse(document.isDocumentEdited)
    document.model.contents = "Kubernetes\ncloud code => Claude Code\n"
    XCTAssertTrue(document.isDocumentEdited)
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: url, ofType: "public.plain-text", for: .saveOperation) { error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    XCTAssertFalse(document.isDocumentEdited)
    let loaded = try VocabularyDocument(contentsOf: url, ofType: "public.plain-text")
    XCTAssertEqual(loaded.model.contents, "Kubernetes\ncloud code => Claude Code\n")
    document.close()
    loaded.close()
  }
}
