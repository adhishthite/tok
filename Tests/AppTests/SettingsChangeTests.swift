import XCTest

@testable import Tok
@testable import TokEngine

/// Covers the audit F05 wording, the F30 change reporting, and the F33 lock conditions.
@MainActor
final class SettingsChangeTests: XCTestCase {
  private func makeSettings() -> (SettingsStore, String, URL) {
    let suite = "TokSettingsChangeTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    return (SettingsStore(defaults: defaults, supportDirectory: directory), suite, directory)
  }

  func testChangedKeysAreReported() {
    let (settings, suite, _) = makeSettings()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    var reported: [Set<String>] = []
    settings.didChange = { reported.append($0) }
    settings.set("SOUND_FEEDBACK", "true")
    XCTAssertEqual(reported, [["SOUND_FEEDBACK"]])
    settings.reset()
    XCTAssertEqual(reported.count, 2)
    XCTAssertTrue(reported[1].contains("HOTKEY"))
    XCTAssertTrue(reported[1].contains("SOUND_FEEDBACK"))
  }

  func testHotKeysDoNotRestartTheEngine() {
    let hot = [
      "SOUND_FEEDBACK", "RELEASE_SOUND", "SHOW_HUD", "HUD_FOLLOW_FOCUS", "HUD_REVEAL",
      "HUD_PARTICLES", "TYPING_WPM", "STATS", "STATS_WORDS", "SHARE_USAGE_METRICS",
      "HISTORY_RETENTION_DAYS", "LIVE_INPUT_PRICE_PER_1M", "LIVE_OUTPUT_PRICE_PER_1M",
      "REST_INPUT_PRICE_PER_1M", "REST_OUTPUT_PRICE_PER_1M", "LOG_LEVEL", "PRIVACY_MODE",
    ]
    for key in hot {
      let setting = SettingCatalog.all.first { $0.key == key }
      XCTAssertEqual(setting?.restartsEngine, false, "\(key) should not restart the engine")
    }
    XCTAssertEqual(SettingCatalog.all.first { $0.key == "HOTKEY" }?.restartsEngine, true)
  }

  func testLockRowsAreDisabledInToggleMode() {
    let limit = SettingCatalog.all.first { $0.key == "LOCK_LIMIT" }?.enabledWhen
    let lock = SettingCatalog.all.first { $0.key == "HOLD_TO_LOCK" }?.enabledWhen
    var values = ["HOLD_TO_LOCK": "15.0", "HOTKEY_MODE": "push_to_talk"]
    XCTAssertEqual(lock?.isSatisfied { values[$0] ?? "" }, true)
    XCTAssertEqual(limit?.isSatisfied { values[$0] ?? "" }, true)
    values["HOTKEY_MODE"] = "toggle"
    XCTAssertEqual(lock?.isSatisfied { values[$0] ?? "" }, false)
    XCTAssertEqual(limit?.isSatisfied { values[$0] ?? "" }, false)
    values["HOTKEY_MODE"] = "push_to_talk"
    values["HOLD_TO_LOCK"] = "0"
    XCTAssertEqual(limit?.isSatisfied { values[$0] ?? "" }, false)
  }

  func testVocabularyFileIsReadOncePerPath() throws {
    let (settings, suite, directory) = makeSettings()
    defer {
      UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
      try? FileManager.default.removeItem(at: directory)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("vocabulary.txt")
    try "kubectl\n".write(to: file, atomically: true, encoding: .utf8)
    settings.set("CUSTOM_VOCABULARY_FILE", file.path)
    XCTAssertTrue(settings.configuration.customVocabulary.contains("kubectl"))
    // An unrelated change must not re-read the file, so an edit behind the store is
    // not picked up until reloadVocabulary runs.
    try "kubectl\ngcloud\n".write(to: file, atomically: true, encoding: .utf8)
    settings.set("SOUND_FEEDBACK", "true")
    XCTAssertFalse(settings.configuration.customVocabulary.contains("gcloud"))
    settings.reloadVocabulary()
    XCTAssertTrue(settings.configuration.customVocabulary.contains("gcloud"))
  }

  func testPromptsFollowTheShortcutMode() {
    XCTAssertEqual(
      ShortcutPrompt.ready(shortcut: "Fn", toggleMode: false), "Hold Fn to dictate.")
    XCTAssertEqual(
      ShortcutPrompt.ready(shortcut: "Fn", toggleMode: true), "Press Fn to dictate.")
    XCTAssertEqual(
      ShortcutPrompt.listening(shortcut: "Fn", toggleMode: false), "Speak, then release to paste.")
    XCTAssertEqual(
      ShortcutPrompt.listening(shortcut: "Fn", toggleMode: true),
      "Speak, then press Fn to paste.")
    XCTAssertEqual(
      ShortcutPrompt.wake(shortcut: "Right Option", toggleMode: false),
      "Hold Right Option to wake the microphone.")
    XCTAssertEqual(
      ShortcutPrompt.menu(shortcut: "Fn", toggleMode: true), "Press Fn and speak.")
  }

  func testStoreMessagesUseTheShortcutLabelAndMode() {
    let (settings, suite, _) = makeSettings()
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    settings.set("HOTKEY", "right_option")
    settings.set("HOTKEY_MODE", "toggle")
    // The store is created after the values, so no settings change reaches the engine.
    let store = DictationStore(settings: settings)
    store.engineDidEmit(.ready)
    XCTAssertEqual(store.message, "Press Right Option to dictate.")
    store.engineDidEmit(.listening(lockAfter: nil))
    XCTAssertEqual(store.message, "Speak, then press Right Option to paste.")
    store.engineDidEmit(.microphoneReleased)
    XCTAssertEqual(store.message, "Press Right Option to wake the microphone.")
  }

  func testFailureKeepsTheErrorAfterTheStatusClears() {
    let store = DictationStore()
    store.engineDidEmit(.failure("Network timeout. Nothing pasted."))
    XCTAssertEqual(store.status, .error)
    XCTAssertEqual(store.lastError, "Network timeout. Nothing pasted.")
    // A quiet clip is a calmer state than a fault, with its own menu-bar symbol.
    store.engineDidEmit(.failure(DictationEngine.noSpeechMessage))
    XCTAssertEqual(store.status, .noSpeech)
    XCTAssertEqual(store.status.symbol, "waveform.slash")
    store.engineDidEmit(.success("Done"))
    XCTAssertEqual(store.status, .ready)
    XCTAssertNil(store.lastError)
    store.engineDidEmit(.failure("Paste failed"))
    store.dismissLastError()
    XCTAssertNil(store.lastError)
  }

  func testDeliveryAndOutcomeLabelsAreReadable() {
    XCTAssertEqual(DeliveryLabel.delivery("dispatched"), "Paste dispatched")
    XCTAssertEqual(DeliveryLabel.menuDelivery("copied"), "Copied to clipboard")
    XCTAssertEqual(DeliveryLabel.menuDelivery("failed"), "Could not deliver")
    XCTAssertNil(DeliveryLabel.menuDelivery(nil))
    XCTAssertEqual(DeliveryLabel.outcome("delivery_failed"), "Could not deliver")
    XCTAssertEqual(DeliveryLabel.outcome("empty"), "No speech")
    XCTAssertEqual(DeliveryLabel.outcome("success"), "Completed")
  }
}
