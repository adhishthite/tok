import XCTest

@testable import Tok

@MainActor
final class HistoryLoadingTests: XCTestCase {
  func testOpeningHistoryDoesNotPresentEmptyStateWhileQueryIsPending() {
    let store = HistoryViewStore()
    store.configure(
      path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
    store.visible = true

    store.reload()

    XCTAssertTrue(store.loading)
    XCTAssertTrue(store.entries.isEmpty)
  }

  func testSearchDoesNotPresentNoMatchesDuringDebounce() {
    let store = HistoryViewStore()
    store.configure(
      path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path)
    store.visible = true

    store.search = "synthetic search"

    XCTAssertTrue(store.loading)
    XCTAssertTrue(store.entries.isEmpty)
  }
}
