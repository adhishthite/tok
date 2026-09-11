import Foundation
import NaturalLanguage

/// Language-aware word boundaries shared by dictation totals and word usage.
/// Totals include function words, single-letter words, and numbers.
public enum WordTokenizer {
  private static let countableScalars = CharacterSet.alphanumerics.subtracting(.nonBaseCharacters)
  public static func words(in text: String) -> [String] {
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    var words: [String] = []
    tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
      let word = String(text[range])
      if word.unicodeScalars.contains(where: countableScalars.contains) {
        words.append(word)
      }
      return true
    }
    return words
  }

  public static func count(in text: String) -> Int { words(in: text).count }
}
