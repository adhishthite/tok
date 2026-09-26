// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

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

  func testConfiguredModelsAreProbedByName() {
    XCTAssertEqual(
      ServiceProbe.modelURL(for: "gemini-3.5-transcribe-live")?.absoluteString,
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-3.5-transcribe-live")
    // A resource-prefixed name would pass here and fail at runtime, so it is refused, as
    // is anything that could change the path or add a query.
    XCTAssertNil(ServiceProbe.modelURL(for: "models/gemini-3.5-flash-lite"))
    XCTAssertNil(ServiceProbe.modelURL(for: "gemini/../models"))
    XCTAssertNil(ServiceProbe.modelURL(for: ""))
    var configuration = EngineConfiguration()
    configuration.geminiLiveModel = "live-model"
    configuration.geminiModel = "rest-model"
    configuration.enableLiveWebSocket = true
    XCTAssertEqual(ServiceProbe.modelsToProbe(configuration), ["live-model", "rest-model"])
    // REST-only never opens a live session, so a retired live model must not block setup.
    configuration.enableLiveWebSocket = false
    XCTAssertEqual(ServiceProbe.modelsToProbe(configuration), ["rest-model"])
    XCTAssertEqual(
      ServiceProbe.message(forModel: "nope", status: 404),
      "The model \"nope\" is not available for this key.")
    XCTAssertNil(ServiceProbe.message(forModel: "ok", status: 200))
    // A rate limit on the model call is still a service problem, not a model problem.
    XCTAssertEqual(
      ServiceProbe.message(forModel: "ok", status: 429), "Rate limited. Try again in a minute.")
  }
}
