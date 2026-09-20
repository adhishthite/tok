import Foundation
import XCTest

@testable import TokEngine

final class VocabularySuggestionTests: XCTestCase {
  func testSuggestionsRoundTripAsVocabularyAndRejectUnsafeSyntax() {
    let raw: [String: Any] = [
      "vocabulary": [
        ["term": "LangGraph", "reason": "Repeated term"],
        ["term": "langgraph", "reason": "Duplicate"],
        ["term": "# hidden"], ["term": "two\nlines"], ["term": "a,b"],
      ],
      "replacements": [
        ["wrong": "cloud code", "right": "Claude Code", "reason": "Repeated correction"],
        ["wrong": "word", "right": "Word"],
        ["wrong": "a b c d e", "right": "term"],
      ],
    ]
    let suggestions = VocabularyAnalyzer.parseSuggestions(raw: raw, known: [])
    XCTAssertEqual(suggestions.map(\.line), ["LangGraph", "cloud code => Claude Code"])
    let config = EngineConfiguration.load(
      values: [:], vocabularyText: suggestions.map(\.line).joined(separator: "\n"))
    XCTAssertEqual(config.customVocabulary, ["LangGraph", "Claude Code"])
    XCTAssertEqual(config.replacementRules.count, 1)
  }

  func testPromptOmitsTimestampsButIncludesAppName() throws {
    // Audit F32: the analysis payload used to carry per-row timestamps with no
    // disclosure. App names stay (they help judge terms); timestamps must not
    // appear anywhere in the built prompt.
    let rows = [
      VocabularyAnalyzer.Row(ts: 1_700_000_000, app: "Xcode", text: "a note about LangGraph")
    ]
    let observed = [
      VocabularyAnalyzer.ObservedCorrection(
        ts: 1_700_000_100, wrong: "cloud code", right: "Claude Code", app: "Slack")
    ]
    let prompt = VocabularyAnalyzer.buildPrompt(
      rows: rows, pairs: [], observed: observed, config: EngineConfiguration())
    XCTAssertTrue(prompt.contains("[Xcode] a note about LangGraph"))
    XCTAssertTrue(prompt.contains("\"cloud code\" -> \"Claude Code\" (Slack)"))
    let timestampPattern = try NSRegularExpression(pattern: #"\d{1,2}-\d{2} \d{2}:\d{2}"#)
    let range = NSRange(prompt.startIndex..., in: prompt)
    XCTAssertNil(timestampPattern.firstMatch(in: prompt, range: range))
  }

  // MARK: - Item 2 (optional upgrade; see Engine/Judgment)

  private final class StubTransport: JudgmentTransport {
    let answers: [String: JudgmentAnswer]
    init(answers: [String: JudgmentAnswer]) { self.answers = answers }

    @discardableResult
    func ask(
      state: JudgmentValue, questions: [String: JudgmentQuestion], label: String,
      completion: @escaping (Result<JudgmentResponse, TypeSafeError>) -> Void
    ) -> CancellableRequest {
      // Only answer the questions actually asked in this call, mirroring a real server.
      let subset = answers.filter { questions[$0.key] != nil }
      completion(
        .success(
          JudgmentResponse(
            model: "jev-test", answers: subset, usage: .init(inputTokens: 50, outputTokens: 3))))
      return CancellableRequest()
    }

    @discardableResult
    func probe(completion: @escaping (Result<Void, TypeSafeError>) -> Void) -> CancellableRequest {
      completion(.success(()))
      return CancellableRequest()
    }
  }

  func testFilterRetryPairsKeepsOnlyPairsAboveThreshold() async throws {
    let stub = StubTransport(answers: ["pair_0": .noul(0.9), "pair_1": .noul(0.3)])
    let service = JudgmentService(apiKey: "test-key") { _ in stub }
    let available = await service.awaitAvailability()
    XCTAssertTrue(available)

    let pairs: [(older: VocabularyAnalyzer.Row, newer: VocabularyAnalyzer.Row)] = [
      (
        VocabularyAnalyzer.Row(ts: 0, app: "A", text: "one"),
        VocabularyAnalyzer.Row(ts: 1, app: "A", text: "two")
      ),
      (
        VocabularyAnalyzer.Row(ts: 2, app: "A", text: "three"),
        VocabularyAnalyzer.Row(ts: 3, app: "A", text: "four")
      ),
    ]
    let (kept, confirmed) = await VocabularyAnalyzer.filterRetryPairs(pairs, judgment: service)
    XCTAssertTrue(confirmed)
    XCTAssertEqual(kept.count, 1)
    XCTAssertEqual(kept.first?.newer.text, "two")
  }

  func testFilterRetryPairsUnchangedWhenJudgmentUnavailable() async {
    let service = JudgmentService(apiKey: "")
    let pairs: [(older: VocabularyAnalyzer.Row, newer: VocabularyAnalyzer.Row)] = [
      (
        VocabularyAnalyzer.Row(ts: 0, app: "A", text: "one"),
        VocabularyAnalyzer.Row(ts: 1, app: "A", text: "two")
      )
    ]
    let (kept, confirmed) = await VocabularyAnalyzer.filterRetryPairs(pairs, judgment: service)
    XCTAssertFalse(confirmed)
    XCTAssertEqual(kept.count, 1)
  }

  func testBuildPromptAnnotatesConfirmedRetryPairs() {
    let rows = [VocabularyAnalyzer.Row(ts: 0, app: "A", text: "seed")]
    let pairs: [(older: VocabularyAnalyzer.Row, newer: VocabularyAnalyzer.Row)] = [
      (
        VocabularyAnalyzer.Row(ts: 0, app: "A", text: "cloud code"),
        VocabularyAnalyzer.Row(ts: 1, app: "A", text: "Claude Code")
      )
    ]
    let prompt = VocabularyAnalyzer.buildPrompt(
      rows: rows, pairs: pairs, observed: [], config: EngineConfiguration(),
      confirmedRetryPairs: true)
    XCTAssertTrue(prompt.contains("Confirmed as a genuine re-dictation by Jev."))
  }

  func testAttachConfidenceScoresTermsAndRulesThenSortsDescending() async {
    // Scores are 0-indexed over the levels, so the top of a 4-level scale is 3.0.
    let stub = StubTransport(answers: [
      "item_0": .noul(0.4), "item_1": .score(3, confidence: nil),
    ])
    let service = JudgmentService(apiKey: "test-key") { _ in stub }
    let available = await service.awaitAvailability()
    XCTAssertTrue(available)
    let suggestions = [
      VocabularySuggestion(line: "LangGraph", reason: "repeated"),
      VocabularySuggestion(line: "cloud code => Claude Code", reason: "repeated correction"),
    ]
    let updated = await VocabularyAnalyzer.attachConfidence(
      suggestions, rows: [], judgment: service)
    XCTAssertEqual(updated.count, 2)
    // item_1 (the rule) scored the top level (3 of 0...3) -> confidence 1.0, sorts first.
    XCTAssertEqual(updated.first?.line, "cloud code => Claude Code")
    XCTAssertEqual(updated.first?.confidence ?? -1, 1.0, accuracy: 0.0001)
    XCTAssertEqual(updated.last?.line, "LangGraph")
    XCTAssertEqual(updated.last?.confidence ?? -1, 0.4, accuracy: 0.0001)
  }

  func testRuleScoreNormalizesOverZeroIndexedLevels() async {
    // A 4-level score answers in 0...3; the midpoint 1.5 must normalize to 0.5, not to
    // (1.5 - 1) / 3. Verified against the live API on 2026-09-21.
    let stub = StubTransport(answers: ["item_0": .score(1.5, confidence: nil)])
    let service = JudgmentService(apiKey: "test-key") { _ in stub }
    let available = await service.awaitAvailability()
    XCTAssertTrue(available)
    let updated = await VocabularyAnalyzer.attachConfidence(
      [VocabularySuggestion(line: "cloud => Claude", reason: "repeated correction")],
      rows: [], judgment: service)
    XCTAssertEqual(updated.first?.confidence ?? -1, 0.5, accuracy: 0.0001)
  }

  func testAttachConfidenceUnchangedWhenJudgmentUnavailable() async {
    let service = JudgmentService(apiKey: "")
    let suggestions = [VocabularySuggestion(line: "LangGraph", reason: "repeated")]
    let updated = await VocabularyAnalyzer.attachConfidence(
      suggestions, rows: [], judgment: service)
    XCTAssertEqual(updated.map(\.line), suggestions.map(\.line))
    XCTAssertNil(updated.first?.confidence)
  }
}
