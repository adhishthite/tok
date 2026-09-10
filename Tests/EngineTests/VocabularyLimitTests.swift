import XCTest

@testable import TokEngine

final class VocabularyLimitTests: XCTestCase {
  func testVocabularyBeyondTheServiceLimitIsDroppedAndCounted() {
    let terms = (1...1205).map { "term\($0)" }.joined(separator: ",")
    let config = EngineConfiguration.load(values: ["CUSTOM_VOCABULARY": terms])
    XCTAssertEqual(config.customVocabulary.count, EngineConfiguration.vocabularyLimit)
    XCTAssertEqual(config.customVocabularyDropped, 205)
    XCTAssertEqual(config.customVocabulary.first, "term1")
    XCTAssertEqual(config.customVocabulary.last, "term1000")
  }

  func testVocabularyWithinTheLimitIsSentUnchanged() {
    let config = EngineConfiguration.load(
      values: ["CUSTOM_VOCABULARY": "Kubernetes, gemini => Gemini, Kubernetes"])
    XCTAssertEqual(config.customVocabulary, ["Kubernetes", "Gemini"])
    XCTAssertEqual(config.customVocabularyDropped, 0)
  }

  func testAlignedEndSignalsAndSessionLimitDefaults() {
    let config = EngineConfiguration()
    XCTAssertTrue(config.wsEndpointAligned)
    XCTAssertEqual(GeminiLiveClient.sessionLimitSeconds, 600)
    XCTAssertLessThan(GeminiLiveClient.sessionRotationSeconds, GeminiLiveClient.sessionLimitSeconds)
    XCTAssertNil(GeminiLiveClient(apiKey: "").sessionRemainingSeconds)
  }

  func testSessionClockStartsAtSetupAndStopsAtDisconnect() throws {
    let client = GeminiLiveClient(apiKey: "")
    client.recoveryFixture(LiveWriteProbe())
    client.recoveryReady()
    let remaining = try XCTUnwrap(client.sessionRemainingSeconds)
    XCTAssertGreaterThan(remaining, 595)
    XCTAssertLessThanOrEqual(remaining, GeminiLiveClient.sessionLimitSeconds)
    client.disconnect()
    XCTAssertNil(client.sessionRemainingSeconds)
  }
}
