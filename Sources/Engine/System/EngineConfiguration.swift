import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

public struct EngineConfiguration {
  public init() {}
  public var geminiApiKey: String = ""
  public var geminiModel: String = "gemini-3.5-flash-lite"
  public var geminiLiveModel: String = "gemini-3.5-transcribe-live"
  public var smartTranscription: Bool = true
  // Region-qualified BCP-47 codes, matching the live-transcribe language table (en-IN, mr-IN,
  // hi-IN, ...). Bare "en"/"mr" is not what the documented table lists.
  public var languageCodes: [String] = ["en-IN", "mr-IN"]
  public var customVocabulary: [String] = []
  public var customVocabularyFile: String = ""
  var replacementRules: [ReplacementRule] = []
  // Sorted + regex-compiled form of replacementRules, built once at load (the raw rules
  // stay around for display and the analyzer).
  var compiledReplacementRules: [ReplacementEngine.CompiledRule] = []
  public var hotkey: String = "fn"
  public var hotkeyMode: String = "push_to_talk"  // "push_to_talk" or "toggle"
  // Hold-to-lock: a hold this long (seconds) locks the turn - the release becomes a
  // non-event and the next press finishes. 0 disables; ignored in toggle mode.
  public var holdToLockSec: Double = 15.0
  // Seconds a locked turn may run before it finishes on its own (a forgotten open mic).
  public var lockLimitSec: Double = 120.0
  public var soundFeedback: Bool = true
  // Soft tick at key release - acknowledges the hold ended while the transcript settles
  // (there can be seconds of silence before the commit earcon on a slow REST fallback).
  public var releaseSound: Bool = true
  public var showHUD: Bool = true
  // Put the HUD on the display holding the frontmost app's focused window (pointer as
  // fallback) rather than always on the menu-bar/notch display. Resolved once per key-down.
  public var hudFollowFocus: Bool = true
  // HUD pill entrance animation: "slide" (shipped default), "bloom", "drift", "unfurl",
  // "morph" (Dynamic Island membrane; needs a physical notch, else falls back to slide).
  public var hudRevealStyle: String = "slide"
  // Ambient particle motes under the notch while listening (CAEmitterLayer, GPU-composited;
  // skipped under Reduce Motion).
  public var hudParticles: Bool = true
  // Screen-share privacy: the pill is hidden entirely (aura glow + earcons carry all
  // state) and the terminal prints only a char count. Paste still happens; the history
  // DB still records locally.
  public var privacyMode: Bool = false
  // Duck the system output while recording so music/video on speakers doesn't bleed into
  // the mic (hurting accuracy and billing audio tokens for it). Opt-in: changing the output
  // volume uninvited is surprising.
  public var duckAudio: Bool = false
  // Fraction of the current output volume kept while ducked (0.2 = drop to 20%).
  public var duckFraction: Double = 0.2
  public var enableLiveWebSocket: Bool = true
  public var restFallbackTimeout: Double = 4.0
  public var preRollMs: Int = 400
  // Capture device: empty = system default input; "auto" = built-in mic while the lid is
  // open, an external one while closed (re-evaluated on lid flips); otherwise an exact
  // CoreAudio UID or a case-insensitive name substring ("studio" -> "Studio Display
  // Microphone"); see --list-inputs. Unmatched falls back to the default with a warning.
  public var inputDevice: String = ""
  // 250ms default: people release the key while the last word is still leaving their mouth;
  // audio keeps streaming during the grace period, so the only cost is commit latency.
  public var postRollMs: Int = 250
  // Adaptive trailing capture: after key release, audio keeps streaming while speech energy
  // is still present; the turn commits once the mic has been quiet for postRollMs
  // continuously, hard-capped at postRollMaxMs. Set equal to postRollMs (or 0) to disable
  // adaptation and get the old fixed post-roll.
  public var postRollMaxMs: Int = 1500
  // RMS dBFS below which the mic is considered quiet (speech typically -30 to -15, room
  // noise -50 to -60 on this meter).
  public var trailSilenceDb: Double = -40.0
  // "manual" (PTT key defines speech bounds), "tuned", or "auto"
  public var vadMode: String = "manual"
  public var vadSilenceMs: Int = 1500
  // A/B knobs for aligning the Live protocol with the dedicated transcribe docs. Defaults
  // preserve shipped behavior; flip individually on the Mac and compare per-turn latency
  // diagnostics (and last-word accuracy for the silence flush) before adopting.
  //
  // Aligned endpointing sends only the documented end-of-turn signal for transcribe models
  // (manual VAD -> activityEnd; auto/tuned -> audioStreamEnd) instead of the legacy
  // audioStreamEnd + activityEnd + clientContent.turnComplete triple.
  public var wsEndpointAligned: Bool = false
  // Streaming chunk size; docs recommend ~100ms for the dedicated model (150 = shipped).
  public var chunkMs: Int = 150
  // Synthetic trailing silence appended after key-up so the speech encoder's lookahead
  // window can finalize the last word. 0 disables it entirely.
  public var silenceFlushMs: Int = 700
  // Release the mic (status-bar indicator off) after this many seconds without a dictation;
  // the next key-down re-arms it. 0 = keep the mic always on (lowest latency, indicator lit).
  public var micIdleTimeoutSec: Int = 300
  // Token pricing (USD per 1M tokens), used only for the per-dictation cost line in the
  // diagnostics. Defaults match Aug 2026 public-preview pricing for the two default models.
  public var liveInputPricePer1M: Double = 3.50  // gemini-3.5-transcribe-live audio input
  public var liveOutputPricePer1M: Double = 21.00  // gemini-3.5-transcribe-live text output
  public var restInputPricePer1M: Double = 0.30  // gemini-3.5-flash-lite input
  public var restOutputPricePer1M: Double = 2.50  // gemini-3.5-flash-lite output
  public var restoreClipboard: Bool = true
  // Append one trailing space to the injected/copied payload so back-to-back dictations
  // don't fuse ("...are you?Are you..."). Logs, HUD, and history keep the unpadded text.
  public var trailingSpace: Bool = true
  public var logLevel: String = "verbose"
  // Local dictation history (SQLite). Every turn - success, empty, or error - becomes one row
  // so usage/latency/cost can be analyzed later. Plaintext on disk; disable with HISTORY=false.
  public var historyEnabled: Bool = true
  public var historyDbPath: String = ""  // empty = ~/Library/Application Support/Tok/history.db
  // Git commit id (short SHA, or "-dirty" suffixed) stamped by the `justspeak` runner via
  // JUSTSPEAK_BUILD  -  not a .env knob, so it's read only from the process environment below.
  public var buildId: String = ""
  // Analyzer-only knobs (--analyze / make analyze). Analysis is rare and offline, so it
  // can afford a stronger model than the REST fallback; empty falls back to GEMINI_MODEL.
  public var analyzeModel: String = "gemini-3.7-flash"
  // Free-text persona for the analysis prompt ("solutions architect at ...; daily terms:
  // GCP services, AI products") so the model can judge what a garbled phrase plausibly
  // meant. Also settable as "# context: ..." lines in the vocabulary file; the knob wins.
  public var analyzeContext: String = ""
  // Opt-in typed-correction capture: after a paste, read the focused field back once via
  // the Accessibility API and record gated single-word edits ("cloud" -> "Claude") to the
  // corrections table for `make analyze`. Off by default: it reads field content (only the
  // changed word pairs are ever stored or shown).
  public var learnCorrections: Bool = false
  // paste-to-read-back delay; the user needs time to notice and fix
  public var learnDelayMs: Int = 8000

