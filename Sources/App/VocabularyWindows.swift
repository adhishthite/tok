import AppKit

@MainActor
final class VocabularyWindows {
  private var documents: [URL: VocabularyDocument] = [:]
  func show(settings: SettingsStore) {
    let url = settings.resolvedVocabularyURL.standardizedFileURL
    if let document = documents[url] {
      document.showWindows()
      document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      if !FileManager.default.fileExists(atPath: url.path) {
        guard
          FileManager.default.createFile(
            atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        else { throw CocoaError(.fileWriteUnknown) }
      }
      let document = try VocabularyDocument(contentsOf: url, ofType: "public.plain-text")
      document.settings = settings
      document.didClose = { [weak self] in self?.documents.removeValue(forKey: url) }
      documents[url] = document
      NSDocumentController.shared.addDocument(document)
      document.makeWindowControllers()
      document.showWindows()
      document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    } catch { NSAlert(error: error).runModal() }
  }
}
