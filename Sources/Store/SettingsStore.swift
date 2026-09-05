import Foundation
import Observation
import TokEngine

@MainActor
@Observable
final class SettingsStore {
  private(set) var hasAPIKey = false
  private(set) var loadError: String?
  @ObservationIgnored private(set) var configuration = EngineConfiguration()
  func load() {
    do {
      var values = UserDefaults.standard.dictionaryRepresentation().compactMapValues {
        $0 as? String
      }
      var baseDirectory = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
          "Tok", isDirectory: true)
      #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--config-file"),
          arguments.indices.contains(flag + 1)
        {
          let url = URL(fileURLWithPath: arguments[flag + 1])
          var imported = try EnvImporter.read(url)
          if let key = imported.removeValue(forKey: "GEMINI_API_KEY"), !key.isEmpty {
            try Keychain.saveAPIKey(key)
          }
          // A development import must not write into JustSpeak's history database.
          imported.removeValue(forKey: "HISTORY_DB")
          values.merge(imported) { _, new in new }
          baseDirectory = url.deletingLastPathComponent()
        }
      #endif
      values["GEMINI_API_KEY"] = try Keychain.readAPIKey() ?? ""
      for (key, value) in ProcessInfo.processInfo.environment where !value.isEmpty {
        values[key] = value
      }
      let path = NSString(string: values["CUSTOM_VOCABULARY_FILE"] ?? "vocabulary.txt")
        .expandingTildeInPath
      let vocabularyURL =
        path.hasPrefix("/")
        ? URL(fileURLWithPath: path) : baseDirectory.appendingPathComponent(path)
      let vocabulary = try? String(contentsOf: vocabularyURL, encoding: .utf8)
      configuration = EngineConfiguration.load(values: values, vocabularyText: vocabulary)
      hasAPIKey = !configuration.geminiApiKey.isEmpty
      loadError = nil
    } catch {
      loadError = "Configuration could not be loaded. Check the selected file and Keychain access."
      hasAPIKey = false
    }
  }
}
