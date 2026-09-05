import AppKit
import SwiftUI
import TokEngine

@MainActor
final class VocabularyDocument: NSDocument {
  let model = VocabularyEditorModel()
  weak var settings: SettingsStore?
  var didClose: (() -> Void)?
  private var reading = false
  private var analysis: Task<Void, Never>?

  override init() {
    super.init()
    model.didEdit = { [weak self] in
      guard let self, !self.reading else { return }
      self.updateChangeCount(.changeDone)
    }
  }
  override nonisolated class var autosavesInPlace: Bool { false }
  override class var readableTypes: [String] { ["public.plain-text"] }
  override class var writableTypes: [String] { ["public.plain-text"] }
  override class func isNativeType(_ type: String) -> Bool { type == "public.plain-text" }

  override func read(from data: Data, ofType typeName: String) throws {
    guard let text = String(data: data, encoding: .utf8) else {
      throw CocoaError(.fileReadInapplicableStringEncoding)
    }
    let install: @MainActor @Sendable () -> Void = {
      self.reading = true
      self.model.contents = text
      self.reading = false
    }
    if Thread.isMainThread {
      MainActor.assumeIsolated { install() }
    } else {
      DispatchQueue.main.sync { install() }
    }
  }
  override func data(ofType typeName: String) throws -> Data { Data(model.contents.utf8) }

  override func makeWindowControllers() {
    let content = VocabularyView(
      model: model, save: { [weak self] in self?.save(nil) },
      analyze: { [weak self] in self?.requestSuggestions() },
      cancelAnalysis: { [weak self] in self?.analysis?.cancel() },
      addSelected: { [weak self] in self?.addSelected() }
    )

    let window = NSWindow(contentViewController: NSHostingController(rootView: content))
    window.title = "Vocabulary"
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.contentMinSize = NSSize(width: 620, height: 420)
    window.setContentSize(NSSize(width: 780, height: 560))
    window.center()
    window.setFrameAutosaveName("TokVocabulary")
    addWindowController(NSWindowController(window: window))
  }

  private func requestSuggestions() {
    guard !model.analyzing, let settings else { return }
    model.analyzing = true
    model.message = nil
    let config = settings.configuration
    analysis = Task { [weak self] in
      do {
        let suggestions = try await VocabularyAnalyzer.analyze(configuration: config)
        guard !Task.isCancelled else {
          self?.model.analyzing = false
          return
        }
        self?.model.suggestions = suggestions
        self?.model.selected = []
        if suggestions.isEmpty { self?.model.message = "No new suggestions this time." }
      } catch is CancellationError {} catch { self?.model.message = error.localizedDescription }
      self?.model.analyzing = false
    }
  }
  private func addSelected() {
    let lines = model.suggestions.filter { model.selected.contains($0.id) }.map(\.line)
    guard !lines.isEmpty else { return }
    replaceContents(
      model.contents + (model.contents.hasSuffix("\n") || model.contents.isEmpty ? "" : "\n")
        + lines.joined(separator: "\n") + "\n")
    model.suggestions = []
    model.selected = []
    model.message = "Suggestions added. Save to use them in dictation."
  }
  func addImportedVocabulary(_ text: String) {
    replaceContents(
      VocabularyImport.merging(text, into: model.contents), actionName: "Import vocabulary")
    model.message = "Vocabulary added. Save to use the changes in dictation."
  }

  private func replaceContents(_ text: String, actionName: String = "Add vocabulary suggestions") {
    guard text != model.contents else { return }
    let prior = model.contents
    undoManager?.registerUndo(withTarget: self) { document in
      document.replaceContents(prior, actionName: actionName)
    }
    undoManager?.setActionName(actionName)
    model.contents = text
  }
  override func close() {
    analysis?.cancel()
    super.close()
    didClose?()
  }
}
