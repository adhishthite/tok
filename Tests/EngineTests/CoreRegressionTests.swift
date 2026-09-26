// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3
import XCTest

@testable import TokEngine

final class CoreRegressionTests: XCTestCase {
  func testReferenceFixtures() throws {
    func pairs(_ input: [CorrectionWatcher.Pair]) -> [String] {
      input.map { $0.wrong + "=>" + $0.right }
    }

    check(
      pairs(CorrectionWatcher.extractCorrections(pasted: "cloud", field: "Claude", vocabSet: []))
        == ["cloud=>Claude"], "proper noun correction")
    check(
      CorrectionWatcher.extractCorrections(pasted: "cloud", field: "Cloud", vocabSet: []).isEmpty,
      "case-only changes rejected")
    check(
      CorrectionWatcher.extractCorrections(pasted: "the", field: "The", vocabSet: []).isEmpty,
      "stopword rejected")
    check(
      CorrectionWatcher.extractCorrections(
        pasted: String(repeating: "word ", count: 513), field: "word", vocabSet: []
      ).isEmpty, "long paste budget")

    var seed: UInt64 = 0x51A7
    func next(_ limit: Int) -> Int {
      seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((seed >> 32) % UInt64(limit))
    }
    let vocabulary = [
      "cloud", "Claude", "code", "Code", "report", "Priya", "priya", "the", "...", "Next.js",
      "next.js", "部署", "मराठी",
    ]
    for _ in 0..<300 {
      let n = 1 + next(12)
      let pasted = (0..<n).map { _ in vocabulary[next(vocabulary.count)] }.joined(separator: " ")
      let field = (0..<(1 + next(40))).map { _ in vocabulary[next(vocabulary.count)] }.joined(
        separator: " ")
      let expected = LegacyCorrectionWatcher.extractCorrections(
        pasted: pasted, field: field, vocabSet: ["claude"]
      ).map { $0.wrong + "=>" + $0.right }
      check(
        pairs(
          CorrectionWatcher.extractCorrections(pasted: pasted, field: field, vocabSet: ["claude"]))
          == expected, "rolling window retains gates and tie behavior")
    }

    // A deliberately blocked terminal must not block producers or grow their queue without limit.
    let writerEntered = DispatchSemaphore(value: 0)
    let releaseWriter = DispatchSemaphore(value: 0)
    let logLock = NSLock()
    var written: [String] = []
    let writer = BoundedLogBuffer { text in
      if text == "block" {
        writerEntered.signal()
        releaseWriter.wait()
      }
      logLock.lock()
      written.append(text)
      logLock.unlock()
    }
    writer.submit("block")
    check(writerEntered.wait(timeout: .now() + 1) == .success, "log sink entered")
    let enqueueStart = ProcessInfo.processInfo.systemUptime
    for i in 0..<10000 { writer.submit("meter \(i)", meter: true) }
    for _ in 0..<1000 { writer.submit("diagnostic") }
    check(
      ProcessInfo.processInfo.systemUptime - enqueueStart < 1,
      "logging producers do not wait for sink")
    releaseWriter.signal()
    writer.flush(timeout: 2)
    logLock.lock()
    let logged = written
    logLock.unlock()
    check(logged.count <= 131, "bounded log queue")
    check(logged.contains("meter 9999"), "latest meter retained")
    Log.isVerbose = false
    var formatted = false
    func expensiveMessage() -> String {
      formatted = true
      return "unexpected"
    }
    Log.meter(expensiveMessage())
    check(!formatted, "normal mode skips meter formatting")

    let retryScope = CancellableRequest()
    let retryFired = DispatchSemaphore(value: 0)
    retryScope.schedule(after: 0.02) { retryFired.signal() }
    retryScope.cancel()
    check(retryFired.wait(timeout: .now() + 0.08) == .timedOut, "cancelled retry cannot start")

    let live = GeminiLiveClient(apiKey: "")
    live.fixtureOpen()
    live.fixtureMessage(["inputTranscription": ["text": "First segment."], "turnComplete": true])
    check(live.fixtureText() == "First segment.", "pre-commit completion preserves text")
    live.fixtureMessage(["interimInputTranscription": ["text": "Second segment"]])
    var completions = 0
    var resultText = ""
    live.fixtureMeteredUsage()
    live.fixtureCompletion { result in
      completions += 1
      if case .success(let value) = result { resultText = value.text }
    }
    live.fixtureMessage(["inputTranscription": ["text": "Second segment."], "turnComplete": true])
    check(resultText == "First segment. Second segment.", "segments preserved")
    live.fixtureSetupComplete()
    check(
      live.lastTurnUsage?.inputTokens == 20 && live.lastTurnUsage?.outputTokens == 3,
      "settled usage survives replacement setup")
    live.fixtureMessage(["inputTranscription": ["text": "Late text"], "turnComplete": true])
    check(
      completions == 1 && live.fixtureText().isEmpty,
      "completion exactly once; late closed-turn text ignored")
    live.fixtureOpen()
    live.fixtureMessage(["inputTranscription": ["text": "Old connection"]], oldConnection: true)
    check(live.fixtureText().isEmpty, "old connection ignored")
    live.fixtureGap()
    check(!live.canCommitTurn, "partial stream ineligible")
    var rejected = false
    live.fixtureBeginCommit { if case .failure = $0 { rejected = true } }
    check(rejected, "partial stream fails before commit")
    let rotation = GeminiLiveClient(apiKey: "synthetic-test-value")
    rotation.fixtureOpen()
    rotation.fixtureIdleRotation()
    check(
      rotation.isReady && rotation.canCommitTurn,
      "healthy active turn defers idle rotation without opening a connection")

  }
}
