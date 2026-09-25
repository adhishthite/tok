import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

public struct EngineConfiguration: Sendable {
  public init() {}
  public var geminiApiKey: String = ""
  // Optional upgrade (see Engine/Judgment): active only when this key is set AND a one-time
  // models probe succeeds. Not a SettingCatalog row - lives in Keychain only, mirroring
  // geminiApiKey exactly.
  public var typesafeApiKey: String = ""
  public var geminiModel: String = "gemini-3.5-flash-lite"
  public var geminiLiveModel: String = "gemini-3.5-transcribe-live"
  public var smartTranscription: Bool = true
  public var postProcessEnabled = false
  public var postProcessAppContext = false
  public var postProcessModel = "gemini-3.5-flash-lite"
  public var postProcessTimeoutMs = 2500
  public var postProcessInputPricePer1M = 0.30
  public var postProcessOutputPricePer1M = 2.50
  // Region-qualified BCP-47 codes, matching the live-transcribe language table (en-IN, mr-IN,
  // hi-IN, ...). Bare "en"/"mr" is not what the documented table lists.
  public var languageCodes: [String] = ["en-IN", "hi-IN", "mr-IN"]
  public var customVocabulary: [String] = []
  /// The service accepts at most this many vocabulary terms per request.
  public static let vocabularyLimit = 1000
  /// The documented sweet spot; more terms dilute the bias.
  public static let vocabularyRecommended = 100
  /// The terms sent with recognition requests: the first `vocabularyLimit` entries.
  /// `customVocabulary` itself stays complete for the analyzer and correction watcher.
  public var recognitionVocabulary: [String] {
    Array(customVocabulary.prefix(Self.vocabularyLimit))
  }
  /// Terms beyond the limit that recognition requests leave out.
  public var customVocabularyDropped: Int { max(0, customVocabulary.count - Self.vocabularyLimit) }
  public var customVocabularyFile: String = ""
  var replacementRules: [ReplacementRule] = []
  // Sorted + regex-compiled form of replacementRules, built once at load (the raw rules
  // stay around for display and the analyzer).
  var compiledReplacementRules: [ReplacementEngine.CompiledRule] = []
  public var hotkey: String = "fn"
  public var hotkeyMode: String = "push_to_talk"  // "push_to_talk" or "toggle"
  /// Human label for the shortcut key, shared by the HUD, the menu panel, and messages.
  public var shortcutLabel: String {
    hotkey == "fn" ? "Fn" : hotkey.replacingOccurrences(of: "_", with: " ").capitalized
  }
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
  // Screen-share privacy: the pill shows one state word and never a dictated word (the
  // aura tint tells success from failure) and the terminal prints only a char count. Paste still happens; the history
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
  public var wsEndpointAligned: Bool = true
  // Streaming chunk size; docs recommend ~100ms for the dedicated model (150 = shipped).
  public var chunkMs: Int = 100
  // Synthetic trailing silence appended after key-up so the speech encoder's lookahead
  // window can finalize the last word. 0 disables it entirely.
  public var silenceFlushMs: Int = 200
  // Release the mic (status-bar indicator off) after this many seconds without a dictation;
  // the next key-down re-arms it. 0 = keep the mic always on (lowest latency, indicator lit).
  public var keepMicrophoneWarm: Bool = false
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
  public var historyRetentionDays: Int = 0
  // Opt-in usage metrics: counts, categories, and buckets only. See PRIVACY.md.
  public var shareUsageMetrics: Bool = false
  public var historyDbPath: String = ""  // empty = ~/Library/Application Support/Tok/history.db
  // Local dictation stats: counts, timing, and word frequencies in stats.db, never
  // transcripts. Separate from history so totals survive history settings. See PRIVACY.md.
  public var statsEnabled: Bool = true
  public var statsWordsEnabled: Bool = true
  // The typing speed the stats dashboard assumes when it estimates time saved.
  public var typingWordsPerMinute: Int = 40
  // Source revision from Tok's built bundle, including a dirty-worktree marker.
  // Assigned by SettingsStore; never a user preference or imported .env setting.
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
  // Free-text label stored with every history row so measurements from a
  // deliberate A/B session can be grouped later without timestamp archaeology. Hot: no
  // engine restart needed. nil (not empty string) when unset, so old rows and rows with no
  // label both read NULL. Trimmed and capped to 64 characters at parse time (SettingCatalog).
  public var experimentTag: String? = nil

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

  static func parseLanguages(_ value: String, fallback: [String]) -> [String] {
    let languages = value.components(separatedBy: ",").map(normalizeLanguageCode).filter {
      !$0.isEmpty
    }
    if languages.contains("auto") || languages.contains("all") { return [] }
    return languages.isEmpty ? fallback : languages
  }

  public static func load(values: [String: String], vocabularyText: String? = nil)
    -> EngineConfiguration
  {
    var config = EngineConfiguration()
    config.geminiApiKey = values["GEMINI_API_KEY"] ?? ""
    config.typesafeApiKey = values["TYPESAFE_API_KEY"] ?? ""
    for setting in SettingCatalog.all {
      setting.apply(&config, values[setting.key] ?? setting.defaultValue)
    }
    var items = config.customVocabulary
    if let vocabularyText {
      items.append(contentsOf: parseVocabulary(from: vocabularyText))
      if config.analyzeContext.isEmpty {
        config.analyzeContext = parseContextDirective(from: vocabularyText)
      }
    }
    let split = splitVocabularyItems(items)
    config.replacementRules = split.rules
    config.compiledReplacementRules = ReplacementEngine.compile(split.rules)
    var seen = Set<String>()
    config.customVocabulary = (split.vocab + split.rules.map { $0.right }).compactMap { value in
      let term = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !term.isEmpty, seen.insert(term.lowercased()).inserted else { return nil }
      return term
    }
    Log.isVerbose = config.logLevel == "verbose"
    return config
  }
}
