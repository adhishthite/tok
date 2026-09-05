import XCTest

@testable import Tok
@testable import TokEngine

@MainActor
final class StoreTests: XCTestCase {
  func testStateTracksEngineEventsWithoutStartingHardware() {
    let store = DictationStore()
    store.engineDidEmit(.ready)
    XCTAssertEqual(store.status, .ready)
    store.engineDidEmit(.listening(lockAfter: 15))
    XCTAssertEqual(store.status, .listening)
    store.engineDidEmit(.locked)
    XCTAssertEqual(store.status, .locked)
    store.engineDidEmit(.processing)
    XCTAssertEqual(store.status, .processing)
    store.engineDidEmit(.microphoneReleased)
    XCTAssertEqual(store.status, .microphoneReleased)
    store.engineDidEmit(.failure("Test failure"))
    XCTAssertEqual(store.message, "Test failure")
  }

  func testDiagnosticsRemainBounded() {
    let store = DictationStore()
    for index in 0..<350 { store.engineDidEmit(.diagnostic("Test line \(index)")) }
    XCTAssertEqual(store.diagnostics.count, 300)
    XCTAssertEqual(store.diagnostics.first?.message, "Test line 50")
    XCTAssertEqual(store.diagnostics.last?.message, "Test line 349")
  }

  func testImporterPreservesQuotedValuesAndEmptySettings() {
    let parsed = EnvImporter.parse(
      """
      # Comment
      HOTKEY=FN
      CUSTOM_VOCABULARY="a=b, c#d"
      INPUT_DEVICE=
      LANGUAGE_CODES='en-IN,mr-IN'
      """)
    XCTAssertEqual(parsed["HOTKEY"], "FN")
    XCTAssertEqual(parsed["CUSTOM_VOCABULARY"], "a=b, c#d")
    XCTAssertEqual(parsed["INPUT_DEVICE"], "")
    XCTAssertEqual(parsed["LANGUAGE_CODES"], "en-IN,mr-IN")
  }
}
