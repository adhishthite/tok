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
    let prompt = buildPrompt(
      rows: rows, pairs: findRetryPairs(rows), observed: observed, config: config)
    let model = config.analyzeModel.isEmpty ? config.geminiModel : config.analyzeModel
    let raw = try await requestAnalysis(prompt: prompt, model: model, config: config)
    try Task.checkCancellation()
    var known = Set(config.customVocabulary.map { $0.lowercased() })
    for rule in config.replacementRules {
      known.insert(rule.wrong.lowercased())
      known.insert(rule.right.lowercased())
    }
    return parseSuggestions(raw: raw, known: known)
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

  // Internal, not private: VocabularySuggestionTests asserts the built prompt
  // carries no timestamp pattern (audit F32).
  static func buildPrompt(
    rows: [Row], pairs: [(older: Row, newer: Row)], observed: [ObservedCorrection],
    config: EngineConfiguration
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
        "A: \(p.older.text)\nB: \(p.newer.text)"
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

}
