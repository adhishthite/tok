// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import TokEngine

final class LiveIntegrationTests: XCTestCase {
  private func inputs() throws -> (EngineConfiguration, Data, URL) {
    guard ProcessInfo.processInfo.environment["TOK_LIVE_TESTS"] == "1" else {
      throw XCTSkip("Run the TokLiveChecks scheme to authorize real API calls.")
    }
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOK_PROJECT_ROOT"]!)
    let content = try String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8)
    var values: [String: String] = [:]
    for line in content.components(separatedBy: .newlines) {
      let line = line.trimmingCharacters(in: .whitespaces)
      guard !line.hasPrefix("#"), let separator = line.firstIndex(of: "=") else { continue }
      let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
      var value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
      if value.count >= 2,
        (value.hasPrefix("\"") && value.hasSuffix("\""))
          || (value.hasPrefix("'") && value.hasSuffix("'"))
      {
        value = String(value.dropFirst().dropLast())
      }
      values[key] = value
    }
    let config = EngineConfiguration.load(values: values)
    XCTAssertFalse(config.geminiApiKey.isEmpty, "API key must be present")
    Log.configure(delegate: nil, apiKey: config.geminiApiKey, privacyMode: true)
    let pcm = try Data(contentsOf: root.appendingPathComponent("build/fixtures/english.pcm"))
    XCTAssertGreaterThan(pcm.count, 32000)
    return (config, pcm, root)
  }

  func testThreeLiveTurns() throws {
    let (config, pcm, root) = try inputs()
    let client = GeminiLiveClient(
      apiKey: config.geminiApiKey, model: config.geminiLiveModel,
      smartTranscription: config.smartTranscription, languageCodes: config.languageCodes,
      vadMode: config.vadMode, vadSilenceMs: config.vadSilenceMs,
      endpointAligned: config.wsEndpointAligned)
    defer { client.disconnect() }
    client.connect()
    var rows: [[String: Any]] = []
    for repetition in 1...3 {
      let setupDeadline = ProcessInfo.processInfo.systemUptime + 15
      while !client.isReady, ProcessInfo.processInfo.systemUptime < setupDeadline {
        Thread.sleep(forTimeInterval: 0.02)
      }
      guard client.isReady else {
        XCTFail("Live handshake did not become ready within 15 seconds")
        return
      }
      client.startNewTurn()
      client.sendAudioChunk(Data(count: config.preRollMs * 32))
      let started = ProcessInfo.processInfo.systemUptime
      for offset in stride(from: 0, to: pcm.count, by: config.chunkMs * 32) {
        let end = min(pcm.count, offset + config.chunkMs * 32)
        let remaining = Double(end) / 32000 - (ProcessInfo.processInfo.systemUptime - started)
        if remaining > 0 { Thread.sleep(forTimeInterval: remaining) }
        client.sendAudioChunk(pcm.subdata(in: offset..<end))
      }
      let released = ProcessInfo.processInfo.systemUptime
      if config.silenceFlushMs > 0 {
        client.sendAudioChunk(Data(count: config.silenceFlushMs * 32))
      }
      let done = DispatchSemaphore(value: 0)
      var row: [String: Any] = ["repetition": repetition]
      client.commitTurn { result in
        defer { done.signal() }
        let elapsed = (ProcessInfo.processInfo.systemUptime - released) * 1000
        row["audio_end_to_settle_ms"] = elapsed
        row["settle_path"] = client.lastSettlePath ?? "unknown"
        switch result {
        case .success(let payload):
          row["success"] = true
          let normalized = payload.text.lowercased().filter { $0.isLetter || $0.isWhitespace }
          XCTAssertEqual(normalized, "please send the revised architecture report by friday")
        case .failure(let error):
          row["success"] = false
          row["error_code"] = (error as NSError).code
          XCTFail("Live transcription failed with code \((error as NSError).code)")
        }
      }
      XCTAssertEqual(done.wait(timeout: .now() + 15), .success)
      rows.append(row)
      Thread.sleep(forTimeInterval: 0.3)
    }
    let data = try JSONSerialization.data(
      withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: root.appendingPathComponent("build/live-api-results.json"), options: .atomic)
  }

  func testRESTFallbackTranscribesSpeech() throws {
    let (config, pcm, _) = try inputs()
    let done = DispatchSemaphore(value: 0)
    let request = GeminiRestClient.transcribe(
      pcmData: pcm, apiKey: config.geminiApiKey,
      model: config.geminiModel, languageCodes: config.languageCodes, customVocabulary: []
    ) { result in
      defer { done.signal() }
      switch result {
      case .success(let payload):
        XCTAssertEqual(
          payload.text.lowercased().filter { $0.isLetter || $0.isWhitespace },
          "please send the revised architecture report by friday")
      case .failure(let error):
        XCTFail("REST transcription failed with code \((error as NSError).code)")
      }
    }
    defer { request.cancel() }
    XCTAssertEqual(done.wait(timeout: .now() + 30), .success)
  }
}
