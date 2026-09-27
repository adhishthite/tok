// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Security
import XCTest

@testable import Tok
@testable import TokEngine

/// A Keychain error reading the Gemini key sets `loadError`; a successful read clears it.
/// See `SettingsStore.load()`.
@MainActor
final class SettingsKeychainTests: XCTestCase {
  private func makeSettings(readKey: @escaping () throws -> String?) -> (
    SettingsStore, String, URL
  ) {
    let suite = "TokSettingsKeychainTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    return (
      SettingsStore(defaults: defaults, supportDirectory: directory, readKey: readKey),
      suite,
      directory
    )
  }

  func testGeminiReadFailureSetsLoadError() {
    let (settings, suite, directory) = makeSettings {
      throw KeychainError(status: errSecInteractionNotAllowed)
    }
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    settings.load()
    XCTAssertNotNil(settings.loadError)
    XCTAssertFalse(settings.hasAPIKey)
  }

  func testGeminiReadSucceedsWithNoError() {
    let (settings, suite, directory) = makeSettings { "gemini-key" }
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    settings.load()
    XCTAssertNil(settings.loadError)
    XCTAssertTrue(settings.hasAPIKey)
    XCTAssertEqual(settings.configuration.geminiApiKey, "gemini-key")
  }
}
