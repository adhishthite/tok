import XCTest

@testable import TokEngine

final class StatsWordTokenizerTests: XCTestCase {
  func testStripsPunctuationLowercasesAndDropsStopWordsAndNumbers() {
    let words = StatsWordTokenizer.words(
      in: "Hello, world! Don’t e-mail the (Kubernetes) team… 2024 I am a x1. Let’s ship")
    XCTAssertEqual(
      words, ["hello", "world", "mail", "kubernetes", "team", "x1", "let's", "ship"])
  }

  func testSegmentsScriptsWrittenWithoutSpaces() {
    let chinese = "我喜欢北京的天气"
    let chineseWords = StatsWordTokenizer.words(in: chinese)
    XCTAssertGreaterThan(chineseWords.count, 1)
    XCTAssertFalse(chineseWords.contains(chinese))
    XCTAssertTrue(chineseWords.allSatisfy { $0.unicodeScalars.count <= 4 })
    let japanese = "今日は良い天気ですね、また明日"
    let japaneseWords = StatsWordTokenizer.words(in: japanese)
    XCTAssertGreaterThan(japaneseWords.count, 1)
    XCTAssertTrue(japaneseWords.allSatisfy { $0.unicodeScalars.count <= 4 })
    let thai = "วันนี้อากาศดีมาก"
    let thaiWords = StatsWordTokenizer.words(in: thai)
    XCTAssertGreaterThan(thaiWords.count, 1)
    XCTAssertFalse(thaiWords.contains(thai))
  }

  func testRejectsSentenceSizedTokensAsASecondGuard() {
    let glued = String(repeating: "ab", count: 30)
    XCTAssertNil(StatsWordTokenizer.normalize(glued))
    XCTAssertEqual(
      StatsWordTokenizer.normalize(String(repeating: "ab", count: 24)),
      String(repeating: "ab", count: 24))
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
