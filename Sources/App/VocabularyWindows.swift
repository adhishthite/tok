import AppKit

@MainActor
final class VocabularyWindows {
  private var documents: [URL: VocabularyDocument] = [:]
  func connect(to settings: SettingsStore) {
    settings.stageVocabularyImport = { [weak self] url, contents in
      let canonical = url.resolvingSymlinksInPath().standardizedFileURL
      guard let document = self?.documents[canonical] else { return false }
      document.addImportedVocabulary(contents)
      document.showWindows()
      return true
    }
  }

  func register(_ document: VocabularyDocument, at url: URL) {
    let canonical = url.resolvingSymlinksInPath().standardizedFileURL
    document.didClose = { [weak self] in self?.documents.removeValue(forKey: canonical) }
    documents[canonical] = document
    NSDocumentController.shared.addDocument(document)
  }

  func show(settings: SettingsStore) {
    let url = settings.resolvedVocabularyURL.resolvingSymlinksInPath().standardizedFileURL
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
      register(document, at: url)
      document.makeWindowControllers()
      document.showWindows()
      document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    } catch { NSAlert(error: error).runModal() }
  }
}
