import Foundation

/// Item 3: a per-turn quality signal. After a turn's transcript has been delivered (pasted or
/// copy-only) and its history row inserted, asks Jev four quick questions about the transcript
/// and writes the answers back onto that row. Fire-and-forget from `JudgmentService`'s own
/// queue - never `sessionQueue`, never main - so it can never delay the next turn.
enum TranscriptQualityJudge {
  static func assess(
    rowid: Int64, transcript: String, appName: String?, appBundleId: String?,
    judgment: JudgmentService, history: HistoryStore
  ) {
    // Runs on JudgmentService's own queue, never the history queue that called this, and
    // never sessionQueue or main.
    judgment.queue.async {
      performAssessment(
        rowid: rowid, transcript: transcript, appName: appName, appBundleId: appBundleId,
        judgment: judgment, history: history)
    }
  }

  private static func performAssessment(
    rowid: Int64, transcript: String, appName: String?, appBundleId: String?,
    judgment: JudgmentService, history: HistoryStore
  ) {
    let state = JudgmentValue.object([
      "transcript": .string(transcript),
      "app": .object([
        "name": .string(appName ?? ""),
        "bundle_id": .string(appBundleId ?? ""),
      ]),
    ])
    let questions: [String: JudgmentQuestion] = [
      "filler": .noul(
        instructions:
          "Is `transcript` a hallucinated filler or greeting produced from silence or background noise, rather than dictated content the speaker meant to send?",
        criteria: [
          "true":
            "Hallucinated filler with no dictated content, e.g. a stray \"thank you\" or \"okay\" from silence.",
          "false":
            "Genuine dictated content, however short, e.g. \"send it\" or \"ok merging now\".",
        ]),
      // Stored raw in history as jev_plausibility: a 0-indexed position on these four
      // levels, so 0...3, not a 0...1 fraction.
      "plausibility": .score(
        instructions:
          "How clean is `transcript` as a piece of dictated text, independent of topic?",
        criteria: [
          "garbled: mostly nonsense words or broken fragments, not readable as intended speech",
          "partly garbled: readable in places but with clear misrecognition damage",
          "mostly clean: readable and coherent with at most small recognition slips",
          "clean dictation: readable, coherent, and free of obvious recognition errors",
        ]),
      "register": .choice(
        instructions: "What register is `transcript` written in?",
        criteria: [
          "chat": "A casual conversational message, e.g. to a person over chat or email.",
          "prose": "Formal or considered writing: a document, report, or article passage.",
          "code": "Source code, a shell command, or a technical identifier-heavy snippet.",
          "command":
            "An instruction addressed to an assistant or application, e.g. \"open settings\".",
          "other": "None of the above fit well.",
        ]),
      "language": .choice(
        instructions: "What language is `transcript` written in?",
        criteria: [
          "english": "Entirely or almost entirely English.",
          "hindi": "Entirely or almost entirely Hindi.",
          "marathi": "Entirely or almost entirely Marathi.",
          "mixed": "A mix of two or more languages within the same transcript.",
          "other": "A language other than English, Hindi, or Marathi.",
        ]),
    ]
    let start = ProcessInfo.processInfo.systemUptime
    judgment.ask(state: state, questions: questions, label: "transcript_quality") { result in
      let response: JudgmentResponse
      switch result {
      case .success(let value):
        response = value
      // .unavailable means the gate is simply closed, which is the normal no-key state and
      // never worth a line; any other failure is a real integration problem, so it is logged.
      case .failure(.unavailable):
        return
      case .failure(let error):
        Log.warn("Jev", "Transcript quality judgment failed: \(error.diagnosticDescription).")
        return
      }
      let ms = Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
      var filler: Double?
      var plausibility: Double?
      var register: String?
      var language: String?
      if case .noul(let value)? = response.answers["filler"] { filler = value }
      if case .score(let value, _)? = response.answers["plausibility"] { plausibility = value }
      if case .choice(let value, _)? = response.answers["register"] { register = value }
      if case .choice(let value, _)? = response.answers["language"] { language = value }
      // A 200 that yields nothing usable means the answer shapes changed under us; that is a
      // broken integration, not a normal outcome, so it gets a line instead of a NULL row.
      if filler == nil, plausibility == nil, register == nil, language == nil {
        Log.warn("Jev", "Transcript quality response carried no usable answers.")
        return
      }
      history.updateJudgment(
        rowid: rowid, filler: filler, plausibility: plausibility, register: register,
        language: language, model: response.model, ms: ms, inputTokens: response.usage.inputTokens)
    }
  }
}
