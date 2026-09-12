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
}
