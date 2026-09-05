import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3
import XCTest

@testable import TokEngine

struct LegacyCorrectionWatcher {
  struct Pair {
    let wrong: String
    let right: String
  }
  static func extractCorrections(pasted: String, field: String, vocabSet: Set<String>) -> [Pair] {
    let pastedTokens = tokenize(pasted)
    let fieldTokens = tokenize(field)
    guard !pastedTokens.isEmpty, !fieldTokens.isEmpty else { return [] }

    let window = bestWindow(pasted: pastedTokens, field: fieldTokens)
    guard !window.isEmpty else { return [] }

    var pairs: [Pair] = []
    for (wrongRaw, rightRaw) in substitutions(from: pastedTokens, to: window) {
      let wrong = strip(wrongRaw)
      let right = strip(rightRaw)
      guard !wrong.isEmpty, !right.isEmpty else { continue }
      guard wrong.lowercased() != right.lowercased() else { continue }
      guard wrong.count >= 3, right.count >= 3 else { continue }
      guard !stopwords.contains(wrong.lowercased()), !stopwords.contains(right.lowercased()) else {
        continue
      }
      guard right.first!.isUppercase || vocabSet.contains(right.lowercased()) else { continue }
      let dist = levenshtein(wrong.lowercased(), right.lowercased())
      let maxLen = max(wrong.count, right.count)
      guard dist <= max(2, (6 * maxLen) / 10) else { continue }
      pairs.append(Pair(wrong: wrong, right: right))
      if pairs.count >= 3 { break }
    }
    return pairs
  }

  private static func tokenize(_ text: String) -> [String] {
    text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
  }

  // Surrounding punctuation only; inner characters ("Next.js", "co-pilot") stay.
  private static func strip(_ token: String) -> String {
    let punct = CharacterSet(charactersIn: ".,!?;:\"'()[]{}<>«»\u{2018}\u{2019}\u{201C}\u{201D}")
    return token.trimmingCharacters(in: punct)
  }

  // Locate the paste inside a field that may hold unrelated text (an email draft, a doc).
  // Slides a pasted-length window over the field and keeps the best token-set overlap;
  // below 0.5 the paste was rewritten or deleted and diffing would produce noise.
  private static func bestWindow(pasted: [String], field: [String]) -> [String] {
    let n = pasted.count
    if field.count <= n {
      if overlapScore(pasted, field) >= 0.5 { return field }
      // A short paste can be edited entirely ("cloud" -> "Claude"): with no unchanged
      // tokens to anchor on the overlap gate can never pass, so for tiny equal-length
      // fields hand the whole thing to the LCS + gate stack and let them judge.
      if n <= 4 && field.count == n { return field }
      return []
    }
    // Always slide an exact-length window: comparing against the whole field dilutes
    // the overlap score when the paste sits inside a larger draft.
    var best: [String] = []
    var bestScore = 0.0
    for start in 0...(field.count - n) {
      let window = Array(field[start..<start + n])
      let score = overlapScore(pasted, window)
      if score > bestScore {
        bestScore = score
        best = window
      }
    }
    return bestScore >= 0.5 ? best : []
  }

  private static func overlapScore(_ a: [String], _ b: [String]) -> Double {
    let sa = Set(a.map { strip($0).lowercased() }.filter { !$0.isEmpty })
    let sb = Set(b.map { strip($0).lowercased() }.filter { !$0.isEmpty })
    guard !sa.isEmpty, !sb.isEmpty else { return 0.0 }
    return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
  }

  // LCS-based token diff. Each maximal run of changed tokens between two matches pairs
  // positionally when both sides changed the same number of tokens (<=3): "cloud code" ->
  // "Claude Code" yields cloud->Claude and code->Code. Unequal or longer runs are
  // discarded - those are rewrites of intent, not misrecognitions.
  private static func substitutions(from a: [String], to b: [String]) -> [(String, String)] {
    let n = a.count
    let m = b.count
    var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
      }
    }
    var result: [(String, String)] = []
    var i = 0
    var j = 0
    var runDel: [String] = []
    var runIns: [String] = []
    func flushRun() {
      if !runDel.isEmpty && runDel.count == runIns.count && runDel.count <= 3 {
        for k in 0..<runDel.count {
          result.append((runDel[k], runIns[k]))
        }
      }
      runDel.removeAll()
      runIns.removeAll()
    }
    while i < n || j < m {
      if i < n && j < m && a[i] == b[j] {
        flushRun()
        i += 1
        j += 1
      } else if j < m && (i == n || lcs[i][j + 1] >= lcs[i + 1][j]) {
        runIns.append(b[j])
        j += 1
      } else {
        runDel.append(a[i])
        i += 1
      }
    }
    flushRun()
    return result
  }

  private static func levenshtein(_ a: String, _ b: String) -> Int {
    let ca = Array(a)
    let cb = Array(b)
    if ca.isEmpty { return cb.count }
    if cb.isEmpty { return ca.count }
    var prev = Array(0...cb.count)
    var curr = [Int](repeating: 0, count: cb.count + 1)
    for i in 1...ca.count {
      curr[0] = i
      for j in 1...cb.count {
        let cost = ca[i - 1] == cb[j - 1] ? 0 : 1
        curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
      }
      swap(&prev, &curr)
    }
    return prev[cb.count]
  }

  private static let stopwords: Set<String> = [
    "the", "and", "but", "for", "not", "you", "your", "are", "was", "were", "have", "has",
    "had", "this", "that", "these", "those", "with", "from", "into", "will", "would",
    "can", "could", "should", "just", "like", "what", "when", "where", "which", "who",
    "how", "all", "any", "some", "there", "here", "then", "than", "them", "they", "its",
    "it's", "out", "about", "over", "under", "also", "very", "more", "most", "our",
  ]
}
