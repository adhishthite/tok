import Foundation
import TokEngine

/// Builds the engine configuration for one arm: the owner's installed-app settings, read
/// from its preferences domain, then the harness safety overrides, then the arm's own
/// changes. The API key comes from GEMINI_API_KEY or the repo .env, never from output.
enum HarnessSettings {
  static let appDomain = "com.adhishthite.tok"

  /// Settings the harness always forces. No sounds or ducking (they would change the
  /// played audio), no clipboard, no correction watcher, no hold-to-lock (a long clip
  /// would lock the turn), no usage metrics.
  static let safety: [String: String] = [
    "SOUND_FEEDBACK": "false",
    "RELEASE_SOUND": "false",
    "DUCK_AUDIO": "false",
    "RESTORE_CLIPBOARD": "false",
    "LEARN_CORRECTIONS": "false",
    "HOLD_TO_LOCK": "0",
    "SHARE_USAGE_METRICS": "false",
    "HISTORY": "true",
  ]

  static func ownerValues() -> [String: String] {
    guard let defaults = UserDefaults(suiteName: appDomain) else { return [:] }
    var values: [String: String] = [:]
    for setting in SettingCatalog.all {
      if let value = defaults.string(forKey: setting.key) { values[setting.key] = value }
    }
    return values
  }

  static func apiKey(root: URL) -> String {
    if let key = ProcessInfo.processInfo.environment["GEMINI_API_KEY"], !key.isEmpty {
      return key
    }
    guard
      let content = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
    else { return "" }
    for line in content.components(separatedBy: .newlines) {
      guard let separator = line.firstIndex(of: "=") else { continue }
      guard line[..<separator].trimmingCharacters(in: .whitespaces) == "GEMINI_API_KEY" else {
        continue
      }
      return line[line.index(after: separator)...]
        .trimmingCharacters(in: .whitespaces)
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return ""
  }

  /// The installed app's vocabulary file, so recognition sees the same custom terms.
  static func vocabularyText(owner: [String: String]) -> String? {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0
    ]
    .appendingPathComponent("Tok", isDirectory: true)
    let raw = owner["CUSTOM_VOCABULARY_FILE"] ?? ""
    let expanded = NSString(
      string: raw.isEmpty ? support.appendingPathComponent("vocabulary.txt").path : raw
    )
    .expandingTildeInPath
    let url =
      expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded) : support.appendingPathComponent(expanded)
    return try? String(contentsOf: url, encoding: .utf8)
  }

  /// Owner settings, then safety overrides, then the arm. No API key.
  static func values(arm: HarnessArm, owner: [String: String]) -> [String: String] {
    var values = owner
    values.merge(safety) { _, forced in forced }
    values.merge(arm.overrides) { _, armValue in armValue }
    values["EXPERIMENT_TAG"] = "harness-\(arm.name)"
    return values
  }

  static func configuration(
    arm: HarnessArm, owner: [String: String], apiKey: String, historyPath: String,
    buildId: String, vocabulary: String?
  ) -> EngineConfiguration {
    var values = values(arm: arm, owner: owner)
    values["HISTORY_DB"] = historyPath
    values["GEMINI_API_KEY"] = apiKey
    var configuration = EngineConfiguration.load(values: values, vocabularyText: vocabulary)
    configuration.buildId = buildId
    return configuration
  }

  /// The settings that differ between arms or matter for reading results, for the run log.
  static let reportedKeys = [
    "KEEP_MICROPHONE_WARM", "MIC_IDLE_TIMEOUT", "WS_ENDPOINT_ALIGNED", "SILENCE_FLUSH_MS",
    "PRE_ROLL_MS", "POST_ROLL_MS", "POST_ROLL_MIN_MS", "POST_ROLL_MAX_MS", "TRAIL_SILENCE_DB",
    "CHUNK_MS",
    "VAD_MODE", "VAD_SILENCE_MS", "REST_FALLBACK_TIMEOUT", "GEMINI_LIVE_MODEL", "GEMINI_MODEL",
    "LANGUAGE_CODES", "SMART_TRANSCRIPTION", "POST_PROCESS_ENABLED", "INPUT_DEVICE",
  ]
}
