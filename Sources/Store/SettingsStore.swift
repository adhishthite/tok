import Foundation
import Observation
import TokEngine

@MainActor
@Observable
final class SettingsStore {
  private(set) var hasAPIKey = false
  var apiKeyProvidedByEnvironment: Bool {
    !(ProcessInfo.processInfo.environment["GEMINI_API_KEY"] ?? "").isEmpty
  }
  // Optional upgrade (see Engine/Judgment); mirrors the Gemini key flow exactly.
  private(set) var hasTypeSafeKey = false
  var typesafeApiKeyProvidedByEnvironment: Bool {
    !(ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? "").isEmpty
  }
  private(set) var loadError: String?
  private(set) var values: [String: String] = [:]
  private(set) var overrides: [String: String] = [:]
  @ObservationIgnored private(set) var configuration = EngineConfiguration()
  /// Reports which settings changed, so DictationStore can skip the engine rebuild for
  /// keys marked `restartsEngine: false` (audit F30). A set containing `everySetting`
  /// means the change is not confined to catalog keys and every consumer must reapply.
  @ObservationIgnored var didChange: ((Set<String>) -> Void)?
  /// Sentinel key for a change that is wider than the catalog: an API key update, an
  /// imported configuration file, or a reloaded vocabulary file.
  static let everySetting = "*"
  @ObservationIgnored var stageVocabularyImport: ((URL, String) -> Bool)?
  @ObservationIgnored private let defaults: UserDefaults
  let supportDirectory: URL
  var vocabularyURL: URL { supportDirectory.appendingPathComponent("vocabulary.txt") }
  var resolvedVocabularyURL: URL {
    let raw = string("CUSTOM_VOCABULARY_FILE")
    let expanded = NSString(string: raw.isEmpty ? vocabularyURL.path : raw).expandingTildeInPath
    return expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded) : supportDirectory.appendingPathComponent(expanded)
  }

  /// The vocabulary file contents for the URL they were read from. Rebuilding on every
  /// settings change used to re-read the file each time (audit F30).
  @ObservationIgnored private var vocabularyCache: (url: URL, text: String?)?

  init(defaults: UserDefaults = .standard, supportDirectory: URL? = nil) {
    self.defaults = defaults
    self.supportDirectory =
      supportDirectory
      ?? FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
        "Tok", isDirectory: true)
  }

  func load() {
    do {
      try FileManager.default.createDirectory(
        at: supportDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if !defaults.bool(forKey: "TokImportedDevelopmentConfig"),
          let flag = arguments.firstIndex(of: "--config-file"), arguments.indices.contains(flag + 1)
        {
          try importConfiguration(from: URL(fileURLWithPath: arguments[flag + 1]), notify: false)
          defaults.set(true, forKey: "TokImportedDevelopmentConfig")
        }
      #endif
      configuration.geminiApiKey = try Keychain.readAPIKey() ?? ""
      configuration.typesafeApiKey = try Keychain.readAPIKey(.typesafe) ?? ""
      values = [:]
      overrides = [:]
      for setting in SettingCatalog.all {
        if let value = defaults.string(forKey: setting.key) { values[setting.key] = value }
        if let value = ProcessInfo.processInfo.environment[setting.key] {
          overrides[setting.key] = value
        }
      }
      rebuild(rereadVocabulary: true)
      loadError = nil
    } catch {
      loadError = "Could not load settings. Check file permissions and Keychain access."
    }
  }

  func string(_ key: String) -> String {
    overrides[key] ?? values[key] ?? SettingCatalog.all.first(where: { $0.key == key })?
      .defaultValue ?? ""
  }
  func bool(_ key: String) -> Bool { ["true", "1"].contains(string(key).lowercased()) }
  func isOverridden(_ key: String) -> Bool { overrides[key] != nil }
  func set(_ key: String, _ value: String) {
    guard !isOverridden(key), SettingCatalog.all.contains(where: { $0.key == key }) else { return }
    defaults.set(value, forKey: key)
    values[key] = value
    rebuild()
    didChange?([key])
  }
  func reset() {
    for setting in SettingCatalog.all { defaults.removeObject(forKey: setting.key) }
    values = [:]
    rebuild()
    didChange?(Set(SettingCatalog.all.map(\.key)))
  }

  private func rebuild(rereadVocabulary: Bool = false) {
    var effective = values.merging(overrides) { _, override in override }
    effective["GEMINI_API_KEY"] =
      ProcessInfo.processInfo.environment["GEMINI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
      ?? configuration.geminiApiKey
    effective["TYPESAFE_API_KEY"] =
      ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
      ?? configuration.typesafeApiKey
    let vocabulary = vocabularyText(rereading: rereadVocabulary)
    configuration = EngineConfiguration.load(values: effective, vocabularyText: vocabulary)
    configuration.buildId = BuildIdentity.revision
    hasAPIKey = !configuration.geminiApiKey.isEmpty
    hasTypeSafeKey = !configuration.typesafeApiKey.isEmpty
  }

  /// Reads the vocabulary file only when asked to, or when the resolved path changed.
  /// A write through this store invalidates the cache itself.
  private func vocabularyText(rereading: Bool) -> String? {
    let url = resolvedVocabularyURL
    if !rereading, let cache = vocabularyCache, cache.url == url { return cache.text }
    let text = try? String(contentsOf: url, encoding: .utf8)
    vocabularyCache = (url, text)
    return text
  }

  func validateAndSaveAPIKey(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidate = configuration
    candidate.geminiApiKey = trimmed
    try await ServiceProbe.validate(configuration: candidate)
    try Keychain.saveAPIKey(trimmed)
    configuration.geminiApiKey = trimmed
    rebuild()
    didChange?([Self.everySetting])
  }
  func testConnection() async throws {
    try await ServiceProbe.validate(configuration: configuration)
  }

  func validateAndSaveTypeSafeKey(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    try await TypeSafeProbe.validate(apiKey: trimmed)
    try Keychain.saveAPIKey(trimmed, account: .typesafe)
    configuration.typesafeApiKey = trimmed
    rebuild()
    didChange?([Self.everySetting])
  }
  func testTypeSafeConnection() async throws {
    try await TypeSafeProbe.validate(apiKey: configuration.typesafeApiKey)
  }

  @discardableResult
  func importConfiguration(from source: URL, notify: Bool = true) throws
    -> ConfigurationImportResult
  {
    let url = source.hasDirectoryPath ? source.appendingPathComponent(".env") : source
    var imported = try EnvImporter.read(url)
    let importedKey = imported.removeValue(forKey: "GEMINI_API_KEY")
    let importedTypeSafeKey = imported.removeValue(forKey: "TYPESAFE_API_KEY")
    imported.removeValue(forKey: "HISTORY_DB")
    // Importing preferences must not shorten the owner's history retention.
    // Existing-record deletion is confirmed separately in History settings.
    imported.removeValue(forKey: "HISTORY_RETENTION_DAYS")
    let rawVocabulary =
      imported["CUSTOM_VOCABULARY_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "vocabulary.txt"
    let vocabulary = VocabularyImport.containedURL(path: rawVocabulary, configuration: url)
    let contents = try vocabulary.flatMap {
      FileManager.default.fileExists(atPath: $0.path) ? try ImportTextFile.read($0) : nil
    }
    if let key = importedKey, !key.isEmpty {
      try Keychain.saveAPIKey(key)
      configuration.geminiApiKey = key
    }
    if let key = importedTypeSafeKey, !key.isEmpty {
      try Keychain.saveAPIKey(key, account: .typesafe)
      configuration.typesafeApiKey = key
    }
    var result = vocabulary == nil ? ConfigurationImportResult.chooseVocabulary : .settingsOnly
    if let contents {
      let vocabularyResult = try addVocabulary(contents)
      imported["CUSTOM_VOCABULARY_FILE"] = vocabularyURL.path
      switch vocabularyResult {
      case .saved: result = .vocabularyAdded
      case .staged: result = .vocabularyStaged
      }
    } else {
      imported.removeValue(forKey: "CUSTOM_VOCABULARY_FILE")
    }
    for setting in SettingCatalog.all {
      if let value = imported[setting.key] {
        defaults.set(value, forKey: setting.key)
        values[setting.key] = value
      }
    }
    rebuild()
    if notify { didChange?([Self.everySetting]) }
    return result
  }

  @discardableResult
  func importVocabulary(from source: URL) throws -> VocabularyImportResult {
    let result = try addVocabulary(ImportTextFile.read(source))
    set("CUSTOM_VOCABULARY_FILE", vocabularyURL.path)
    return result
  }

  private func addVocabulary(_ contents: String) throws -> VocabularyImportResult {
    if stageVocabularyImport?(vocabularyURL, contents) == true { return .staged }
    try FileManager.default.createDirectory(
      at: supportDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let existing =
      FileManager.default.fileExists(atPath: vocabularyURL.path)
      ? try String(contentsOf: vocabularyURL, encoding: .utf8) : ""
    try VocabularyImport.merging(contents, into: existing).write(
      to: vocabularyURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: vocabularyURL.path)
    // The file just changed under the cache, and the path may not change with it.
    vocabularyCache = nil
    return .saved
  }

  func reloadVocabulary() {
    rebuild(rereadVocabulary: true)
    didChange?([Self.everySetting])
  }
}
