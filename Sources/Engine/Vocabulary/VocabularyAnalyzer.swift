// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SQLite3

public enum VocabularyAnalyzer {
  @concurrent public static func analyze(configuration config: EngineConfiguration, days: Int = 30)
    async throws -> [VocabularySuggestion]
  {
    guard !config.geminiApiKey.isEmpty else { throw VocabularyAnalysisError.noAPIKey }
    let path = NSString(
      string: config.historyDbPath.isEmpty
        ? "~/Library/Application Support/Tok/history.db" : config.historyDbPath
    ).expandingTildeInPath
    let rows = try loadRows(dbPath: path, days: max(1, min(365, days)))
    guard rows.count >= 5 else { throw VocabularyAnalysisError.insufficientHistory }
    try Task.checkCancellation()
    let observed = loadCorrections(dbPath: path, days: days)
    // Item 2 (optional upgrade; see Engine/Judgment). This offline analysis run can afford
    // the one round trip the models probe costs; the live turn path never waits like this.
    let judgment = JudgmentService(apiKey: config.typesafeApiKey)
    _ = await judgment.awaitAvailability()
    let (retryPairs, jevConfirmedPairs) = await filterRetryPairs(
      findRetryPairs(rows), judgment: judgment)
    try Task.checkCancellation()
    let prompt = buildPrompt(
      rows: rows, pairs: retryPairs, observed: observed, config: config,
      confirmedRetryPairs: jevConfirmedPairs)
    let model = config.analyzeModel.isEmpty ? config.geminiModel : config.analyzeModel
    let raw = try await requestAnalysis(prompt: prompt, model: model, config: config)
    try Task.checkCancellation()
    var known = Set(config.customVocabulary.map { $0.lowercased() })
    for rule in config.replacementRules {
      known.insert(rule.wrong.lowercased())
      known.insert(rule.right.lowercased())
    }
    let suggestions = parseSuggestions(raw: raw, known: known)
    return await attachConfidence(suggestions, rows: rows, judgment: judgment)
  }
  private static func validComponent(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("#") && !value.contains("=>") && !value.contains(",")
      && value.rangeOfCharacter(from: .newlines) == nil
  }
  private static func requestAnalysis(prompt: String, model: String, config: EngineConfiguration)
    async throws -> [String: Any]
  {
    guard
      let url = URL(
        string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")
    else { throw VocabularyAnalysisError.invalidResponse }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(config.geminiApiKey, forHTTPHeaderField: "x-goog-api-key")
    request.httpBody = try JSONSerialization.data(withJSONObject: [
      "contents": [["parts": [["text": prompt]]]],
      "generationConfig": ["temperature": 0.2, "responseMimeType": "application/json"],
    ])
    let settings = URLSessionConfiguration.ephemeral
    settings.timeoutIntervalForRequest = 30
    settings.timeoutIntervalForResource = 45
    let session = URLSession(configuration: settings)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(for: request)
    guard let response = response as? HTTPURLResponse else {
      throw VocabularyAnalysisError.invalidResponse
    }
    guard (200...299).contains(response.statusCode) else {
      throw VocabularyAnalysisError.http(response.statusCode)
    }
    guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let candidates = json["candidates"] as? [[String: Any]],
      let content = candidates.first?["content"] as? [String: Any],
      let parts = content["parts"] as? [[String: Any]],
      let text = parts.first?["text"] as? String, let bytes = text.data(using: .utf8),
      let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    else { throw VocabularyAnalysisError.invalidResponse }
    return result
  }
  private static func loadRows(dbPath: String, days: Int) throws -> [Row] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle
    else {
      let msg =
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite3_open_v2 error"
      if let handle = handle { sqlite3_close(handle) }
      Log.error("ANALYZE", "Failed to open history DB: \(msg)")
      throw VocabularyAnalysisError.historyUnavailable
    }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "PRAGMA busy_timeout=2000;", nil, nil, nil)

