import XCTest

@testable import TokEngine

final class StatsWordTokenizerTests: XCTestCase {
  func testStripsPunctuationLowercasesAndDropsStopWordsAndNumbers() {
    let words = StatsWordTokenizer.words(
      in: "Hello, world! Don’t e-mail the (Kubernetes) team… 2024 I am a x1. Let’s ship")
    XCTAssertEqual(
      words, ["hello", "world", "e-mail", "kubernetes", "team", "x1", "let's", "ship"])
  }

  func testKeepsRepeatsInOrderForCounting() {
    XCTAssertEqual(StatsWordTokenizer.words(in: "ship ship Ship"), ["ship", "ship", "ship"])
  }

  func testKeepsCombiningMarksInIndicScripts() {
    let words = StatsWordTokenizer.words(in: "नमस्ते दुनिया की, हैलो है")
    XCTAssertEqual(words, ["नमस्ते", "दुनिया", "हैलो"])
  }

  func testRejectsSingleLettersAndEmptyTokens() {
    XCTAssertEqual(StatsWordTokenizer.words(in: "a - … b  \n c"), [])
  }
}
