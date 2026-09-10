import XCTest

@testable import Tok
@testable import TokEngine

@MainActor
final class MetricsStoreTests: XCTestCase {
  private var suite = ""
  private var defaults: UserDefaults!
  private var directory: URL!

  override func setUp() {
    suite = "TokMetricsTests.\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suite)
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }
  override func tearDown() {
    defaults.removePersistentDomain(forName: suite)
    try? FileManager.default.removeItem(at: directory)
  }

  private func event(_ store: MetricsStore) -> MetricEvent {
    .setup(
      envelope: store.envelope(), microphone: true, accessibility: true, inputMonitoring: true,
      apiKey: true)
  }
  private var queueURL: URL { directory.appendingPathComponent("metrics-queue.jsonl") }

  func testOffByDefaultRecordsNothingAndWritesNoFile() {
    let store = MetricsStore(defaults: defaults, supportDirectory: directory)
    store.configure(enabled: false)
    store.record(event(store))
    XCTAssertFalse(store.enabled)
    XCTAssertEqual(store.queuedCount, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
    XCTAssertNil(defaults.string(forKey: MetricsStore.installIDKey))
  }

  func testEnabledQueuesEventsLocallyAndDisablingDeletesThem() throws {
    let store = MetricsStore(defaults: defaults, supportDirectory: directory)
    store.configure(enabled: true)
    store.record(event(store))
    store.record(event(store))
    XCTAssertEqual(store.queuedCount, 2)
    XCTAssertEqual(store.queuedPayloads.count, 2)
    XCTAssertTrue(try XCTUnwrap(store.lastPayload).contains("\"event\" : \"setup_state\""))
    XCTAssertTrue(try XCTUnwrap(store.lastPayload).contains(store.installID))
    let attributes = try FileManager.default.attributesOfItem(atPath: queueURL.path)
    XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    store.configure(enabled: false)
    XCTAssertEqual(store.queuedCount, 0)
    XCTAssertNil(store.lastPayload)
    XCTAssertFalse(FileManager.default.fileExists(atPath: queueURL.path))
  }

  func testInstallIDPersistsRotatesAfterNinetyDaysAndResets() {
    var now = Date(timeIntervalSince1970: 1_757_500_000)
    let store = MetricsStore(defaults: defaults, supportDirectory: directory) { now }
    store.configure(enabled: true)
    let first = store.installID
    XCTAssertEqual(first.count, 36)
    store.configure(enabled: true)
    XCTAssertEqual(store.installID, first)
    now = now.addingTimeInterval(91 * 86400)
    store.configure(enabled: true)
    XCTAssertNotEqual(store.installID, first)
    let rotated = store.installID
    store.record(event(store))
    store.resetInstallID()
    XCTAssertNotEqual(store.installID, rotated)
    XCTAssertEqual(store.queuedCount, 0)
  }

  func testQueueIsCappedAndUndocumentedEventsAreRefused() {
    let store = MetricsStore(defaults: defaults, supportDirectory: directory)
    store.configure(enabled: true)
    for _ in 0..<(MetricsStore.queueLimit + 5) { store.record(event(store)) }
    XCTAssertEqual(store.queuedCount, MetricsStore.queueLimit)
    let rogue = MetricEvent(
      name: "setup_state", envelope: store.envelope(), fields: ["transcript": .string("x")])
    XCTAssertEqual(rogue.undocumentedKeys, ["transcript"])
    store.record(rogue)
    XCTAssertEqual(store.queuedCount, MetricsStore.queueLimit)
  }

  func testStoreOffersMetricsAndDaysSinceInstall() {
    let start = Date(timeIntervalSince1970: 1_757_500_000)
    let store = MetricsStore(defaults: defaults, supportDirectory: directory) {
      start.addingTimeInterval(10 * 86400)
    }
    XCTAssertEqual(store.daysSinceInstall, 0)
    defaults.set(start, forKey: MetricsStore.firstLaunchKey)
    XCTAssertEqual(store.daysSinceInstall, 10)
  }
}
