import Foundation
import XCTest

@testable import TokEngine

final class ServiceProbeTests: XCTestCase {
  func testEmptyKeyFailsBeforeAnyRequest() async {
    var configuration = EngineConfiguration()
    configuration.geminiApiKey = ""
    do {
      try await ServiceProbe.validate(configuration: configuration)
      XCTFail("An empty key must not validate.")
    } catch {
      XCTAssertEqual((error as NSError).code, 1)
      XCTAssertEqual(error.localizedDescription, "Enter an API key first.")
    }
  }

  func testStatusMessagesSeparateKeyProblemsFromServiceProblems() {
    XCTAssertNil(ServiceProbe.message(forStatus: 200))
    for status in [400, 401, 403] {
      XCTAssertEqual(
        ServiceProbe.message(forStatus: status),
        "The API key was rejected. Check the key and try again.")
    }
    XCTAssertEqual(ServiceProbe.message(forStatus: 429), "Rate limited. Try again in a minute.")
    XCTAssertEqual(ServiceProbe.message(forStatus: 503), "Gemini is unavailable right now.")
    XCTAssertEqual(
      ServiceProbe.message(forStatus: 302), "Gemini could not verify the key. Try again.")
  }

  func testTransportFailuresNeverAccuseTheKey() {
    XCTAssertEqual(
      ServiceProbe.message(for: URLError(.notConnectedToInternet)), "No network connection.")
    XCTAssertEqual(
      ServiceProbe.message(for: URLError(.cannotFindHost)), "No network connection.")
    XCTAssertEqual(
      ServiceProbe.message(for: URLError(.timedOut)), "Gemini did not respond in time. Try again.")
  }

  func testProbeUsesTheLightweightModelsEndpoint() {
    // The probe must stay on the REST endpoint the engine already warms, not a live session.
    XCTAssertEqual(
      ServiceProbe.probeURLString,
      "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")
    XCTAssertEqual(ServiceProbe.timeoutSeconds, 10)
  }
}
