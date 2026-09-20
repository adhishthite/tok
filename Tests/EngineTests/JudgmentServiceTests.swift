import Foundation
import XCTest

@testable import TokEngine

/// JudgmentService gate: no key -> no requests; failed probe -> unavailable; good probe ->
/// available. Uses an injected transport closure instead of a real network stack.
final class JudgmentServiceTests: XCTestCase {

  private final class StubTransport: JudgmentTransport {
    let probeResult: Result<Void, TypeSafeError>
    let askResult: Result<JudgmentResponse, TypeSafeError>
    private(set) var askCallCount = 0
    private(set) var probeCallCount = 0

    init(
      probeResult: Result<Void, TypeSafeError> = .success(()),
      askResult: Result<JudgmentResponse, TypeSafeError>? = nil
    ) {
      self.probeResult = probeResult
      self.askResult =
        askResult
        ?? .success(
          JudgmentResponse(
            model: "jev-test", answers: [:], usage: .init(inputTokens: 1, outputTokens: 1)))
    }

    @discardableResult
    func ask(
      state: JudgmentValue, questions: [String: JudgmentQuestion], label: String,
      completion: @escaping (Result<JudgmentResponse, TypeSafeError>) -> Void
    ) -> CancellableRequest {
      askCallCount += 1
      completion(askResult)
      return CancellableRequest()
    }

    @discardableResult
    func probe(completion: @escaping (Result<Void, TypeSafeError>) -> Void) -> CancellableRequest {
      probeCallCount += 1
      completion(probeResult)
      return CancellableRequest()
    }
  }

  func testEmptyKeyNeverBuildsATransportProbesOrAsks() {
    let stub = StubTransport()
    // The real transport owns the URLSession, so "never constructed" is the proof that an
    // empty key creates no TypeSafe session and can issue no request.
    var transportsBuilt = 0
    let service = JudgmentService(apiKey: "") { _ in
      transportsBuilt += 1
      return stub
    }
    let settled = expectation(description: "settled")
    service.queue.async { settled.fulfill() }
    wait(for: [settled], timeout: 2)
    XCTAssertEqual(transportsBuilt, 0)
    XCTAssertEqual(stub.probeCallCount, 0)
    XCTAssertFalse(service.isAvailable)
    let askExpectation = expectation(description: "ask no-ops")
    service.ask(state: .string("x"), questions: [:], label: "t") { result in
      if case .failure(.unavailable) = result {} else { XCTFail("expected .unavailable") }
      askExpectation.fulfill()
    }
    wait(for: [askExpectation], timeout: 2)
    XCTAssertEqual(stub.askCallCount, 0)
    XCTAssertEqual(transportsBuilt, 0)
  }

  func testFailedProbeLeavesServiceUnavailableAndAsksNothing() async {
    let stub = StubTransport(probeResult: .failure(.unauthorized))
    let service = JudgmentService(apiKey: "bad-key") { _ in stub }
    let available = await service.awaitAvailability()
    XCTAssertFalse(available)
    XCTAssertFalse(service.isAvailable)
    // A rejected key probes exactly once and never reaches the judgment endpoint.
    let result = await service.ask(state: .string("x"), questions: [:], label: "t")
    guard case .failure(.unavailable) = result else {
      return XCTFail("expected .unavailable after a failed probe")
    }
    XCTAssertEqual(stub.askCallCount, 0)
    XCTAssertEqual(stub.probeCallCount, 1)
  }

  func testSuccessfulProbeMakesServiceAvailableAndAskWorks() async {
    let stub = StubTransport(probeResult: .success(()))
    let service = JudgmentService(apiKey: "good-key") { _ in stub }
    let available = await service.awaitAvailability()
    XCTAssertTrue(available)
    XCTAssertTrue(service.isAvailable)
    let result = await service.ask(state: .string("x"), questions: [:], label: "t")
    guard case .success = result else { return XCTFail("expected success once available") }
    XCTAssertEqual(stub.askCallCount, 1)
  }

  func testConfigureWithSameKeyDoesNotReprobe() async {
    let stub = StubTransport(probeResult: .failure(.unauthorized))
    let service = JudgmentService(apiKey: "same-key") { _ in stub }
    _ = await service.awaitAvailability()
    XCTAssertEqual(stub.probeCallCount, 1)
    service.configure(apiKey: "same-key")
    // No new probe was scheduled for the unchanged key.
    let settled = expectation(description: "queue settled")
    service.queue.async { settled.fulfill() }
    await fulfillment(of: [settled], timeout: 2)
    XCTAssertEqual(stub.probeCallCount, 1)
  }

  /// Thread-safe recorder for `onAvailabilityChange` callbacks: they land on
  /// `JudgmentService.queue`, never the test's calling thread.
  private final class AvailabilityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [JudgmentAvailability] = []
    func append(_ value: JudgmentAvailability) {
      lock.lock()
      values.append(value)
      lock.unlock()
    }
    var snapshot: [JudgmentAvailability] {
      lock.lock()
      defer { lock.unlock() }
      return values
    }
  }

  func testAvailabilityChangeEmitsOffWhenKeyIsCleared() {
    let stub = StubTransport(probeResult: .success(()))
    // Starts with no key so the handler is installed before the first transition. Seeding the
    // key in the initializer instead would race the probe's callback against the handler
    // assignment, and the recorded sequence would depend on which won.
    let service = JudgmentService(apiKey: "") { _ in stub }
    let recorder = AvailabilityRecorder()
    let seeded = expectation(description: "seed key verified")
    let offEmitted = expectation(description: "off emitted")
    service.onAvailabilityChange = { value in
      recorder.append(value)
      // Reading `availability` from inside the callback proves the lock is not held while
      // the callback runs: `availability` locks the same NSLock, so this would hang forever
      // (and time the test out) if the handler ran before `lock` was released.
      _ = service.availability
      if value == .available { seeded.fulfill() }
      if value == .off { offEmitted.fulfill() }
    }
    service.configure(apiKey: "seed-key")
    wait(for: [seeded], timeout: 2)
    service.configure(apiKey: "")
    wait(for: [offEmitted], timeout: 2)
    XCTAssertEqual(recorder.snapshot, [.checking, .available, .off])
  }

  func testAvailabilityChangeEmitsCheckingThenAvailableForGoodProbe() {
    let stub = StubTransport(probeResult: .success(()))
    let service = JudgmentService(apiKey: "") { _ in stub }
    let recorder = AvailabilityRecorder()
    let availableEmitted = expectation(description: "available emitted")
    service.onAvailabilityChange = { value in
      recorder.append(value)
      _ = service.availability
      if value == .available { availableEmitted.fulfill() }
    }
    service.configure(apiKey: "good-key")
    wait(for: [availableEmitted], timeout: 2)
    XCTAssertEqual(recorder.snapshot, [.checking, .available])
  }

  func testAvailabilityChangeEmitsCheckingThenUnavailableWithReasonForFailedProbe() {
    let stub = StubTransport(probeResult: .failure(.unauthorized))
    let service = JudgmentService(apiKey: "") { _ in stub }
    let recorder = AvailabilityRecorder()
    let unavailableEmitted = expectation(description: "unavailable emitted")
    service.onAvailabilityChange = { value in
      recorder.append(value)
      _ = service.availability
      if case .unavailable = value { unavailableEmitted.fulfill() }
    }
    service.configure(apiKey: "bad-key")
    wait(for: [unavailableEmitted], timeout: 2)
    XCTAssertEqual(
      recorder.snapshot, [.checking, .unavailable(reason: "HTTP 401 (key rejected)")])
  }
}
