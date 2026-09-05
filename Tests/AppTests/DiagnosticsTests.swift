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
