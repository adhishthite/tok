import AppKit
import SwiftUI
import XCTest

@testable import Tok
@testable import TokEngine

@MainActor
final class DiagnosticsTests: XCTestCase {
  func testAppFailuresAppearInIssueFilterAndCanBeCleared() {
    let store = DictationStore()
    store.engineDidEmit(.failure("Microphone unavailable. Try again."))
    XCTAssertEqual(store.diagnostics.count, 1)
    XCTAssertTrue(store.diagnostics[0].matches("Microphone", issuesOnly: true))
    store.clearDiagnostics()
    XCTAssertTrue(store.diagnostics.isEmpty)
    XCTAssertEqual(store.message, "Microphone unavailable. Try again.")
  }

  func testSeverityAndSearchDoNotInferErrorsFromMessageWords() {
    let warning = DiagnosticEntry(line: "[WARNING] [MIC] Device disconnected")
    XCTAssertEqual(warning.level, .warning)
    XCTAssertEqual(warning.category, "MIC")
    XCTAssertEqual(warning.message, "Device disconnected")
    XCTAssertTrue(warning.matches("device", issuesOnly: true))
    XCTAssertFalse(warning.matches("connection", issuesOnly: true))
    let info = DiagnosticEntry(line: "[CHECK] No errors found")
    XCTAssertFalse(info.matches("errors", issuesOnly: true))
    XCTAssertTrue(info.matches("errors", issuesOnly: false))
    let latency = DiagnosticEntry(line: "LATENCY route=WS total=450.0ms")
    XCTAssertEqual(latency.category, "LATENCY")
    XCTAssertEqual(latency.message, "route=WS total=450.0ms")
  }

  func testMissingTimingAndCopyOnlyDeliveryStayExplicit() {
    var turn = fixture()
    turn.totalMs = .infinity
    turn.captureFinalizeMs = -1
    turn.roundtripMs = .nan
    turn.injectMs = nil
    turn.deliveryOutcome = "copied"
    let snapshot = LatencySnapshot(record: turn)
    XCTAssertNil(snapshot.total)
    XCTAssertNil(snapshot.capture)
    XCTAssertNil(snapshot.transcription)
    XCTAssertNil(snapshot.injection)
    XCTAssertEqual(snapshot.delivery, "Copied to clipboard")
    XCTAssertEqual(LatencySnapshot.milliseconds(snapshot.total), "Not measured")
  }

  func testCleanupMetricsStaySeparateAndUnknownUsageIsNotInvented() {
    let store = DictationStore()
    var turn = fixture()
    turn.totalMs = 1350
    turn.postProcessing = PostProcessingMetrics(
      status: "completed", model: "gemini-3.5-flash-lite", latencyMs: 900, inputTokens: 200,
      outputTokens: 30, costUSD: 0.000135, appContextUsed: true)
    store.engineDidEmit(.turnSettled(turn))
    XCTAssertEqual(store.lastLatency?.transcription, 360)
    XCTAssertEqual(store.lastLatency?.postProcessing?.latencyMs, 900)
    XCTAssertTrue(store.lastLatencyLine.contains("cleanup_status=completed"))
    XCTAssertTrue(store.lastLatencyLine.contains("cleanup_input_tokens=200"))
    XCTAssertTrue(store.lastLatencyLine.contains("cleanup_thinking_tokens=n/a"))
    XCTAssertTrue(store.lastLatencyLine.contains("app_context=true"))
    turn.postProcessing = PostProcessingMetrics(
      status: "timed_out", latencyMs: 2500, errorCode: "timeout")
    turn.costUSD = nil
    store.engineDidEmit(.turnSettled(turn))
    XCTAssertTrue(store.lastLatencyLine.contains("cleanup_cost_usd=n/a"))
    XCTAssertTrue(store.lastLatencyLine.contains("total_cost_usd=n/a"))
  }

