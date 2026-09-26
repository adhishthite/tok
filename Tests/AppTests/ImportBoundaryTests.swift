// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Tok

@MainActor
final class ImportBoundaryTests: XCTestCase {
  func testOutsidePathAndSymlinkRequireSeparateSelection() throws {
    try withSettings { settings, root in
      let incoming = root.appendingPathComponent("incoming", isDirectory: true)
      try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
      let outside = root.appendingPathComponent("outside.txt")
      try "Outside fixture term\n".write(to: outside, atomically: true, encoding: .utf8)
      let configuration = incoming.appendingPathComponent("settings.env")
      for path in ["../outside.txt", outside.path] {
        try "CUSTOM_VOCABULARY_FILE=\(path)\n".write(
          to: configuration, atomically: true, encoding: .utf8)
        let result = try settings.importConfiguration(from: configuration)
        if case .chooseVocabulary = result {} else { XCTFail("External file was not rejected") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: settings.vocabularyURL.path))
      }
      let link = incoming.appendingPathComponent("vocabulary.txt")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
      try "HOTKEY=fn\n".write(to: configuration, atomically: true, encoding: .utf8)
      let result = try settings.importConfiguration(from: configuration)
      if case .chooseVocabulary = result {} else { XCTFail("Symlink escape was not rejected") }
      XCTAssertFalse(FileManager.default.fileExists(atPath: settings.vocabularyURL.path))
      try settings.importVocabulary(from: outside)
      XCTAssertTrue(settings.configuration.customVocabulary.contains("Outside fixture term"))
    }
  }

  func testContainedVocabularyMergesWithoutRemovingExistingTerms() throws {
    try withSettings { settings, root in
      try FileManager.default.createDirectory(
        at: settings.supportDirectory, withIntermediateDirectories: true)
      try "Existing term\n".write(to: settings.vocabularyURL, atomically: true, encoding: .utf8)
      let incoming = root.appendingPathComponent("incoming", isDirectory: true)
      try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
      let vocabulary = incoming.appendingPathComponent("vocabulary.txt")
      try "Existing term\nNew term\nNew term\n".write(
        to: vocabulary, atomically: true, encoding: .utf8)
      let configuration = incoming.appendingPathComponent("settings.env")
      try "CUSTOM_VOCABULARY_FILE=\(vocabulary.path)\n".write(
        to: configuration, atomically: true, encoding: .utf8)
      try settings.importConfiguration(from: configuration)
      XCTAssertEqual(
        try String(contentsOf: settings.vocabularyURL, encoding: .utf8), "Existing term\nNew term\n"
      )
      XCTAssertTrue(settings.configuration.customVocabulary.contains("New term"))
    }
  }

  func testEmptyVocabularyPathUsesSameFileAsEditor() throws {
    try withSettings { settings, _ in
      try FileManager.default.createDirectory(
        at: settings.supportDirectory, withIntermediateDirectories: true)
      try "Canonical term\n".write(to: settings.vocabularyURL, atomically: true, encoding: .utf8)
      settings.set("CUSTOM_VOCABULARY_FILE", "")
      XCTAssertEqual(settings.resolvedVocabularyURL, settings.vocabularyURL)
      XCTAssertTrue(settings.configuration.customVocabulary.contains("Canonical term"))
    }
  }

  func testOversizedAndInvalidTextImportsFailBeforeSettingsChange() throws {
    try withSettings { settings, root in
      let file = root.appendingPathComponent("settings.env")
      try Data(repeating: 65, count: ImportTextFile.maximumBytes + 1).write(to: file)
      XCTAssertThrowsError(try settings.importConfiguration(from: file))
      XCTAssertTrue(settings.values.isEmpty)
      try Data([0xff, 0xfe, 0xff]).write(to: file)
      XCTAssertThrowsError(try settings.importConfiguration(from: file))
      XCTAssertTrue(settings.values.isEmpty)
      XCTAssertThrowsError(try ImportTextFile.read(root))
    }
  }

  private func withSettings(_ body: (SettingsStore, URL) throws -> Void) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "TokImportBoundary.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(
      SettingsStore(defaults: defaults, supportDirectory: root.appendingPathComponent("Tok")), root)
  }
}
