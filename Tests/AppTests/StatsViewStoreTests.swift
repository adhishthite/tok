import XCTest

@testable import Tok
@testable import TokEngine

@MainActor
final class StatsViewStoreTests: XCTestCase {
  private var directory: URL!

  override func setUp() {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: directory) }

  private func turn(_ text: String) -> TurnRecord {
    TurnRecord(
      outcome: "success", text: text, charCount: text.count,
      wordCount: text.split { $0.isWhitespace }.count, transport: "Live", model: "fixture",
      isLiveRoute: true, fallbackReason: nil, audioSeconds: 2, firstTokenMs: nil,
      roundtripMs: 300, captureFinalizeMs: 0, injectMs: 0, totalMs: 300, injected: true,
      inputTokens: nil, outputTokens: nil, tokensMetered: false, costUSD: nil,
      languageCodes: "en-IN", smartMode: true, vadMode: "manual", error: nil, appBundleId: nil,
      appName: "Notes", inputDevice: nil, inputTransport: nil, deliveryOutcome: "dispatched")
  }

  private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<100 where !condition() {
      try? await Task.sleep(for: .milliseconds(50))
    }
  }

  func testRecordsWhenEnabledAndRefreshesTheGlance() async throws {
    let store = StatsViewStore()
    store.configure(directory: directory, enabled: true, trackWords: true, typingWordsPerMinute: 40)
    store.record(turn("hello stats world"))
    await waitUntil { store.wordsToday == 3 }
    XCTAssertEqual(store.wordsToday, 3)
    XCTAssertEqual(store.fileURL, directory.appendingPathComponent("stats.db"))
    let report = try await XCTUnwrap(store.repository).report(
      range: .today, typingWordsPerMinute: 40)
    XCTAssertEqual(report.dictations, 1)
    XCTAssertEqual(report.topWords.map(\.word), ["hello", "stats", "world"])
  }

  func testDisabledTrackingWritesNothing() async throws {
    let store = StatsViewStore()
    store.configure(
      directory: directory, enabled: false, trackWords: true, typingWordsPerMinute: 40)
    store.record(turn("not counted"))
    try await Task.sleep(for: .milliseconds(200))
    XCTAssertFalse(store.isEnabled)
    XCTAssertFalse(store.tracksWords)
    XCTAssertEqual(store.wordsToday, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
  }

  func testClearResetsTheGlanceAndReport() async throws {
    let store = StatsViewStore()
    store.configure(directory: directory, enabled: true, trackWords: true, typingWordsPerMinute: 40)
    store.record(turn("one two"))
    await waitUntil { store.wordsToday == 2 }
    await store.clear()
    XCTAssertEqual(store.wordsToday, 0)
    XCTAssertEqual(store.report.attempts, 0)
    let words = try await XCTUnwrap(store.repository).words(since: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(words, 0)
  }
}
