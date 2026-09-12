import XCTest

@testable import Tok
@testable import TokEngine

@MainActor
final class SettingsImportTests: XCTestCase {
  func testImportPreservesExistingHistoryPolicy() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "TokImportTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = SettingsStore(defaults: defaults, supportDirectory: root)
    settings.set("HISTORY_RETENTION_DAYS", "30")
    let source = root.appendingPathComponent("import.env")
    try "HISTORY_RETENTION_DAYS=7\nHOTKEY=RIGHT_OPTION\n".write(
      to: source, atomically: true, encoding: .utf8)
    var notifiedRetention: Int?
    settings.didChange = { _ in notifiedRetention = settings.configuration.historyRetentionDays }
    try settings.importConfiguration(from: source)
    XCTAssertEqual(settings.string("HISTORY_RETENTION_DAYS"), "30")
    XCTAssertEqual(notifiedRetention, 30)
    XCTAssertEqual(settings.string("HOTKEY"), "RIGHT_OPTION")
  }
}
