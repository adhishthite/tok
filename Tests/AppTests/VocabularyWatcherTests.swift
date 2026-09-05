import Foundation
import XCTest

@testable import Tok

final class VocabularyWatcherTests: XCTestCase {
  func testAtomicReplacementIsObserved() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("vocabulary.txt")
    try "Initial\n".write(to: url, atomically: true, encoding: .utf8)
    let changed = expectation(description: "Atomic vocabulary replacement")
    let watcher = VocabularyWatcher(url: url) { changed.fulfill() }
    XCTAssertNotNil(watcher)
    defer { watcher?.stop() }
    try "New vocabulary term\n".write(to: url, atomically: true, encoding: .utf8)
    await fulfillment(of: [changed], timeout: 3)
  }
}
