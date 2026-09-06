import AppKit

@MainActor
enum FileDialogs {
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
