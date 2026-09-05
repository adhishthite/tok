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
  private(set) var loadError: String?
  private(set) var values: [String: String] = [:]
  private(set) var overrides: [String: String] = [:]
  @ObservationIgnored private(set) var configuration = EngineConfiguration()
  @ObservationIgnored var didChange: (() -> Void)?
  @ObservationIgnored private let defaults: UserDefaults
  let supportDirectory: URL
  var vocabularyURL: URL { supportDirectory.appendingPathComponent("vocabulary.txt") }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    supportDirectory = FileManager.default.urls(
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
      values = [:]
      overrides = [:]
      for setting in SettingCatalog.all {
        if let value = defaults.string(forKey: setting.key) { values[setting.key] = value }
        if let value = ProcessInfo.processInfo.environment[setting.key] {
          overrides[setting.key] = value
        }
      }
      rebuild()
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
    didChange?()
  }
  func reset() {
    for setting in SettingCatalog.all { defaults.removeObject(forKey: setting.key) }
    values = [:]
    rebuild()
    didChange?()
  }

  private func rebuild() {
    var effective = values.merging(overrides) { _, override in override }
    effective["GEMINI_API_KEY"] =
      ProcessInfo.processInfo.environment["GEMINI_API_KEY"].flatMap { $0.isEmpty ? nil : $0 }
      ?? configuration.geminiApiKey
    let rawPath = effective["CUSTOM_VOCABULARY_FILE"] ?? vocabularyURL.path
    let expanded = NSString(string: rawPath).expandingTildeInPath
    let url =
      expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded) : supportDirectory.appendingPathComponent(expanded)
    let vocabulary = try? String(contentsOf: url, encoding: .utf8)
    configuration = EngineConfiguration.load(values: effective, vocabularyText: vocabulary)
    hasAPIKey = !configuration.geminiApiKey.isEmpty
  }

  func validateAndSaveAPIKey(_ key: String) async throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    var candidate = configuration
    candidate.geminiApiKey = trimmed
    try await ServiceProbe.validate(configuration: candidate)
    try Keychain.saveAPIKey(trimmed)
    configuration.geminiApiKey = trimmed
    rebuild()
    didChange?()
  }
  func testConnection() async throws {
    try await ServiceProbe.validate(configuration: configuration)
  }

  func importConfiguration(from source: URL, notify: Bool = true) throws {
    let url = source.hasDirectoryPath ? source.appendingPathComponent(".env") : source
    var imported = try EnvImporter.read(url)
    if let key = imported.removeValue(forKey: "GEMINI_API_KEY"), !key.isEmpty {
      try Keychain.saveAPIKey(key)
      configuration.geminiApiKey = key
    }
    imported.removeValue(forKey: "HISTORY_DB")
    let rawVocabulary =
      imported["CUSTOM_VOCABULARY_FILE"].flatMap { $0.isEmpty ? nil : $0 } ?? "vocabulary.txt"
    let expanded = NSString(string: rawVocabulary).expandingTildeInPath
    let vocabulary =
      expanded.hasPrefix("/")
      ? URL(fileURLWithPath: expanded)
      : url.deletingLastPathComponent().appendingPathComponent(expanded)
    if let contents = try? Data(contentsOf: vocabulary) {
      try FileManager.default.createDirectory(
        at: supportDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try contents.write(to: vocabularyURL, options: .atomic)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: vocabularyURL.path)
      imported["CUSTOM_VOCABULARY_FILE"] = vocabularyURL.path
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
    if notify { didChange?() }
  }

  func reloadVocabulary() {
    rebuild()
    didChange?()
  }
}
