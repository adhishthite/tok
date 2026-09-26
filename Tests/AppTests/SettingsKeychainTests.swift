// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Security
import XCTest

@testable import Tok
@testable import TokEngine

/// A Keychain error reading the optional TypeSafe item (locked keychain, denied interaction,
/// corrupt item) must not disable core dictation by tripping `loadError`. Only the required
/// Gemini key keeps that behavior. See `SettingsStore.load()`.
@MainActor
final class SettingsKeychainTests: XCTestCase {
  private func makeSettings(
    readKey: @escaping (Keychain.Account) throws -> String?,
    deleteKey: @escaping (Keychain.Account) throws -> Void = { _ in }
  ) -> (SettingsStore, String, URL) {
    let suite = "TokSettingsKeychainTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    return (
      SettingsStore(
        defaults: defaults, supportDirectory: directory, readKey: readKey, deleteKey: deleteKey),
      suite,
      directory
    )
  }

  func testTypeSafeReadFailureIsNonFatal() {
    let (settings, suite, directory) = makeSettings { account in
      switch account {
      case .gemini: return "gemini-key"
      case .typesafe: throw KeychainError(status: errSecInteractionNotAllowed)
      }
    }
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    settings.load()
    XCTAssertNil(settings.loadError)
    XCTAssertTrue(settings.hasAPIKey)
    XCTAssertEqual(settings.configuration.geminiApiKey, "gemini-key")
    XCTAssertFalse(settings.hasTypeSafeKey)
    XCTAssertEqual(settings.configuration.typesafeApiKey, "")
    XCTAssertEqual(settings.typesafeKeyError, "Could not read the TypeSafe key from Keychain.")
  }

  func testRemovingTheTypeSafeKeyTurnsJudgmentsOff() throws {
    var deleted: [Keychain.Account] = []
    var notified: Set<String> = []
    let (settings, suite, directory) = makeSettings(
      readKey: { account in account == .typesafe ? "typesafe-key" : "gemini-key" },
      deleteKey: { deleted.append($0) })
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    settings.load()
    settings.didChange = { notified.formUnion($0) }
    XCTAssertTrue(settings.hasTypeSafeKey)
    try settings.removeTypeSafeKey()
    XCTAssertEqual(deleted, [.typesafe])
    XCTAssertFalse(settings.hasTypeSafeKey)
    XCTAssertEqual(settings.configuration.typesafeApiKey, "")
    XCTAssertTrue(settings.hasAPIKey, "the Gemini key is untouched")
    XCTAssertTrue(notified.contains(SettingsStore.everySetting), "the engine is reconfigured")
  }

  func testRemovingTheTypeSafeKeyKeepsItWhenKeychainFails() {
    let (settings, suite, directory) = makeSettings(
      readKey: { account in account == .typesafe ? "typesafe-key" : "gemini-key" },
      deleteKey: { _ in throw KeychainError(status: errSecInteractionNotAllowed) })
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    settings.load()
    XCTAssertThrowsError(try settings.removeTypeSafeKey())
    XCTAssertTrue(settings.hasTypeSafeKey, "the key stays in use when it could not be deleted")
  }

  func testGeminiReadFailureSetsLoadError() {
    let (settings, suite, directory) = makeSettings { account in
      switch account {
      case .gemini: throw KeychainError(status: errSecInteractionNotAllowed)
      case .typesafe: return nil
      }
    }
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    settings.load()
    XCTAssertNotNil(settings.loadError)
    XCTAssertFalse(settings.hasAPIKey)
  }

  func testBothKeysSucceedWithNoErrors() {
    let (settings, suite, directory) = makeSettings { account in
      switch account {
      case .gemini: return "gemini-key"
      case .typesafe: return "typesafe-key"
      }
    }
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    settings.load()
    XCTAssertNil(settings.loadError)
    XCTAssertNil(settings.typesafeKeyError)
    XCTAssertTrue(settings.hasAPIKey)
    XCTAssertTrue(settings.hasTypeSafeKey)
    XCTAssertEqual(settings.configuration.geminiApiKey, "gemini-key")
    XCTAssertEqual(settings.configuration.typesafeApiKey, "typesafe-key")
  }
}
