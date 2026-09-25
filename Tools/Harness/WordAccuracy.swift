import Foundation

/// Word-level comparison of a transcript against the clip's known text. Both sides are
/// lowercased, stripped of punctuation, split at letter-digit boundaries, and have
/// numbers spelled out, so "p95" and "p ninety five" or "4" and "four" compare equal.
struct WordAccuracy: Encodable {
  let wer: Double
  let referenceWords: Int
  let hypothesisWords: Int
  let firstWordHit: Bool
  let lastWordHit: Bool

  init(reference: String, hypothesis: String) {
    let ref = Self.words(reference)
    let hyp = Self.words(hypothesis)
    referenceWords = ref.count
    hypothesisWords = hyp.count
    wer =
      ref.isEmpty ? (hyp.isEmpty ? 0 : 1) : Double(Self.editDistance(ref, hyp)) / Double(ref.count)
    // A clipped onset or a cut tail shows as a missing first or last word; allow one word
    // of slack for an inserted filler.
    firstWordHit = ref.first.map { hyp.prefix(2).contains($0) } ?? true
    lastWordHit = ref.last.map { hyp.suffix(2).contains($0) } ?? true
  }

  private static let spellOut: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .spellOut
    formatter.locale = Locale(identifier: "en_US")
    return formatter
  }()

  static func words(_ text: String) -> [String] {
    var normalized = text.lowercased()
      .replacingOccurrences(of: "\u{2019}", with: "'")
      .replacingOccurrences(of: "-", with: " ")
    normalized = normalized.replacingOccurrences(
      of: "([a-z])([0-9])", with: "$1 $2", options: .regularExpression)
    normalized = normalized.replacingOccurrences(
      of: "([0-9])(st|nd|rd|th)\\b", with: "$1", options: .regularExpression)
    var tokens: [String] = []
    normalized.enumerateSubstrings(in: normalized.startIndex..., options: .byWords) {
      word, _, _, _ in
      guard let word else { return }
      if let number = Int(word), let spelled = spellOut.string(from: NSNumber(value: number)) {
        tokens.append(
          contentsOf: spelled.replacingOccurrences(of: "-", with: " ").split(separator: " ").map(
            String.init))
      } else {
        tokens.append(word)
      }
    }
    return tokens
  }

  private static func editDistance(_ a: [String], _ b: [String]) -> Int {
    var previous = Array(0...b.count)
    for (i, word) in a.enumerated() {
      var current = [i + 1] + Array(repeating: 0, count: b.count)
      for (j, other) in b.enumerated() {
        current[j + 1] = min(
          previous[j + 1] + 1, current[j] + 1, previous[j] + (word == other ? 0 : 1))
      }
      previous = current
    }
    return previous[b.count]
  }
}