    let sql = """
      SELECT ts_epoch, app_name, text FROM transcriptions
      WHERE outcome = 'success' AND text IS NOT NULL AND length(trim(text)) > 0 AND ts_epoch >= ?
      ORDER BY ts_epoch DESC LIMIT 500
      """
    var stmt: OpaquePointer?
    if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) != SQLITE_OK {
      // Legacy DB predating the app_name column: its ALTER runs on the app's write
      // path, which may not have happened since upgrading. Analyze without app context
      // rather than failing (NULL keeps the column indices aligned).
      sqlite3_finalize(stmt)
      stmt = nil
      let legacySql = """
        SELECT ts_epoch, NULL, text FROM transcriptions
        WHERE outcome = 'success' AND text IS NOT NULL AND length(trim(text)) > 0 AND ts_epoch >= ?
        ORDER BY ts_epoch DESC LIMIT 500
        """
      guard sqlite3_prepare_v2(db, legacySql, -1, &stmt, nil) == SQLITE_OK else {
        Log.error("ANALYZE", "Failed to query history: \(String(cString: sqlite3_errmsg(db)))")
        sqlite3_finalize(stmt)
        throw VocabularyAnalysisError.historyUnavailable
      }
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - Double(days) * 86400.0)

    // Cap the payload so a heavy month of dictation cannot balloon one analysis call;
    // rows are newest-first, so what gets dropped is the oldest history.
    var results: [Row] = []
    var budget = 300_000
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let cText = sqlite3_column_text(stmt, 2) else { continue }
      let text = String(cString: cText)
      if text.count > budget {
        Log.warn(
          "ANALYZE",
          "Payload cap reached - older transcripts beyond \(results.count) rows were dropped.")
        break
      }
      budget -= text.count
      let ts = sqlite3_column_double(stmt, 0)
      let app = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
      results.append(Row(ts: ts, app: app, text: text))
    }
    return results
  }

  // Lenient companion to loadRows: the corrections table only exists once
  // LEARN_CORRECTIONS has run, so a failed prepare on an older DB is expected silence,
  // not an error.
  private static func loadCorrections(dbPath: String, days: Int) -> [ObservedCorrection] {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle
    else {
      if let handle = handle { sqlite3_close(handle) }
      return []
    }
    defer { sqlite3_close(db) }
    sqlite3_exec(db, "PRAGMA busy_timeout=2000;", nil, nil, nil)

    let sql = """
      SELECT ts_epoch, wrong_text, right_text, app_name FROM corrections
      WHERE ts_epoch >= ? ORDER BY ts_epoch DESC LIMIT 200
      """
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
      sqlite3_finalize(stmt)
      return []
    }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - Double(days) * 86400.0)

    var results: [ObservedCorrection] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
      guard let cWrong = sqlite3_column_text(stmt, 1), let cRight = sqlite3_column_text(stmt, 2)
      else { continue }
      let app = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
      results.append(
        ObservedCorrection(
          ts: sqlite3_column_double(stmt, 0),
          wrong: String(cString: cWrong),
          right: String(cString: cRight),
          app: app
        ))
    }
    return results
  }

  // A near-identical dictation seconds after another usually means the user re-said a
  // mangled turn: the differing words are direct correction evidence. This pass is pure
  // recall over adjacent rows (rows arrive newest-first); the model judges whether each
  // pair is a correction or merely similar content.
  private static func findRetryPairs(_ rows: [Row]) -> [(older: Row, newer: Row)] {
    var pairs: [(older: Row, newer: Row)] = []
    for i in 0..<rows.count where i + 1 < rows.count {
      let newer = rows[i]
      let older = rows[i + 1]
      guard newer.ts - older.ts <= 120.0 else { continue }
      let a = tokenSet(older.text)
      let b = tokenSet(newer.text)
      guard !a.isEmpty, !b.isEmpty, a != b else { continue }
      let jaccard = Double(a.intersection(b).count) / Double(a.union(b).count)
      if jaccard >= 0.5 {
        pairs.append((older, newer))
      }
    }
    return pairs
  }

  private static func tokenSet(_ text: String) -> Set<String> {
    Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
  }

  // Item 2 (optional upgrade; see Engine/Judgment). With Jev available, judges each
  // recall-found retry pair with one noul and keeps only pairs >= retryPairThreshold,
  // reporting whether Jev was used at all (`jevConfirmed`) so buildPrompt can say so.
  // Without Jev (or with no pairs), returns the input unchanged - byte-for-byte identical
  // to today's prompt for that case.
  static func filterRetryPairs(
    _ pairs: [(older: Row, newer: Row)], judgment: JudgmentService
  ) async -> (pairs: [(older: Row, newer: Row)], jevConfirmed: Bool) {
    guard judgment.isAvailable, !pairs.isEmpty else { return (pairs, false) }
    // Bounded the same way buildPrompt's own prompt block already is.
    let capped = Array(pairs.prefix(20))
    var questions: [String: JudgmentQuestion] = [:]
    var stateItems: [String: JudgmentValue] = [:]
    for (index, pair) in capped.enumerated() {
      let id = "pair_\(index)"
      stateItems[id] = .object([
        "first": .string(pair.older.text), "second": .string(pair.newer.text),
      ])
      questions[id] = .noul(
        instructions: """
          Is `\(id).second` a re-dictation of `\(id).first` with the same intended content, \
          rather than merely similar content?
          """,
        criteria: [
          "true": "The speaker repeated the same intended sentence, e.g. after a misrecognition.",
          "false": "The content is topically similar but the intended meaning differs.",
        ])
    }
    let result = await judgment.ask(
      state: .object(stateItems), questions: questions, label: "retry_pairs")
    guard case .success(let response) = result else {
      if case .failure(let error) = result {
        Log.warn("Jev", "Retry-pair judgment failed: \(error.diagnosticDescription).")
      }
      return (pairs, false)
    }
    var kept: [(older: Row, newer: Row)] = []
    for (index, pair) in capped.enumerated() {
      guard case .noul(let value)? = response.answers["pair_\(index)"],
        value >= retryPairThreshold
      else { continue }
      kept.append(pair)
    }
    return (kept, true)
  }

  // Unevaluated threshold; must be tuned on real data.
  static let retryPairThreshold = 0.6

  // Internal, not private: VocabularySuggestionTests asserts the built prompt
  // carries no timestamp pattern (audit F32).
  static func buildPrompt(
    rows: [Row], pairs: [(older: Row, newer: Row)], observed: [ObservedCorrection],
    config: EngineConfiguration, confirmedRetryPairs: Bool = false
  ) -> String {
    var existing: [String] = config.customVocabulary
    existing.append(contentsOf: config.replacementRules.map { "\($0.wrong) => \($0.right)" })
    let existingBlock = existing.isEmpty ? "(none)" : existing.joined(separator: "\n")

    // Audit F32: timestamps add no value to term suggestions (re-dictation pairs
    // are already found locally by findRetryPairs, above) and were sent to Gemini
    // without disclosure. Only the app name goes out, and PRIVACY.md and the
    // VocabularyView confirmation both now say so.
    let transcriptBlock = rows.map { row in
      let app = row.app.isEmpty ? "?" : row.app
      return "[\(app)] \(row.text)"
    }.joined(separator: "\n")

    // Cap the pair block: pairs duplicate transcript text, and 20 is already far more
    // correction evidence than one session needs.
    let pairBlock =
      pairs.isEmpty
      ? "(none)"
      : pairs.prefix(20).map { p in
        let confirmed = confirmedRetryPairs ? "\nConfirmed as a genuine re-dictation by Jev." : ""
        return "A: \(p.older.text)\nB: \(p.newer.text)\(confirmed)"
      }.joined(separator: "\n---\n")

    let contextBlock =
      config.analyzeContext.isEmpty
      ? ""
      : "\nABOUT THE USER (use this to judge what a garbled phrase plausibly meant):\n\(config.analyzeContext)\n"

    let observedBlock =
      observed.isEmpty
      ? "(none)"
      : observed.map { c in
        let app = c.app.isEmpty ? "?" : c.app
        return "\"\(c.wrong)\" -> \"\(c.right)\" (\(app))"
      }.joined(separator: "\n")

    return """
      You are analyzing a user's voice-dictation history to improve their speech-to-text setup.
      Below are their recent transcriptions (newest first, each prefixed with the app dictated into), their EXISTING custom vocabulary, and detected re-dictation pairs.
      \(contextBlock)
      Find two things:
      1. "vocabulary": domain terms the user says repeatedly that a recognizer is likely to mangle - product names, people/company names, acronyms, technical jargon, non-English words. These become recognition-boost hints. Judge by repetition across MANY transcripts, only suggest terms actually present in the transcripts, and never repeat a term already in the existing vocabulary.
      2. "replacements": misrecognitions, fixed later by deterministic "wrong => right" rules.
         - The existing vocabulary is your primary target list: hunt for garbled or phonetic variants of exactly those terms (e.g. "cloud code" when the vocabulary has "Claude Code").
         - The wrong form must appear verbatim in the transcriptions. The right form does NOT have to appear anywhere - infer it from the existing vocabulary, the app column, the user description, and world knowledge.
         - A single occurrence is enough when the intended term is unambiguous in its sentence; otherwise require repetition.
         - In a re-dictation pair, the words differing between A and B are usually the correction (B is what the user meant).
         - The OBSERVED TYPED CORRECTIONS are ground truth (the user manually fixed the pasted text): propose each as a rule unless already covered by the existing vocabulary or clearly a one-off contextual edit.
         - Never suggest a rule for grammar, style, punctuation, or capitalization-only differences - only real word substitutions.
         - Each side at most 4 words, and only propose a rule if this user would essentially never mean the wrong form literally: the rule fires on every future dictation.

      Hard rules:
      - At most 15 vocabulary terms and 10 replacements; fewer is better than padded.
      - Each reason is at most 12 words and cites the evidence (e.g. "appears 9 times", "re-dictation pair", "vocabulary term 'Claude Code' garbled").
      - If there is nothing worth suggesting, return empty arrays.

      Respond with strict JSON only, exactly this shape:
      {"vocabulary": [{"term": "", "reason": ""}], "replacements": [{"wrong": "", "right": "", "reason": ""}]}

      EXISTING VOCABULARY:
      \(existingBlock)

      RE-DICTATION PAIRS (older A, then newer B):
      \(pairBlock)

      OBSERVED TYPED CORRECTIONS (the user edited the pasted text; ground truth):
      \(observedBlock)

      TRANSCRIPTIONS:
      \(transcriptBlock)
      """
  }

  static func parseSuggestions(raw: [String: Any], known: Set<String>) -> [VocabularySuggestion] {
    var suggestions: [VocabularySuggestion] = []
    var seen = Set<String>()

    if let vocab = raw["vocabulary"] as? [[String: Any]] {
      for entry in vocab.prefix(15) {
        guard
          let term = (entry["term"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          validComponent(term), term.count <= 60
        else { continue }
        let key = term.lowercased()
        if known.contains(key) || seen.contains(key) { continue }
        seen.insert(key)
        let reason = (entry["reason"] as? String) ?? ""
        suggestions.append(VocabularySuggestion(line: term, reason: reason))
      }
    }
    if let rules = raw["replacements"] as? [[String: Any]] {
      for entry in rules.prefix(10) {
        guard
          let wrong = (entry["wrong"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          let right = (entry["right"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
          validComponent(wrong), validComponent(right), wrong.lowercased() != right.lowercased(),
          wrong.count <= 80, right.count <= 80,
          // Wispr Flow-style phrase cap: long rules are almost never a true
          // misrecognition and fire too broadly to be safe.
          wrong.split(separator: " ").count <= 4, right.split(separator: " ").count <= 4,
          !wrong.contains("=>"), !right.contains("=>")
        else { continue }
        let key = wrong.lowercased()
        if known.contains(key) || seen.contains(key) { continue }
        seen.insert(key)
        let reason = (entry["reason"] as? String) ?? ""
        suggestions.append(VocabularySuggestion(line: "\(wrong) => \(right)", reason: reason))
      }
    }
    return suggestions
  }

  // Item 2 (optional upgrade; see Engine/Judgment). For each proposed replacement rule, asks
  // Jev a 4-level risk score (normalized 0...1, safest = 1) using up to 3 transcript excerpts
  // where the wrong side appears; for each proposed vocabulary term, asks a single noul on
  // whether it is worth boosting. Returns suggestions unchanged (nil confidence, original
  // order) when Jev is unavailable or there is nothing to judge.
  static func attachConfidence(
    _ suggestions: [VocabularySuggestion], rows: [Row], judgment: JudgmentService
  ) async -> [VocabularySuggestion] {
    guard judgment.isAvailable, !suggestions.isEmpty else { return suggestions }
    let items = suggestions.enumerated().map { index, suggestion in
      confidenceItem(id: "item_\(index)", suggestion: suggestion, rows: rows)
    }
    var confidenceById: [String: Double] = [:]
    for chunk in chunkedByEstimatedTokens(items) {
      // Cancel stops at the next chunk: no further excerpts leave after the user stops.
      if Task.isCancelled { break }
      let state = JudgmentValue.object(
        Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, $0.state) }))
      let questions = Dictionary(uniqueKeysWithValues: chunk.map { ($0.id, $0.question) })
      let result = await judgment.ask(
        state: state, questions: questions, label: "vocabulary_confidence")
      guard case .success(let response) = result else {
        if case .failure(let error) = result {
          Log.warn(
            "Jev",
            "Suggestion confidence failed for \(chunk.count) items: \(error.diagnosticDescription)."
          )
        }
        continue
      }
      for item in chunk {
        guard let confidence = confidence(for: item.kind, answer: response.answers[item.id]) else {
          continue
        }
        confidenceById[item.id] = confidence
      }
    }
    guard !confidenceById.isEmpty else { return suggestions }
    let updated = suggestions.enumerated().map { index, suggestion in
      VocabularySuggestion(
        line: suggestion.line, reason: suggestion.reason,
        confidence: confidenceById["item_\(index)"])
    }
    // Suggestions without a confidence (e.g. a chunk that failed) sort after those with one,
    // in their original relative order.
    return updated.enumerated().sorted { lhs, rhs in
      switch (lhs.element.confidence, rhs.element.confidence) {
      case (let l?, let r?): return l != r ? l > r : lhs.offset < rhs.offset
      case (nil, nil): return lhs.offset < rhs.offset
      case (nil, _): return false
      case (_, nil): return true
      }
    }.map(\.element)
  }

  private enum ConfidenceKind {
    case vocabularyTerm
    case replacementRule(levels: Int)
  }

  private struct ConfidenceItem {
    let id: String
    let state: JudgmentValue
    let question: JudgmentQuestion
    let kind: ConfidenceKind
    let estimatedTokens: Int
  }

  // Ordered lowest to highest, so the TypeSafe score runs 0 (would corrupt) to 3 (safe).
  // "left side" matches the wording of the question that carries these levels.
  private static let ruleRiskLevels = [
    "would corrupt correct text: the left side is a real word or phrase that appears legitimately",
    "risky: the left side is plausible dictation in some contexts",
    "mostly safe: the left side is rarely intended",
    "safe: the left side is never intended speech, only a misrecognition",
  ]

  private static func confidenceItem(id: String, suggestion: VocabularySuggestion, rows: [Row])
    -> ConfidenceItem
  {
    if let arrow = suggestion.line.range(of: " => ") {
      let wrong = String(suggestion.line[..<arrow.lowerBound])
      let right = String(suggestion.line[arrow.upperBound...])
      let excerpts = rows.filter { $0.text.localizedCaseInsensitiveContains(wrong) }.prefix(3)
        .map(\.text)
      let state = JudgmentValue.object([
        "rule": .string("\(wrong) => \(right)"),
        "excerpts": .array(excerpts.map { .string($0) }),
      ])
      let question = JudgmentQuestion.score(
        instructions:
          "`\(id).rule` would be applied as an always-on replacement rule to every future dictation, rewriting its left side wherever it appears. `\(id).excerpts` holds past transcripts containing that left side. Pick the level that describes how safe that rule is.",
        criteria: ruleRiskLevels)
      let estimate = (wrong.count + right.count + excerpts.reduce(0) { $0 + $1.count }) / 4 + 60
      return ConfidenceItem(
        id: id, state: state, question: question,
        kind: .replacementRule(levels: ruleRiskLevels.count), estimatedTokens: estimate)
    }
    let state = JudgmentValue.object(["term": .string(suggestion.line)])
    let question = JudgmentQuestion.noul(
      instructions:
        "Is `\(id).term` a term worth boosting for speech recognition - a proper noun, product name, jargon, or acronym - rather than a common word?"
    )
    let estimate = suggestion.line.count / 4 + 40
    return ConfidenceItem(
      id: id, state: state, question: question, kind: .vocabularyTerm, estimatedTokens: estimate)
  }

  // TypeSafe scores are 0-indexed over the level list: a 4-level question answers in 0...3,
  // as a probability-weighted mean of the level positions (docs.typesafe.ai/primitives/score).
  // Normalizing therefore divides by the top level index, not by it minus one.
  private static func confidence(for kind: ConfidenceKind, answer: JudgmentAnswer?) -> Double? {
    switch (kind, answer) {
    case (.vocabularyTerm, .noul(let value)?):
      return value
    case (.replacementRule(let levels), .score(let value, _)?) where levels > 1:
      return min(1, max(0, value / Double(levels - 1)))
    default:
      return nil
    }
  }

  // Keeps each judgment request's state under ~8k estimated tokens (CLAUDE.md/spec budget),
  // splitting into multiple sequential requests only when the fan-out is large enough to
  // need it. `analyze()` already caps suggestions at 15 vocabulary + 10 replacements, so a
  // single chunk is the common case.
  private static func chunkedByEstimatedTokens(
    _ items: [ConfidenceItem], budget: Int = 8000
  ) -> [[ConfidenceItem]] {
    var chunks: [[ConfidenceItem]] = []
    var current: [ConfidenceItem] = []
    var used = 0
    for item in items {
      if !current.isEmpty && used + item.estimatedTokens > budget {
        chunks.append(current)
        current = []
        used = 0
      }
      current.append(item)
      used += item.estimatedTokens
    }
    if !current.isEmpty { chunks.append(current) }
    return chunks
  }
}
