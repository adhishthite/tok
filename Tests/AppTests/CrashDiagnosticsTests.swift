// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import XCTest

@testable import Tok

/// Covers #13: MetricKit crash and hang reports are stored locally, bounded, included in a
/// saved report, and deleted by "Clear log".
@MainActor
final class CrashDiagnosticsTests: XCTestCase {
  private var root: URL!

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: root)
    super.tearDown()
  }

  private func json(_ tag: String, padding: Int = 0) -> Data {
    Data("{\"tag\":\"\(tag)\(String(repeating: "x", count: padding))\"}".utf8)
  }

  private func storedNames(_ crashes: CrashDiagnostics) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: crashes.directory.path)) ?? []).sorted()
  }

  private func permissions(_ path: String) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
  }

  func testEachDiagnosticGetsItsOwnOwnerOnlyFile() {
    let crashes = CrashDiagnostics(supportDirectory: root)
    crashes.store([("crash", json("a")), ("hang", json("b"))])
    let names = storedNames(crashes)
    XCTAssertEqual(names.count, 2)
    XCTAssertTrue(names[0].hasSuffix("-crash.json"))
    XCTAssertTrue(names[1].hasSuffix("-hang.json"))
    XCTAssertEqual(permissions(crashes.directory.path), 0o700)
    for name in names {
      XCTAssertEqual(permissions(crashes.directory.appendingPathComponent(name).path), 0o600)
    }
  }

  func testOnlyTheNewestFilesWithinBothBoundsRemain() throws {
    let crashes = CrashDiagnostics(supportDirectory: root, maxFiles: 3, maxBytes: 100)
    for index in 0..<5 { crashes.store([("crash", json("n\(index)"))]) }
    let kept = try storedNames(crashes).map {
      try String(contentsOf: crashes.directory.appendingPathComponent($0), encoding: .utf8)
    }
    XCTAssertEqual(kept, ["{\"tag\":\"n2\"}", "{\"tag\":\"n3\"}", "{\"tag\":\"n4\"}"])

    // 40-byte entries under a 100-byte cap: two fit.
    let sized = CrashDiagnostics(
      supportDirectory: root.appendingPathComponent("sized"), maxFiles: 10, maxBytes: 100)
    for index in 0..<4 { sized.store([("hang", json("s\(index)", padding: 28))]) }
    XCTAssertEqual(storedNames(sized).count, 2)

    // One entry over the cap is skipped instead of evicting everything else.
    sized.store([("crash", json("big", padding: 200))])
    XCTAssertEqual(storedNames(sized).count, 2)
  }

  func testReportBodyIsUnchangedWithoutCrashesAndAppendsThemAfterTheLog() throws {
    let log = DiagnosticsFile(directory: root)
    log.write("LATENCY route=WS total=450.0ms")
    let crashes = CrashDiagnostics(supportDirectory: root)
    let logOnly = DictationStore.reportBody(log: log, crashes: crashes)
    XCTAssertEqual(logOnly, log.reportContents())
    XCTAssertTrue(logOnly.contains("LATENCY"))

    crashes.store([("crash", json("stack"))])
    let body = DictationStore.reportBody(log: log, crashes: crashes)
    XCTAssertTrue(body.hasPrefix(logOnly))
    let section = String(body.dropFirst(logOnly.count))
    XCTAssertTrue(section.contains("Crash and hang diagnostics"))
    XCTAssertTrue(section.contains("{\"tag\":\"stack\"}"))
    log.close()
  }

  func testClearLogDeletesStoredCrashReports() {
    let suite = "TokCrashDiagnosticsTests.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, supportDirectory: root)
    let store = DictationStore(settings: settings)
    store.crashDiagnostics.store([("hang", json("h"))])
    XCTAssertEqual(storedNames(store.crashDiagnostics).count, 1)
    store.clearDiagnostics()
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.crashDiagnostics.directory.path))
    XCTAssertEqual(store.crashDiagnostics.reportSection(), "")
  }
}
