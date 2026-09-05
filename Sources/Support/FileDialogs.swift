import AppKit

@MainActor
enum FileDialogs {
  static func chooseConfiguration() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import JustSpeak settings"
    panel.message =
      "Choose a UTF-8 .env file up to 1 MB, or its folder. Your key is stored in Keychain. Vocabulary in this folder is added to your existing terms."
    panel.prompt = "Import"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.showsHiddenFiles = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }

  static func chooseVocabulary() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Add vocabulary from file"
    panel.message =
      "Choose a UTF-8 text file up to 1 MB. New lines are added to your existing vocabulary."
    panel.prompt = "Add vocabulary"
    panel.canChooseDirectories = false
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}
