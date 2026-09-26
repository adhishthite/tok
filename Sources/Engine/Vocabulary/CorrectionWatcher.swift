// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class CorrectionWatcher {

  let history: HistoryStore?
  private let delayMs: Int
  // Lowercased boost terms: a correction whose right side is a known vocabulary term
  // passes the proper-noun gate even when lowercase ("kubectl", "gcloud").
  let vocabSet: Set<String>
  // Item 1 (optional upgrade; see Engine/Judgment). When available, genuineness judging
  // replaces the capitalization/vocab proxy and the Levenshtein band as the precision gate.
  let judgment: JudgmentService
  // Main-thread-only. Bumping invalidates any armed read-back (captureActive idiom):
  // a new capture means the field is about to change under the pending read.
  var generation = 0
  let worker = DispatchQueue(label: "com.adhishthite.tok.corrections", qos: .utility)

  // Unevaluated threshold; must be tuned on real data.
  static let genuinenessThreshold = 0.7

  init(config: EngineConfiguration, history: HistoryStore?, judgment: JudgmentService) {
    self.history = history
    self.delayMs = config.learnDelayMs
    self.vocabSet = Set(config.customVocabulary.map { $0.lowercased() })
    self.judgment = judgment
  }

  // Main thread. Called after a successful paste into the app identified by pid.
  func arm(pastedText: String, targetPid: pid_t, appName: String) {
    generation += 1
    let gen = generation
    DispatchQueue.main.asyncAfter(deadline: .now() + Double(delayMs) / 1000.0) { [weak self] in
      self?.fire(gen: gen, pastedText: pastedText, targetPid: targetPid, appName: appName)
    }
  }

  // Main thread. A new capture invalidates the pending read - the next paste would land
  // in the field and the diff would misread it as an edit.
  func cancelPending() {
    generation += 1
  }

  private func fire(gen: Int, pastedText: String, targetPid: pid_t, appName: String) {
    guard gen == generation else { return }
    // The user moved on or is in a password field: reading the focused element now would
    // capture text that has nothing to do with the paste.
    guard !SecureInputMonitor.isActive else { return }
    guard let front = NSWorkspace.shared.frontmostApplication,
      front.processIdentifier == targetPid
    else { return }
    worker.async { [weak self] in
      guard let self = self else { return }
      // Only the result crosses back to main; the field is never retained or logged.
      guard let field = Self.focusedFieldValue(pid: targetPid) else { return }
      if self.judgment.isAvailable {
        let candidates = Self.extractCandidates(
          pasted: pastedText, field: field, vocabSet: self.vocabSet, applyProxyGates: false)
        guard !candidates.isEmpty else { return }
        self.judgeGenuineness(candidates: candidates) { [weak self] genuine in
          guard let self = self, !genuine.isEmpty else { return }
          DispatchQueue.main.async { [weak self] in
            guard let self = self, gen == self.generation, !SecureInputMonitor.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid
            else { return }
            for (candidate, score) in genuine {
              self.history?.recordCorrection(
                wrong: candidate.wrong, right: candidate.right, appName: appName,
                genuineness: score, source: "ax_readback_jev")
            }
            Log.info("LEARN", "Observed \(genuine.count) typed corrections (Jev-confirmed).")
          }
        }
      } else {
        let pairs = Self.extractCorrections(
          pasted: pastedText, field: field, vocabSet: self.vocabSet)
        DispatchQueue.main.async { [weak self] in
          guard let self = self, gen == self.generation, !SecureInputMonitor.isActive,
            NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPid
          else { return }
          for p in pairs {
            self.history?.recordCorrection(wrong: p.wrong, right: p.right, appName: appName)
          }
          if !pairs.isEmpty { Log.info("LEARN", "Observed \(pairs.count) typed corrections.") }
        }
      }
    }
  }

  // Sends one noul per candidate pair in a single Jev request and keeps only those judged
  // genuine (noul >= genuinenessThreshold). Internal (not private) so tests can drive it
  // directly with synthetic candidates instead of the AX read-back.
  func judgeGenuineness(
    candidates: [Candidate], completion: @escaping ([(candidate: Candidate, score: Double)]) -> Void
  ) {
    guard !candidates.isEmpty else {
      completion([])
      return
    }
    var questions: [String: JudgmentQuestion] = [:]
    for index in candidates.indices {
      questions["pair_\(index)"] = Self.genuinenessQuestion(index: index)
    }
    let state = JudgmentValue.object([
      "pairs": .array(
        candidates.map {
          .object([
            "pasted": .string($0.pastedWindow), "edited": .string($0.editedWindow),
            "wrong": .string($0.wrong), "right": .string($0.right),
          ])
        })
    ])
    judgment.ask(state: state, questions: questions, label: "correction_genuineness") { result in
      let response: JudgmentResponse
      switch result {
      case .success(let value):
        response = value
      // .unavailable means the gate is simply closed, which is the normal no-key state and
      // never worth a line; any other failure is a real integration problem, so it is logged.
      case .failure(.unavailable):
        completion([])
        return
      case .failure(let error):
        Log.warn("Jev", "Correction genuineness judgment failed: \(error.diagnosticDescription).")
        completion([])
        return
      }
      var genuine: [(candidate: Candidate, score: Double)] = []
      for (index, candidate) in candidates.enumerated() {
        guard case .noul(let value)? = response.answers["pair_\(index)"],
          value >= Self.genuinenessThreshold
        else { continue }
        genuine.append((candidate, value))
      }
      completion(genuine)
    }
  }

  // The candidate itself travels in the request state as `pairs[index]`; the question only
  // needs the index to point at it.
  private static func genuinenessQuestion(index: Int) -> JudgmentQuestion {
    .noul(
      instructions: """
        In `pairs[\(index)]`, speech recognition produced `pairs[\(index)].wrong` where the \
        speaker's own edit shows `pairs[\(index)].right` was intended, inside the surrounding \
        text `pairs[\(index)].pasted` (as recognized) versus `pairs[\(index)].edited` (after the \
        user's edit). Is `pairs[\(index)].right` what the speaker actually said - a phonetic or \
        spelling misrecognition fix - and not a change of meaning, wording, tense, or a deletion?
        """,
      criteria: [
        "true":
          "A misrecognition fix: \"cloud\" -> \"Claude\" (misheard product name); \"cot\" -> \"Kot\" (misheard name).",
        "false":
          "A meaning or wording change, not a misrecognition: \"quick\" -> \"fast\" (synonym swap); \"the\" -> \"a\" (grammar edit).",
      ])
  }

  // Focused element's string value in the target app, or nil when the app exposes none.
  private static func focusedFieldValue(pid: pid_t) -> String? {
    let appElement = AXUIElementCreateApplication(pid)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.05
    AXUIElementSetMessagingTimeout(appElement, 0.05)
    var focusedRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
      let focusedAny = focusedRef, CFGetTypeID(focusedAny) == AXUIElementGetTypeID()
    else { return nil }
    let focused = focusedAny as! AXUIElement
    let remaining = deadline - ProcessInfo.processInfo.systemUptime
    guard remaining > 0.002 else { return nil }
    AXUIElementSetMessagingTimeout(focused, Float(remaining))
    var valueRef: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &valueRef) == .success,
      let value = valueRef as? String, !value.isEmpty
    else { return nil }
    return value
  }

  // MARK: Diff + gates (Python-mirrored; see verification protocol)

  // The gate stack is deliberately strict (WhimprFlow/Wispr Flow lineage): only single-word
  // swaps, both sides >=3 chars, no stopwords, no capitalization-only fixes, right side a
  // proper noun or known vocabulary term, and phonetically plausible via a Levenshtein
  // band. A missed correction costs nothing (the analyzer can still infer it); a false
  // positive plants a bad rule suggestion.
  static func extractCorrections(pasted: String, field: String, vocabSet: Set<String>) -> [Pair] {
    extractCandidates(pasted: pasted, field: field, vocabSet: vocabSet, applyProxyGates: true).map {
      Pair(wrong: $0.wrong, right: $0.right)
    }
  }

  // The full gate stack through "not case-only" and the cap of 3 always applies (recall
  // filter). `applyProxyGates` additionally applies the capitalization/known-vocab proxy and
  // the Levenshtein band - the precision filter used only when Jev is unavailable to judge
  // genuineness directly (item 1). `pastedWindow`/`editedWindow` are the surrounding window
  // sentences a genuineness judgment needs for context.
  static func extractCandidates(
    pasted: String, field: String, vocabSet: Set<String>, applyProxyGates: Bool
  ) -> [Candidate] {
    guard pasted.utf8.count <= 16000, field.utf8.count <= 500000 else { return [] }
    let pastedTokens = tokenize(pasted)
    let fieldTokens = tokenize(field)
    guard !pastedTokens.isEmpty, !fieldTokens.isEmpty, pastedTokens.count <= 512,
      fieldTokens.count <= 50000
    else { return [] }

    let window = bestWindow(pasted: pastedTokens, field: fieldTokens)
    guard !window.isEmpty else { return [] }
    let pastedSentence = pastedTokens.joined(separator: " ")
    let editedSentence = window.joined(separator: " ")

    var candidates: [Candidate] = []
    for (wrongRaw, rightRaw) in substitutions(from: pastedTokens, to: window) {
      let wrong = strip(wrongRaw)
      let right = strip(rightRaw)
      guard !wrong.isEmpty, !right.isEmpty else { continue }
      guard wrong.lowercased() != right.lowercased() else { continue }
      guard wrong.count >= 3, right.count >= 3 else { continue }
      guard !stopwords.contains(wrong.lowercased()), !stopwords.contains(right.lowercased()) else {
        continue
      }
      if applyProxyGates {
        guard right.first!.isUppercase || vocabSet.contains(right.lowercased()) else { continue }
        let dist = levenshtein(wrong.lowercased(), right.lowercased())
        let maxLen = max(wrong.count, right.count)
        guard dist <= max(2, (6 * maxLen) / 10) else { continue }
      }
      candidates.append(
        Candidate(
          wrong: wrong, right: right, pastedWindow: pastedSentence, editedWindow: editedSentence))
      if candidates.count >= 3 { break }
    }
    return candidates
  }

  private static func tokenize(_ text: String) -> [String] {
    text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
  }

  // Surrounding punctuation only; inner characters ("Next.js", "co-pilot") stay.
  private static let surroundingPunctuation = CharacterSet(
    charactersIn: ".,!?;:\"'()[]{}<>«»\u{2018}\u{2019}\u{201C}\u{201D}")

  private static func strip(_ token: String) -> String {
    return token.trimmingCharacters(in: surroundingPunctuation)
  }

  // Locate the paste inside a field that may hold unrelated text (an email draft, a doc).
  // Slides a pasted-length window over the field and keeps the best token-set overlap;
  // below 0.5 the paste was rewritten or deleted and diffing would produce noise.
  static func bestWindow(pasted: [String], field: [String]) -> [String] {
    let n = pasted.count
    if field.count <= n {
      if overlapScore(pasted, field) >= 0.5 { return field }
      // A short paste can be edited entirely ("cloud" -> "Claude"): with no unchanged
      // tokens to anchor on the overlap gate can never pass, so for tiny equal-length
      // fields hand the whole thing to the LCS + gate stack and let them judge.
      if n <= 4 && field.count == n { return field }
      return []
    }
    let target = Set(pasted.map { strip($0).lowercased() }.filter { !$0.isEmpty })
    guard !target.isEmpty else { return [] }
    let normalized = field.map { strip($0).lowercased() }
    var counts: [String: Int] = [:]
    var intersection = 0
    func add(_ word: String) {
      guard !word.isEmpty else { return }
      let count = counts[word, default: 0]
      if count == 0 && target.contains(word) { intersection += 1 }
      counts[word] = count + 1
    }
    func remove(_ word: String) {
      guard let count = counts[word] else { return }
      if count == 1 {
        counts.removeValue(forKey: word)
        if target.contains(word) { intersection -= 1 }
      } else {
        counts[word] = count - 1
      }
    }
    for word in normalized.prefix(n) { add(word) }
    var bestStart = 0
    var bestScore = 0.0
    for start in 0...(field.count - n) {
      if start > 0 {
        remove(normalized[start - 1])
        add(normalized[start + n - 1])
      }
      let union = target.count + counts.count - intersection
      let score = Double(intersection) / Double(union)
      if score > bestScore {
        bestScore = score
        bestStart = start
      }
      if score == 1 { break }
    }
    return bestScore >= 0.5 ? Array(field[bestStart..<bestStart + n]) : []
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
