// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import XCTest

@testable import Tok

@MainActor
final class OpenVocabularyImportTests: XCTestCase {
  func testImportsPreserveUnsavedEditsAndWaitForSave() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "TokOpenImport.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SettingsStore(defaults: defaults, supportDirectory: root)
    try "Existing\n".write(to: settings.vocabularyURL, atomically: true, encoding: .utf8)
    let document = try VocabularyDocument(
      contentsOf: settings.vocabularyURL, ofType: "public.plain-text")
    let windows = VocabularyWindows()
    windows.connect(to: settings)
    windows.register(document, at: settings.vocabularyURL)
    defer {
      document.updateChangeCount(.changeCleared)
      document.close()
      withExtendedLifetime(windows) {}
    }
    document.model.contents = "Existing\nUnsaved\n"
    let undo = UndoManager()
    undo.groupsByEvent = false
    document.undoManager = undo
    let imported = root.appendingPathComponent("imported.txt")
    try "Imported\n".write(to: imported, atomically: true, encoding: .utf8)
    undo.beginUndoGrouping()
    let result = try settings.importVocabulary(from: imported)
    undo.endUndoGrouping()
    if case .staged = result {} else { XCTFail("An open document must stage imports") }
    XCTAssertEqual(document.model.contents, "Existing\nUnsaved\nImported\n")
    XCTAssertTrue(document.isDocumentEdited)
    XCTAssertEqual(try String(contentsOf: settings.vocabularyURL, encoding: .utf8), "Existing\n")
    XCTAssertFalse(settings.configuration.customVocabulary.contains("Imported"))
    undo.undo()
    XCTAssertEqual(document.model.contents, "Existing\nUnsaved\n")
    undo.redo()
    XCTAssertEqual(document.model.contents, "Existing\nUnsaved\nImported\n")

    let config = root.appendingPathComponent("settings.env")
    try "CUSTOM_VOCABULARY_FILE=imported.txt\n".write(to: config, atomically: true, encoding: .utf8)
    let configResult = try settings.importConfiguration(from: config)
    if case .vocabularyStaged = configResult {
    } else {
      XCTFail("Configuration import must use the open document")
    }
    XCTAssertEqual(try String(contentsOf: settings.vocabularyURL, encoding: .utf8), "Existing\n")

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      document.save(to: settings.vocabularyURL, ofType: "public.plain-text", for: .saveOperation) {
        error in
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
      }
    }
    settings.reloadVocabulary()
    XCTAssertTrue(settings.configuration.customVocabulary.contains("Unsaved"))
    XCTAssertTrue(settings.configuration.customVocabulary.contains("Imported"))
    XCTAssertFalse(document.isDocumentEdited)
  }
}
