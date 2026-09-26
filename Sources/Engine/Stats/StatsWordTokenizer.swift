// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Splits dictated text into countable words. Function words, fillers, and bare numbers
/// are dropped so the most-used list shows vocabulary rather than grammar.
public enum StatsWordTokenizer {
  /// English function words and fillers, plus the most common Hindi and Marathi ones,
  /// matching Tok's default languages.
  static let stopWords: Set<String> = [
    "a", "an", "the", "and", "or", "but", "if", "so", "of", "to", "in", "on", "at", "by",
    "for", "with", "from", "as", "is", "are", "was", "were", "be", "been", "being", "am",
    "do", "does", "did", "have", "has", "had", "i", "me", "my", "we", "our", "us", "you",
    "your", "he", "him", "his", "she", "her", "it", "its", "they", "them", "their", "this",
    "that", "these", "those", "there", "here", "what", "which", "who", "whom", "when",
    "where", "why", "how", "not", "no", "yes", "can", "could", "will", "would", "should",
    "shall", "may", "might", "must", "just", "also", "than", "then", "too", "very", "up",
    "down", "out", "into", "about", "over", "again", "all", "any", "some", "more", "most",
    "other", "such", "only", "own", "same", "because", "while", "before", "after", "okay",
    "ok", "um", "uh", "yeah", "don't", "doesn't", "didn't", "can't", "won't", "isn't",
    "aren't", "wasn't", "i'm", "i've", "i'll", "i'd", "it's", "that's", "there's", "we're",
    "we've", "we'll", "you're", "you've", "you'll", "they're", "they've", "he's", "she's",
    "और", "है", "हैं", "का", "की", "के", "को", "में", "से", "पर", "यह", "वह", "ये", "वो", "हम",
    "तुम", "आप", "मैं", "एक", "हो", "था", "थी", "थे", "ही", "भी", "तो", "ना", "नहीं", "आणि",
    "आहे", "आहेत", "ला", "चा", "ची", "चे", "मध्ये", "मी", "तू", "ती", "ते", "हा", "हे",
    "नाही", "पण", "किंवा",
  ]

  private static let wordScalars = CharacterSet.alphanumerics.union(.nonBaseCharacters)
  /// Longer tokens are not words. This is a second guard, after segmentation, so a
  /// sentence can never be stored as one "word" even if the tokenizer misjudges a script.
  static let maximumScalars = 48

  /// Lowercased words in reading order. Repeats are kept so callers can count them.
  /// Segmentation follows Unicode word boundaries, so scripts written without spaces
  /// such as Chinese, Japanese, and Thai are split into words, not kept as sentences.
  public static func words(in text: String) -> [String] {
    WordTokenizer.words(in: text).compactMap(normalize)
  }

  /// Lowercases, strips edge punctuation, and rejects numbers, single letters, and stop words.
  /// Internal apostrophes and hyphens survive, so "don't" and "e-mail" stay whole.
  static func normalize(_ token: String) -> String? {
    let scalars = token.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").unicodeScalars
    let trimmed = scalars.drop(while: { !wordScalars.contains($0) })
    var end = trimmed.endIndex
    while end > trimmed.startIndex, !wordScalars.contains(trimmed[trimmed.index(before: end)]) {
      end = trimmed.index(before: end)
    }
    let word = String(trimmed[trimmed.startIndex..<end])
    let length = word.unicodeScalars.count
    guard length >= 2, length <= maximumScalars,
      word.unicodeScalars.contains(where: CharacterSet.letters.contains),
      !stopWords.contains(word)
    else { return nil }
    return word
  }
}
