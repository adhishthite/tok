import Foundation
import XCTest

@testable import TokEngine

final class LiveKeepaliveTests: XCTestCase {
  func testKeepaliveArmsOnSetupAndStopsOnDisconnect() {
    let client = GeminiLiveClient(apiKey: "")
    XCTAssertFalse(client.fixtureKeepaliveArmed)
    client.fixtureSetupComplete()
    XCTAssertTrue(client.fixtureKeepaliveArmed)
    client.disconnect()
    XCTAssertFalse(client.fixtureKeepaliveArmed)
  }

  func testConnectionFailureStopsTheKeepalive() {
    let client = GeminiLiveClient(apiKey: "")
    client.fixtureSetupComplete()
    XCTAssertTrue(client.fixtureKeepaliveArmed)
    client.recoveryConnectionFailure()
    XCTAssertFalse(client.fixtureKeepaliveArmed)
  }
}

final class LiveUsageTests: XCTestCase {
  func testCumulativeCountsReportThePerTurnDelta() {
    let client = GeminiLiveClient(apiKey: "")
    client.fixtureSetupComplete()
    client.startNewTurn()
    client.fixtureUsage(prompt: 20, response: 3)
    XCTAssertEqual(client.lastTurnUsage?.inputTokens, 20)
    XCTAssertEqual(client.lastTurnUsage?.outputTokens, 3)
    client.startNewTurn()
    client.fixtureUsage(prompt: 46, response: 9)
    XCTAssertEqual(client.lastTurnUsage?.inputTokens, 26)
    XCTAssertEqual(client.lastTurnUsage?.outputTokens, 6)
    client.abandonTurn()
  }

  func testCountsThatShrinkAreReadAsPerTurnValues() {
    let client = GeminiLiveClient(apiKey: "")
    client.fixtureSetupComplete()
    client.startNewTurn()
    client.fixtureUsage(prompt: 40, response: 8)
    client.startNewTurn()
    // A cumulative counter never shrinks, so 15 has to be this turn's own value. The
    // baseline diff would have reported nothing at all here.
    client.fixtureUsage(prompt: 15, response: 2)
    XCTAssertEqual(client.lastTurnUsage?.inputTokens, 15)
    XCTAssertEqual(client.lastTurnUsage?.outputTokens, 2)
    client.startNewTurn()
    XCTAssertNil(client.lastTurnUsage)
    client.fixtureUsage(prompt: 7, response: 1)
    XCTAssertEqual(client.lastTurnUsage?.inputTokens, 7)
    XCTAssertEqual(client.lastTurnUsage?.outputTokens, 1)
    client.abandonTurn()
  }

  func testOutputCountIsReadUnderEitherFieldName() {
    let client = GeminiLiveClient(apiKey: "")
    client.fixtureSetupComplete()
    client.startNewTurn()
    client.fixtureUsage(prompt: 10, response: 4, responseKey: "candidatesTokenCount")
    XCTAssertEqual(client.lastTurnUsage?.outputTokens, 4)
    client.abandonTurn()
  }
}
