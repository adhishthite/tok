import AppKit

@MainActor
enum FileDialogs {
  static func chooseConfiguration() -> URL? {
    let panel = NSOpenPanel()
    panel.title = "Import JustSpeak settings"
    panel.message =
      "Choose the .env file or its folder. Your API key is stored in Keychain; vocabulary is copied into Tok."
    panel.prompt = "Import"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.showsHiddenFiles = true
    panel.allowsMultipleSelection = false
    guard panel.runModal() == .OK else { return nil }
    return panel.url
  }
}
