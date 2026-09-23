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
    readKey: @escaping (Keychain.Account) throws -> String?
  ) -> (SettingsStore, String, URL) {
    let suite = "TokSettingsKeychainTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    return (
      SettingsStore(defaults: defaults, supportDirectory: directory, readKey: readKey), suite,
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
