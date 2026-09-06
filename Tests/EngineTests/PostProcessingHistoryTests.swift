import Foundation
import SQLite3
import XCTest

@testable import TokEngine

final class PostProcessingHistoryTests: XCTestCase {
  func testLegacyHistoryMigratesBeforeAnyNewDictationAndKeepsExistingRows() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appendingPathComponent("history.db").path
    var db: OpaquePointer?
    XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
    let handle = try XCTUnwrap(db)
    let schema = """
      CREATE TABLE transcriptions (
      id INTEGER PRIMARY KEY,ts_epoch REAL,text TEXT,outcome TEXT,app_name TEXT,
      is_live_route INTEGER,transport TEXT,model TEXT,word_count INTEGER,cost_usd REAL,
      input_tokens INTEGER,output_tokens INTEGER,tokens_metered INTEGER,audio_seconds REAL,
      event_queue_ms REAL,capture_finalize_ms REAL,first_token_ms REAL,roundtrip_ms REAL,
      inject_ms REAL,total_ms REAL,ready_ms REAL,delivery_outcome TEXT,finish_mode TEXT,error TEXT);
      INSERT INTO transcriptions (id,ts_epoch,text,outcome,word_count,cost_usd,total_ms)
      VALUES (1,1,'Historic fixture','success',2,0.1,400);
      """
    XCTAssertEqual(sqlite3_exec(handle, schema, nil, nil, nil), SQLITE_OK)
    sqlite3_close(handle)
    let repository = HistoryRepository(path: path)
    let rows = try await repository.entries()
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows.first?.text, "Historic fixture")
    XCTAssertNil(rows.first?.postProcessing)
    XCTAssertEqual(rows.first?.transcriptionCost, 0.1)
    // Idempotence includes subsequent connections, not just the first migration.
    let again = try await repository.entries()
    XCTAssertEqual(again.count, 1)
    let stats = try await repository.statistics(since: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(stats.cost, 0.1)
    XCTAssertEqual(stats.unpricedCleanupCount, 0)
  }

  func testCleanupMetricsRoundTripAndUnknownCostsStayExplicit() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    var config = EngineConfiguration()
    config.historyDbPath = folder.appendingPathComponent("history.db").path
    config.buildId = "fixture"
    let store = HistoryStore(config: config)
    var completed = fixture()
    completed.postProcessing = PostProcessingMetrics(
      status: "completed", model: "gemini-3.5-flash-lite", latencyMs: 100,
      inputTokens: 200, outputTokens: 30, thinkingTokens: 7, costUSD: 0.002,
      appContextUsed: true)
    completed.transcriptionCostUSD = 0.01
    completed.costUSD = 0.012
    store.record(completed)
    var timedOut = fixture()
    timedOut.postProcessing = PostProcessingMetrics(
      status: "timed_out", model: "gemini-3.5-flash-lite", latencyMs: 2500, errorCode: "timeout")
    timedOut.transcriptionCostUSD = 0.02
    timedOut.costUSD = nil
    store.record(timedOut)
    store.close()
    let repository = HistoryRepository(path: config.historyDbPath)
    let rows = try await repository.entries()
    XCTAssertEqual(rows.count, 2)
    let cleanup = try XCTUnwrap(
      rows.first(where: { $0.postProcessing?.status == "completed" })?.postProcessing)
    XCTAssertEqual(cleanup.latencyMs, 100)
    XCTAssertEqual(cleanup.inputTokens, 200)
    XCTAssertEqual(cleanup.outputTokens, 30)
    XCTAssertEqual(cleanup.thinkingTokens, 7)
    XCTAssertEqual(cleanup.costUSD, 0.002)
    XCTAssertTrue(cleanup.appContextUsed)
    let fallback = try XCTUnwrap(rows.first(where: { $0.postProcessing?.status == "timed_out" }))
    XCTAssertEqual(fallback.outcome, "success")
    XCTAssertNil(fallback.cost)
    XCTAssertNil(fallback.postProcessing?.inputTokens)
    XCTAssertEqual(fallback.transcriptionCost, 0.02)
    let stats = try await repository.statistics(since: Date(timeIntervalSince1970: 0))
    XCTAssertEqual(stats.cost, 0.032, accuracy: 0.000001)
    XCTAssertEqual(stats.unpricedCleanupCount, 1)
  }

  private func fixture() -> TurnRecord {
    TurnRecord(
      outcome: "success", text: "Fixture", charCount: 7, wordCount: 1,
      transport: "Live", model: "fixture", isLiveRoute: true, fallbackReason: nil,
      audioSeconds: 1, firstTokenMs: nil, roundtripMs: 300, captureFinalizeMs: 80,
      injectMs: 15, totalMs: 500, injected: true, inputTokens: 100, outputTokens: 20,
      tokensMetered: true, costUSD: nil, languageCodes: "en-IN", smartMode: true,
      vadMode: "manual", error: nil, appBundleId: nil, appName: nil,
      inputDevice: nil, inputTransport: nil, deliveryOutcome: "dispatched")
  }
}