  func testRenderNativeDiagnostics() async throws {
    let entries = [
      DiagnosticEntry(line: "[SESSION] Ready for dictation"),
      DiagnosticEntry(line: "[WARNING] [MIC] Device disconnected; using the system default"),
      DiagnosticEntry(
        line:
          "LATENCY route=WS capture=60.0ms api=360.0ms injection=30.0ms total=450.0ms delivery=dispatched"
      ),
    ]
    let view = NSHostingView(
      rootView:
        VStack(spacing: 0) {
          LatencySummaryView(snapshot: LatencySnapshot(record: fixture()))
          Divider()
          DiagnosticLogView(entries: entries, clear: {})
        }.frame(width: 860, height: 420))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 860, height: 420),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/tok-diagnostics.png"))
    XCTAssertGreaterThan(bitmap.pixelsWide, 800)
  }

  // MARK: - DiagnosticsFile (audit F36)
  //
  // These exercise DiagnosticsFile directly rather than through
  // DictationStore.start(), which would apply the real history-retention
  // policy against the user's actual `~/Library/Application Support/Tok`
  // database when HISTORY_DB is unset. DiagnosticsFile alone is the
  // documented fallback for this reason.

  func testDiagnosticsFileWritesTimestampedLines() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = DiagnosticsFile(directory: directory)
    file.write("[INFO] [APP] Session ready")
    file.write("[ERROR] [APP] Something failed")
    file.close()
    let contents = try! String(
      contentsOf: directory.appendingPathComponent("diagnostics.log"), encoding: .utf8)
    let lines = contents.split(separator: "\n")
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].hasSuffix("[INFO] [APP] Session ready"))
    XCTAssertTrue(lines[1].hasSuffix("[ERROR] [APP] Something failed"))
    // ISO 8601 timestamp prefix precedes the message on its own line.
    XCTAssertTrue(lines[0].contains("T"), "expected an ISO 8601 timestamp prefix")
  }

  func testDiagnosticsFileRollsPastTheThresholdAndStaysBounded() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = DiagnosticsFile(directory: directory, rollThreshold: 100)
    for index in 0..<20 { file.write("line \(index) padding-to-grow-past-the-threshold") }
    file.close()
    let logURL = directory.appendingPathComponent("diagnostics.log")
    let rolledURL = directory.appendingPathComponent("diagnostics.1.log")
    XCTAssertTrue(FileManager.default.fileExists(atPath: rolledURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: logURL.path))
    let activeSize =
      try! FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as! Int
    // At most one line's worth of data can sit past the threshold before the
    // next write triggers another roll.
    XCTAssertLessThan(activeSize, 200)
  }

  func testReportContentsPutsRolledLinesBeforeCurrentOnes() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = DiagnosticsFile(directory: directory, rollThreshold: 50)
    file.write("first-batch-padding-to-exceed-the-roll-threshold")
    file.write("second-batch-after-the-roll")
    file.close()
    let report = file.reportContents()
    let first = try! XCTUnwrap(report.range(of: "first-batch"))
    let second = try! XCTUnwrap(report.range(of: "second-batch"))
    XCTAssertLessThan(first.lowerBound, second.lowerBound)
  }

  /// A saved report only ever contains what was handed to `write`. As long as
  /// `DictationStore.appendDiagnostic` redacts before calling it (existing
  /// behavior above this file), the persisted log never carries the secret.
  func testReportContentsNeverContainsASecretThatWasNotWritten() {
    let directory = makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = DiagnosticsFile(directory: directory)
    let secret = "fake-secret-key-should-never-appear"
    file.write("[ERROR] [APP] Auth failed for key [redacted]")
    file.close()
    let report = file.reportContents()
    XCTAssertFalse(report.contains(secret))
    XCTAssertTrue(report.contains("[redacted]"))
  }

  private func makeTempDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  private func fixture() -> TurnRecord {
    TurnRecord(
      outcome: "success", text: "Fixture transcript", charCount: 18, wordCount: 2,
      transport: "Live", model: "fixture", isLiveRoute: true, fallbackReason: nil,
      audioSeconds: 2, firstTokenMs: nil, roundtripMs: 360, captureFinalizeMs: 60,
      injectMs: 30, totalMs: 450, injected: true, inputTokens: nil, outputTokens: nil,
      tokensMetered: false, costUSD: nil, languageCodes: "en-IN", smartMode: true,
      vadMode: "manual", error: nil, appBundleId: nil, appName: nil,
      inputDevice: nil, inputTransport: nil, deliveryOutcome: "dispatched")
  }
}
