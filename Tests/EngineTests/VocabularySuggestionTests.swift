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
}