  static func parseVocabulary(from text: String) -> [String] {
    var items: [String] = []
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
      if let data = trimmed.data(using: .utf8),
        let arr = try? JSONSerialization.jsonObject(with: data) as? [String]
      {
        return arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
      }
    }

    let lines = text.components(separatedBy: .newlines)
    for line in lines {
      let cleanLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if cleanLine.isEmpty || cleanLine.hasPrefix("#") { continue }

      if cleanLine.contains(",") {
        let parts = cleanLine.components(separatedBy: ",")
        for part in parts {
          let cleaned = part.trimmingCharacters(in: .whitespacesAndNewlines)
          if !cleaned.isEmpty && !cleaned.hasPrefix("#") {
            items.append(cleaned)
          }
        }
      } else {
        items.append(cleanLine)
      }
    }
    return items
  }

  // "# context: ..." lines in the vocabulary file describe the dictating user for the
  // analyzer prompt. parseVocabulary already skips them as comments, so the directive
  // rides in the same file without affecting recognition. Multiple lines join with a space.
  static func parseContextDirective(from text: String) -> String {
    var parts: [String] = []
    for line in text.components(separatedBy: .newlines) {
      let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
      let lower = cleaned.lowercased()
      guard lower.hasPrefix("# context:") || lower.hasPrefix("#context:") else { continue }
      guard let colon = cleaned.firstIndex(of: ":") else { continue }
      let value = String(cleaned[cleaned.index(after: colon)...]).trimmingCharacters(
        in: .whitespaces)
      if !value.isEmpty { parts.append(value) }
    }
    return parts.joined(separator: " ")
  }

  // Splits raw vocabulary items into plain boost terms and "wrong => right" replacement
  // rules (first "=>" wins; either side empty after trim discards the item). Rules are
  // deduped by lowercased "wrong", first occurrence wins - matching the boost-term dedupe.
  static func splitVocabularyItems(_ items: [String]) -> (vocab: [String], rules: [ReplacementRule])
  {
    var vocab: [String] = []
    var rules: [ReplacementRule] = []
    var seenWrong = Set<String>()
    for item in items {
      guard let arrow = item.range(of: "=>") else {
        vocab.append(item)
        continue
      }
      let wrong = item[item.startIndex..<arrow.lowerBound].trimmingCharacters(
        in: .whitespacesAndNewlines)
      let right = item[arrow.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
      if wrong.isEmpty || right.isEmpty { continue }
      let key = wrong.lowercased()
      if seenWrong.contains(key) { continue }
      seenWrong.insert(key)
      rules.append(ReplacementRule(wrong: wrong, right: right))
    }
    return (vocab, rules)
  }

  // Canonical BCP-47 casing: language lowercase, script Titlecase, region UPPERCASE
  // ("en-in" -> "en-IN", "pa-guru-in" -> "pa-Guru-IN"). The live-transcribe language table
  // uses region-qualified codes with this casing, so normalize instead of lowercasing away.
  static func normalizeLanguageCode(_ raw: String) -> String {
    let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "-")
    return parts.enumerated().map { idx, part in
      let s = String(part)
      if idx == 0 { return s.lowercased() }
      if s.count == 4 { return s.prefix(1).uppercased() + s.dropFirst().lowercased() }
      return s.uppercased()
    }.joined(separator: "-")
  }

  public static func load(values: [String: String], vocabularyText: String? = nil)
    -> EngineConfiguration
  {
    var config = EngineConfiguration()
    var inlineVocabRaw = ""
    var vocabFile = ""
    var rawLanguages: String?
    for (key, value) in values {
      switch key {
      case "GEMINI_API_KEY": config.geminiApiKey = value
      case "GEMINI_MODEL": config.geminiModel = value
      case "GEMINI_LIVE_MODEL": config.geminiLiveModel = value
      case "SMART_TRANSCRIPTION":
        config.smartTranscription = (value.lowercased() == "true" || value == "1")
      case "LANGUAGE_CODES": rawLanguages = value
      case "CUSTOM_VOCABULARY": inlineVocabRaw = value
      case "CUSTOM_VOCABULARY_FILE": vocabFile = value
      case "HOTKEY": config.hotkey = value.lowercased()
      case "HOTKEY_MODE": config.hotkeyMode = value.lowercased()
      case "HOLD_TO_LOCK":
        if let s = Double(value) { config.holdToLockSec = min(60.0, max(0.0, s)) }
      case "LOCK_LIMIT": if let s = Double(value) { config.lockLimitSec = min(600.0, max(0.0, s)) }
      case "SOUND_FEEDBACK": config.soundFeedback = (value.lowercased() == "true" || value == "1")
      case "RELEASE_SOUND": config.releaseSound = (value.lowercased() == "true" || value == "1")
      case "SHOW_HUD": config.showHUD = (value.lowercased() == "true" || value == "1")
      case "HUD_FOLLOW_FOCUS":
        config.hudFollowFocus = (value.lowercased() == "true" || value == "1")
      case "INPUT_DEVICE": config.inputDevice = value
      case "HUD_REVEAL":
        if ["slide", "bloom", "drift", "unfurl", "morph"].contains(value.lowercased()) {
          config.hudRevealStyle = value.lowercased()
        }
      case "HUD_PARTICLES": config.hudParticles = (value.lowercased() == "true" || value == "1")
      case "PRIVACY_MODE": config.privacyMode = (value.lowercased() == "true" || value == "1")
      case "DUCK_AUDIO": config.duckAudio = (value.lowercased() == "true" || value == "1")
      case "DUCK_FRACTION": if let f = Double(value) { config.duckFraction = min(1.0, max(0.0, f)) }
      case "ENABLE_LIVE_WEBSOCKET":
        config.enableLiveWebSocket = (value.lowercased() == "true" || value == "1")
      case "RESTORE_CLIPBOARD":
        config.restoreClipboard = (value.lowercased() == "true" || value == "1")
      case "TRAILING_SPACE": config.trailingSpace = (value.lowercased() == "true" || value == "1")
      case "REST_FALLBACK_TIMEOUT": if let t = Double(value) { config.restFallbackTimeout = t }
      case "PRE_ROLL_MS": if let ms = Int(value) { config.preRollMs = min(1000, max(0, ms)) }
      case "POST_ROLL_MS": if let ms = Int(value) { config.postRollMs = min(500, max(0, ms)) }
      case "POST_ROLL_MAX_MS":
        if let ms = Int(value) { config.postRollMaxMs = min(5000, max(0, ms)) }
      case "TRAIL_SILENCE_DB":
        if let db = Double(value) { config.trailSilenceDb = min(-10.0, max(-80.0, db)) }
      case "VAD_MODE":
        if ["manual", "tuned", "auto"].contains(value.lowercased()) {
          config.vadMode = value.lowercased()
        }
      case "VAD_SILENCE_MS":
        if let ms = Int(value) { config.vadSilenceMs = min(5000, max(200, ms)) }
      case "WS_ENDPOINT_ALIGNED":
        config.wsEndpointAligned = (value.lowercased() == "true" || value == "1")
      case "CHUNK_MS": if let ms = Int(value) { config.chunkMs = min(500, max(20, ms)) }
      case "SILENCE_FLUSH_MS":
        if let ms = Int(value) { config.silenceFlushMs = min(2000, max(0, ms)) }
      case "MIC_IDLE_TIMEOUT":
        if let sec = Int(value) { config.micIdleTimeoutSec = min(7200, max(0, sec)) }
      case "HISTORY": config.historyEnabled = (value.lowercased() == "true" || value == "1")
      case "HISTORY_DB": config.historyDbPath = value
      case "ANALYZE_MODEL": config.analyzeModel = value
      case "ANALYZE_CONTEXT": config.analyzeContext = value
      case "LEARN_CORRECTIONS":
        config.learnCorrections = (value.lowercased() == "true" || value == "1")
      case "LEARN_DELAY_MS":
        if let ms = Int(value) { config.learnDelayMs = min(60000, max(2000, ms)) }
      case "LIVE_INPUT_PRICE_PER_1M":
        if let p = Double(value), p >= 0 { config.liveInputPricePer1M = p }
      case "LIVE_OUTPUT_PRICE_PER_1M":
        if let p = Double(value), p >= 0 { config.liveOutputPricePer1M = p }
      case "REST_INPUT_PRICE_PER_1M":
        if let p = Double(value), p >= 0 { config.restInputPricePer1M = p }
      case "REST_OUTPUT_PRICE_PER_1M":
        if let p = Double(value), p >= 0 { config.restOutputPricePer1M = p }
      case "LOG_LEVEL": config.logLevel = value.lowercased()
      default: break
      }
    }
    if let raw = rawLanguages {
      let parsedLangs = raw.components(separatedBy: ",")
        .map { normalizeLanguageCode($0) }
        .filter { !$0.isEmpty }
      if parsedLangs.contains("auto") || parsedLangs.contains("all") {
        config.languageCodes = []
      } else if !parsedLangs.isEmpty {
        config.languageCodes = parsedLangs
      }
    }

    config.customVocabularyFile = vocabFile

    var combinedVocab: [String] = []
    if !inlineVocabRaw.isEmpty {
      combinedVocab.append(contentsOf: parseVocabulary(from: inlineVocabRaw))
    }

    if let content = vocabularyText {
      combinedVocab.append(contentsOf: parseVocabulary(from: content))
      if config.analyzeContext.isEmpty {
        config.analyzeContext = parseContextDirective(from: content)
      }
    }
    // Pull "wrong => right" replacement rules out of the raw items; the right-hand side
    // still boosts recognition - never the wrong form, which would just teach the
    // recognizer to keep mishearing it the same way.
    let vocabSplit = splitVocabularyItems(combinedVocab)
    config.replacementRules = vocabSplit.rules
    config.compiledReplacementRules = ReplacementEngine.compile(vocabSplit.rules)
    combinedVocab = vocabSplit.vocab + vocabSplit.rules.map { $0.right }

    // Deduplicate while preserving order
    var seen = Set<String>()
    var deduped: [String] = []
    for word in combinedVocab {
      let normalized = word.trimmingCharacters(in: .whitespacesAndNewlines)
      if !normalized.isEmpty && !seen.contains(normalized.lowercased()) {
        seen.insert(normalized.lowercased())
        deduped.append(normalized)
      }
    }
    config.customVocabulary = deduped

    Log.isVerbose = (config.logLevel == "verbose")
    return config
  }
}
