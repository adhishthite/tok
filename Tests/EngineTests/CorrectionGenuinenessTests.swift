import Foundation
import XCTest

@testable import TokEngine

/// Item 1: with Jev available, extractCandidates drops the capitalization/vocab proxy and the
/// Levenshtein band, and CorrectionWatcher.judgeGenuineness keeps only candidates whose noul
/// clears the threshold. Existing extractCorrections behavior (no Jev) is covered unchanged
/// by CoreRegressionTests.
final class CorrectionGenuinenessTests: XCTestCase {

  private final class StubTransport: JudgmentTransport {
    let nouls: [String: Double]
    init(nouls: [String: Double]) { self.nouls = nouls }

    @discardableResult
    func ask(
      state: JudgmentValue, questions: [String: JudgmentQuestion], label: String,
      completion: @escaping (Result<JudgmentResponse, TypeSafeError>) -> Void
    ) -> CancellableRequest {
      var answers: [String: JudgmentAnswer] = [:]
      for (id, value) in nouls { answers[id] = .noul(value) }
      completion(
        .success(
          JudgmentResponse(
            model: "jev-test", answers: answers, usage: .init(inputTokens: 40, outputTokens: 2))))
      return CancellableRequest()
    }

    @discardableResult
    func probe(completion: @escaping (Result<Void, TypeSafeError>) -> Void) -> CancellableRequest {
      completion(.success(()))
      return CancellableRequest()
    }
  }

  func testOnlyCandidateAboveThresholdIsKept() async {
    let stub = StubTransport(nouls: ["pair_0": 0.9, "pair_1": 0.2])
    let service = JudgmentService(apiKey: "test-key") { _ in stub }
    let available = await service.awaitAvailability()
    XCTAssertTrue(available)

    var config = EngineConfiguration()
    config.learnCorrections = true
    let watcher = CorrectionWatcher(config: config, history: nil, judgment: service)

    let candidates = [
      CorrectionWatcher.Candidate(
        wrong: "cloud", right: "Claude", pastedWindow: "use cloud code",
        editedWindow: "use Claude code"),
      CorrectionWatcher.Candidate(
        wrong: "quick", right: "fast", pastedWindow: "a quick fix", editedWindow: "a fast fix"),
    ]

    let done = expectation(description: "genuineness judged")
    var kept: [(candidate: CorrectionWatcher.Candidate, score: Double)] = []
    watcher.judgeGenuineness(candidates: candidates) { genuine in
      kept = genuine
      done.fulfill()
    }
    await fulfillment(of: [done], timeout: 5)

    XCTAssertEqual(kept.count, 1)
    XCTAssertEqual(kept.first?.candidate.wrong, "cloud")
    XCTAssertEqual(kept.first?.candidate.right, "Claude")
    XCTAssertEqual(kept.first?.score ?? -1, 0.9, accuracy: 0.0001)
  }

  func testJevCandidatesDropProxyGatesButKeepRecallFilter() {
    // "Cloud" -> "cloud" is case-only and must still be rejected (recall filter kept).
    XCTAssertTrue(
      CorrectionWatcher.extractCandidates(
        pasted: "cloud", field: "cloud", vocabSet: [], applyProxyGates: false
      ).isEmpty)
    // A lowercase, non-vocabulary right side that would fail the proxy gate is still a
    // candidate once that gate is dropped.
    let candidates = CorrectionWatcher.extractCandidates(
      pasted: "the cot meeting", field: "the kot meeting", vocabSet: [], applyProxyGates: false)
    XCTAssertEqual(candidates.map(\.wrong), ["cot"])
    XCTAssertEqual(candidates.map(\.right), ["kot"])
    XCTAssertEqual(candidates.first?.pastedWindow, "the cot meeting")
    XCTAssertEqual(candidates.first?.editedWindow, "the kot meeting")
  }

  func testEmptyCandidatesCompleteImmediatelyWithoutARequest() {
    let stub = StubTransport(nouls: [:])
    let service = JudgmentService(apiKey: "test-key") { _ in stub }
    let watcher = CorrectionWatcher(config: EngineConfiguration(), history: nil, judgment: service)
    let done = expectation(description: "completed")
    watcher.judgeGenuineness(candidates: []) { genuine in
      XCTAssertTrue(genuine.isEmpty)
      done.fulfill()
    }
    wait(for: [done], timeout: 2)
  }
}
