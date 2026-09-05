import XCTest

@testable import Tok
@testable import TokEngine

@MainActor
final class PrivacyTransitionTests: XCTestCase {
  func testEnablingPrivacyRemovesPreviouslyCachedWordsImmediately() {
    let suite = "TokPrivacyTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SettingsStore(
      defaults: defaults,
      supportDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
        UUID().uuidString))
    let store = DictationStore(settings: settings)
    let record = TurnRecord(
      outcome: "success", text: "Private fixture words", charCount: 21, wordCount: 3,
      transport: "fixture", model: nil, isLiveRoute: true, fallbackReason: nil,
      audioSeconds: nil, firstTokenMs: nil, roundtripMs: nil, captureFinalizeMs: nil,
      injectMs: nil, totalMs: nil, injected: true, inputTokens: nil, outputTokens: nil,
      tokensMetered: nil, costUSD: nil, languageCodes: "en-IN", smartMode: true,
      vadMode: "manual", error: nil, appBundleId: nil, appName: nil, inputDevice: nil,
      inputTransport: nil)
    store.engineDidEmit(.turnSettled(record))
    store.engineDidEmit(.liveText("Another private fixture"))
    XCTAssertFalse(store.lastText.isEmpty)
    settings.set("PRIVACY_MODE", "true")
    XCTAssertTrue(store.lastText.isEmpty)
    XCTAssertTrue(store.liveText.isEmpty)
  }
}
