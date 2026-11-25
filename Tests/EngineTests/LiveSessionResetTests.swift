// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import TokEngine

/// SMART transcription keeps text context across the turns of one live session, so a
/// session is replaced once a turn has used it: in the background after the server
/// completes a turn, and at the start of a turn that would otherwise inherit earlier text.
/// When a session is reused anyway, the earlier turns' text is removed from each finalized
/// transcription, and a transcript that cannot be separated fails the live turn.
final class LiveSessionResetTests: XCTestCase {
  private static let conversationalModel = "gemini-live-conversational-fixture"

  /// A client whose connects stay off the network, and the connection_events kinds it
  /// reports. Events arrive on the test thread and on settleQueue, so reads take the lock.
  private func offlineClient(
    model: String = "gemini-3.5-transcribe-live", smart: Bool = true
  ) -> (client: GeminiLiveClient, kinds: () -> [String]) {
    let client = GeminiLiveClient(
      apiKey: "fixture-key", model: model, smartTranscription: smart)
    client.connectTransport = { _, _ in }
    let eventLock = NSLock()
    var recorded: [String] = []
    client.onConnectionEvent = { kind, _, _ in
      eventLock.lock()
      recorded.append(kind)
      eventLock.unlock()
    }
    return (
      client,
      {
        eventLock.lock()
        defer { eventLock.unlock() }
        return recorded
      }
    )
  }

  /// Runs one turn to a server completion and returns what it delivered.
  @discardableResult
  private func completeTurn(_ client: GeminiLiveClient, final text: String) -> String? {
    var delivered: String?
    client.fixtureOpen()
    client.fixtureCompletion { result in
      if case .success(let value) = result { delivered = value.text }
    }
    client.fixtureMessage(["inputTranscription": ["text": text], "turnComplete": true])
    return delivered
  }

  /// Parks settleQueue until the returned closure runs, so a queued session reset can be
  /// observed before it executes. The wait is bounded either way.
  private func holdSettleQueue(_ client: GeminiLiveClient) -> () -> Void {
    let gate = DispatchSemaphore(value: 0)
    client.settleQueue.async { _ = gate.wait(timeout: .now() + 5) }
    return { gate.signal() }
  }

  private func connectionID(_ client: GeminiLiveClient) -> UInt64 {
    client.lock.lock()
    defer { client.lock.unlock() }
    return client.connectionID
  }

  private func deferredRotation(_ client: GeminiLiveClient) -> Bool {
    client.lock.lock()
    defer { client.lock.unlock() }
    return client.rotateWhenIdle
  }

  private func sessionUsed(_ client: GeminiLiveClient) -> Bool {
    client.lock.lock()
    defer { client.lock.unlock() }
    return client.sessionUsedBySmartTurn
  }

  private func committedSessionText(_ client: GeminiLiveClient) -> String {
    client.lock.lock()
    defer { client.lock.unlock() }
    return client.sessionCommittedTranscript
  }

  private func markSessionUsed(_ client: GeminiLiveClient) {
    client.lock.lock()
    client.sessionUsedBySmartTurn = true
    client.lock.unlock()
  }

  // MARK: Background reset after a server turn completion

  func testServerTurnCompletionResetsASmartSessionInTheBackground() {
    let (client, kinds) = offlineClient()
    let before = connectionID(client)
    let release = holdSettleQueue(client)
    let delivered = completeTurn(client, final: "First turn.")
    XCTAssertEqual(delivered, "First turn.")
    XCTAssertEqual(
      connectionID(client), before, "the completion is delivered before the session is replaced")
    XCTAssertEqual(committedSessionText(client), "First turn.")
    release()
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), ["connect_turn_reset"])
    XCTAssertEqual(connectionID(client), before &+ 1)
    XCTAssertEqual(client.socketStateAtKeydown.state, "connecting")
    XCTAssertFalse(sessionUsed(client), "the new connection starts without context")
    XCTAssertEqual(committedSessionText(client), "")
    client.shutdown()
  }

  func testVerbatimSessionIsReusedAfterAServerTurnCompletion() {
    let (client, kinds) = offlineClient(smart: false)
    let before = connectionID(client)
    XCTAssertEqual(completeTurn(client, final: "First turn."), "First turn.")
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), [])
    XCTAssertEqual(connectionID(client), before)
    XCTAssertFalse(sessionUsed(client))
    client.shutdown()
  }

  func testConversationalSessionIsReusedAfterAServerTurnCompletion() {
    let (client, kinds) = offlineClient(model: Self.conversationalModel)
    let before = connectionID(client)
    XCTAssertEqual(completeTurn(client, final: "First turn."), "First turn.")
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), [])
    XCTAssertEqual(connectionID(client), before)
    client.shutdown()
  }

  func testDisconnectCancelsAQueuedSessionReset() {
    let (client, kinds) = offlineClient()
    let release = holdSettleQueue(client)
    completeTurn(client, final: "First turn.")
    client.disconnect()
    let afterDisconnect = connectionID(client)
    release()
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), [], "a reset queued before disconnect never reconnects")
    XCTAssertEqual(connectionID(client), afterDisconnect)
    XCTAssertEqual(client.socketStateAtKeydown.state, "closed")
    client.shutdown()
  }

  func testQueuedSessionResetDefersToATurnThatIsAlreadyOpen() {
    let (client, kinds) = offlineClient()
    let before = connectionID(client)
    let release = holdSettleQueue(client)
    completeTurn(client, final: "First turn.")
    // The next turn opens, ready, before the queued reset runs. startNewTurn() would replace
    // the used session itself, so this drives the connect guard directly.
    client.fixtureOpen()
    release()
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), [], "a healthy open turn is not interrupted")
    XCTAssertEqual(connectionID(client), before)
    XCTAssertTrue(deferredRotation(client), "the reset is owed once the open turn ends")
    XCTAssertTrue(client.canCommitTurn)

    var second: String?
    client.fixtureCompletion { result in
      if case .success(let value) = result { second = value.text }
    }
    client.fixtureMessage([
      "inputTranscription": ["text": "First turn. Second turn."], "turnComplete": true,
    ])
    XCTAssertEqual(second, "Second turn.")
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), ["connect_turn_reset"])
    XCTAssertEqual(connectionID(client), before &+ 1)
    XCTAssertFalse(deferredRotation(client))
    client.shutdown()
  }

  // MARK: Proactive reset at turn start

  func testFinalizedTextMarksSessionContextEvenWithNoTurnOpen() {
    let (client, _) = offlineClient()
    client.fixtureSetupComplete()
    XCTAssertFalse(sessionUsed(client))
    client.fixtureMessage(["inputTranscription": ["text": " \n "]])
    XCTAssertFalse(sessionUsed(client), "whitespace is not context")
    client.fixtureMessage(["interimInputTranscription": ["text": "speculative words"]])
    XCTAssertFalse(sessionUsed(client), "an interim is not finalized text")
    client.fixtureMessage(["inputTranscription": ["text": "Stale words."]], oldConnection: true)
    XCTAssertFalse(sessionUsed(client), "an earlier connection says nothing about this one")
    client.fixtureMessage(["inputAudioTranscription": ["text": "Late words."]])
    XCTAssertTrue(sessionUsed(client))
    XCTAssertEqual(client.fixtureText(), "", "a closed turn still ignores the text itself")
    client.fixtureSetupComplete()
    XCTAssertFalse(sessionUsed(client), "a new session starts clean")
    client.shutdown()
  }

  func testVerbatimSessionNeverRecordsContext() {
    let (client, kinds) = offlineClient(smart: false)
    client.fixtureSetupComplete()
    client.fixtureMessage(["inputTranscription": ["text": "Late words."]])
    XCTAssertFalse(sessionUsed(client))
    client.startNewTurn()
    XCTAssertEqual(kinds(), [])
    XCTAssertFalse(client.lastConnectionChangedDuringTurn)
    client.shutdown()
  }

  func testTurnStartReplacesASessionThatAlreadyHasContext() {
    let (client, kinds) = offlineClient()
    client.fixtureSetupComplete()
    client.fixtureMessage(["inputTranscription": ["text": "Words from an earlier turn."]])
    let before = connectionID(client)
    client.startNewTurn()
    XCTAssertEqual(kinds(), ["connect_turn_reset"])
    XCTAssertEqual(connectionID(client), before &+ 1)
    XCTAssertTrue(
      client.lastConnectionChangedDuringTurn, "the reset is recorded against the new turn")
    XCTAssertFalse(sessionUsed(client))
    XCTAssertEqual(client.socketStateAtKeydown.state, "connecting")
    XCTAssertFalse(client.recoveryGap, "a reset before the turn opens loses no audio")
    client.recoveryDrain()
    XCTAssertEqual(client.recoveryPending, 1, "activityStart waits for the new handshake")

    // Starting again abandons the open turn, which replaces its socket as a planned reset.
    // That new session has no context, so the turn start adds no second reset.
    client.startNewTurn()
    XCTAssertEqual(kinds(), ["connect_turn_reset", "connect_turn_reset"])
    XCTAssertFalse(client.lastConnectionChangedDuringTurn)
    client.shutdown()
  }

  func testTurnStartResetSupersedesAQueuedBackgroundReset() {
    let (client, kinds) = offlineClient()
    let before = connectionID(client)
    let release = holdSettleQueue(client)
    completeTurn(client, final: "First turn.")
    XCTAssertTrue(sessionUsed(client))
    client.startNewTurn()
    XCTAssertEqual(kinds(), ["connect_turn_reset"])
    XCTAssertEqual(connectionID(client), before &+ 1)
    release()
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), ["connect_turn_reset"], "the queued reset is stale and dropped")
    XCTAssertEqual(connectionID(client), before &+ 1)
    XCTAssertFalse(client.recoveryGap)
    XCTAssertFalse(deferredRotation(client))
    client.shutdown()
  }

  func testTurnStartDoesNotReconnectADisconnectedClient() {
    let (client, kinds) = offlineClient()
    client.fixtureSetupComplete()
    client.disconnect()
    markSessionUsed(client)
    let before = connectionID(client)
    client.startNewTurn()
    XCTAssertEqual(kinds(), [], "disconnect stays in force")
    XCTAssertEqual(connectionID(client), before)
    XCTAssertFalse(client.lastConnectionChangedDuringTurn)
    XCTAssertEqual(client.socketStateAtKeydown.state, "closed")
    client.shutdown()
  }

  func testTurnStartDoesNotReconnectAfterTheKeyRejectionStop() {
    let (client, kinds) = offlineClient()
    client.recoveryFixture(LiveWriteProbe())
    guard let task = client.webSocketTask else { return XCTFail("fixture has no task") }
    client.urlSession(
      client.urlSession, webSocketTask: task, didCloseWith: .policyViolation,
      reason: Data("API key not valid".utf8))
    var rejections = 0
    client.onAuthRejected = { rejections += 1 }
    let epoch = connectionID(client)
    // Three consecutive rejections stop the reconnect loop.
    for _ in 0..<3 {
      client.connectionFailed(epoch: epoch, error: NSError(domain: "fixture", code: 1))
    }
    XCTAssertEqual(rejections, 1)
    // Each turn after the stop opens and is abandoned, as a REST-settled turn is. Neither
    // the turn start nor the abandon may restart the client or clear the rejection streak.
    for turn in 1...3 {
      markSessionUsed(client)
      client.startNewTurn()
      XCTAssertFalse(client.lastConnectionChangedDuringTurn, "turn \(turn)")
      client.abandonTurn()
      XCTAssertEqual(connectionID(client), epoch, "turn \(turn): the stop stays in force")
    }
    XCTAssertFalse(
      kinds().contains { $0.hasPrefix("connect_") }, "no connect after the stop: \(kinds())")
    // The streak survived: one more rejection is reported at once rather than counted
    // toward a fresh three-strike limit and retried.
    client.connectionFailed(epoch: epoch, error: NSError(domain: "fixture", code: 1))
    XCTAssertEqual(rejections, 2)
    client.settleQueue.sync {}
    XCTAssertFalse(kinds().contains { $0.hasPrefix("connect_") })
    XCTAssertEqual(connectionID(client), epoch)
    client.shutdown()
  }

  func testAHeuristicSettleDoesNotReconnectAfterTheKeyRejectionStop() {
    let (client, kinds) = offlineClient()
    client.recoveryFixture(LiveWriteProbe())
    guard let task = client.webSocketTask else { return XCTFail("fixture has no task") }
    client.urlSession(
      client.urlSession, webSocketTask: task, didCloseWith: .policyViolation,
      reason: Data("API key not valid".utf8))
    let epoch = connectionID(client)
    for _ in 0..<3 {
      client.connectionFailed(epoch: epoch, error: NSError(domain: "fixture", code: 1))
    }
    client.startNewTurn()
    var delivered: String?
    client.fixtureCompletion { result in
      if case .success(let value) = result { delivered = value.text }
    }
    client.fixtureMessage(["interimInputTranscription": ["text": "late words"]])
    // The settle ceiling has passed: the turn settles on its interim text, and the reset
    // that follows a heuristic finish is dropped because reconnects are stopped.
    client.recoveryForceSettleAge()
    XCTAssertEqual(delivered, "late words")
    XCTAssertFalse(
      kinds().contains { $0.hasPrefix("connect_") }, "no connect after the stop: \(kinds())")
    XCTAssertEqual(connectionID(client), epoch)
    client.shutdown()
  }

  func testAbandonTurnDoesNotReconnectADisconnectedClient() {
    let (client, kinds) = offlineClient()
    client.fixtureSetupComplete()
    client.startNewTurn()
    client.disconnect()
    let afterDisconnect = connectionID(client)
    for _ in 1...2 {
      client.abandonTurn()
      client.startNewTurn()
    }
    client.abandonTurn()
    XCTAssertFalse(
      kinds().contains { $0.hasPrefix("connect_") }, "disconnect stays in force: \(kinds())")
    XCTAssertEqual(connectionID(client), afterDisconnect)
    XCTAssertEqual(client.socketStateAtKeydown.state, "closed")
    client.shutdown()
  }

  func testAbandonTurnReplacesTheSocketAsAPlannedReset() {
    let (client, kinds) = offlineClient(smart: false)
    client.fixtureSetupComplete()
    let before = connectionID(client)
    client.startNewTurn()
    XCTAssertEqual(kinds(), [], "a VERBATIM session is reused at turn start")
    client.abandonTurn()
    XCTAssertEqual(kinds(), ["connect_turn_reset"])
    XCTAssertEqual(connectionID(client), before &+ 1)
    client.abandonTurn()
    XCTAssertEqual(kinds(), ["connect_turn_reset"], "no open turn, nothing to replace")
    client.shutdown()
  }

  // MARK: A SMART turn's audio marks the session used

  /// A client on a ready socket whose writes the probe accepts and completes in order.
  private func readyClient(smart: Bool = true) -> (
    client: GeminiLiveClient, kinds: () -> [String], probe: LiveWriteProbe
  ) {
    let (client, kinds) = offlineClient(smart: smart)
    let probe = LiveWriteProbe()
    client.recoveryFixture(probe)
    client.recoveryReady()
    return (client, kinds, probe)
  }

  /// Runs one turn whose only text is an interim, sent while recording, then completed by
  /// the server. Returns what it delivered.
  private func completeInterimOnlyTurn(
    _ client: GeminiLiveClient, probe: LiveWriteProbe, text: String
  ) -> String? {
    client.startNewTurn()
    client.recoveryDrain()
    for index in probe.sent.indices { probe.finish(index) }
    client.recoveryDrain()
    var delivered: String?
    client.fixtureMessage(["interimInputTranscription": ["text": text]])
    client.fixtureCompletion { result in
      if case .success(let value) = result { delivered = value.text }
    }
    client.fixtureMessage(["turnComplete": true])
    return delivered
  }

  func testTurnStartKeepsAFreshSmartSessionThatNoTurnHasUsed() {
    let (client, kinds, probe) = readyClient()
    XCTAssertFalse(sessionUsed(client))
    let before = connectionID(client)
    client.startNewTurn()
    XCTAssertEqual(kinds(), [], "a fresh session is not replaced")
    XCTAssertEqual(connectionID(client), before)
    XCTAssertFalse(client.lastConnectionChangedDuringTurn)
    client.recoveryDrain()
    XCTAssertEqual(probe.sent.count, 1, "activityStart goes out on the fresh session")
    XCTAssertTrue(sessionUsed(client), "the turn's first write marks the session used")
    client.shutdown()
  }

  func testInterimOnlyTurnStillResetsTheSessionAtTheNextTurnStart() {
    let (client, kinds, probe) = readyClient()
    let before = connectionID(client)
    let release = holdSettleQueue(client)
    XCTAssertEqual(
      completeInterimOnlyTurn(client, probe: probe, text: "hello there"), "hello there")
    XCTAssertTrue(sessionUsed(client), "no final arrived, but the turn's audio did")
    XCTAssertEqual(kinds(), [], "the background reset is still queued")
    // A re-press before the queued reset runs starts on a new connection anyway.
    client.startNewTurn()
    XCTAssertEqual(kinds(), ["connect_turn_reset"])
    XCTAssertEqual(connectionID(client), before &+ 1)
    XCTAssertTrue(client.lastConnectionChangedDuringTurn)
    XCTAssertFalse(client.recoveryGap)
    release()
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), ["connect_turn_reset"], "the queued reset is stale and dropped")
    client.shutdown()
  }

  func testVerbatimTurnWritesDoNotMarkTheSessionUsed() {
    let (client, kinds, probe) = readyClient(smart: false)
    let before = connectionID(client)
    XCTAssertEqual(
      completeInterimOnlyTurn(client, probe: probe, text: "hello there"), "hello there")
    XCTAssertFalse(sessionUsed(client))
    client.startNewTurn()
    client.settleQueue.sync {}
    XCTAssertEqual(kinds(), [], "a VERBATIM session is reused")
    XCTAssertEqual(connectionID(client), before)
    client.shutdown()
  }

  // MARK: Earlier-turn prefix removal

  private func stripped(_ incoming: String, _ committed: String) -> String? {
    GeminiLiveClient.strippingSessionPrefix(incoming, committed: committed)
  }

  func testPrefixHelperRemovesAnExactPrefix() {
    XCTAssertEqual(stripped("Hello world. Next sentence.", "Hello world."), "Next sentence.")
    XCTAssertEqual(stripped("Hello world next", "Hello world"), "next")
  }

  func testPrefixHelperToleratesAnEditedTerminator() {
    XCTAssertEqual(stripped("Hello world, next.", "Hello world."), "next.")
    XCTAssertEqual(stripped("Hello world; and then more", "Hello world!"), "and then more")
    XCTAssertEqual(stripped("Hello world: next", "Hello world?"), "next")
    XCTAssertEqual(stripped("Hello world next.", "Hello world."), "next.")
    XCTAssertEqual(stripped("Hello world. Next.", "Hello world"), "Next.")
  }

  func testPrefixHelperFollowsAMultiTurnChain() {
    let first = "Send the report."
    let second = "Send the report. Copy the team."
    let third = "Send the report, copy the team, and book a room."
    XCTAssertEqual(stripped(second, first), "Copy the team.")
    XCTAssertNil(stripped(third, second), "a reworded earlier turn is not a prefix")
    let thirdVerbatim = "Send the report. Copy the team. Book a room."
    XCTAssertEqual(stripped(thirdVerbatim, second), "Book a room.")
  }

  func testPrefixHelperRequiresAWordBoundary() {
    XCTAssertNil(stripped("Google.com is the site", "Google"))
    XCTAssertNil(stripped("Test.swift compiles", "Test"))
    XCTAssertNil(stripped("Test.swift compiles", "Test."))
    XCTAssertNil(stripped("Hello worldly goods", "Hello world"))
    XCTAssertNil(stripped("Version 2.5 shipped", "Version 2."))
    // A dot inside the committed text is matched literally, and one that starts a new
    // word stays with that word.
    XCTAssertEqual(stripped("Open Google.com. Then search.", "Open Google.com."), "Then search.")
    XCTAssertEqual(stripped("Open the file. .swift sources", "Open the file."), ".swift sources")
  }

  func testPrefixHelperReturnsEmptyForAReplay() {
    XCTAssertEqual(stripped("Hello world.", "Hello world."), "")
    XCTAssertEqual(stripped("Hello world", "Hello world."), "")
    XCTAssertEqual(stripped("Hello world!", "Hello world."), "")
    XCTAssertEqual(stripped("  Hello world. \n", "Hello world."), "")
  }

  func testPrefixHelperIgnoresWhitespaceDifferences() {
    XCTAssertEqual(stripped("  Hello world.\n Next.  ", "Hello world."), "Next.")
    XCTAssertEqual(stripped("Hello  world.\nNext.", "Hello world. "), "Next.")
    XCTAssertEqual(stripped("Hello world. Next.", "Hello\n world."), "Next.")
    XCTAssertEqual(stripped("Hello world , next", "Hello world."), "next")
    XCTAssertNil(stripped("Helloworld. Next.", "Hello world."), "a missing space is a new word")
  }

  func testPrefixHelperReturnsNilWithoutAMatch() {
    XCTAssertNil(stripped("Something else entirely.", "Hello world."))
    XCTAssertNil(stripped("Hello", "Hello world."), "a shorter text does not contain the prefix")
    XCTAssertNil(stripped("hello world. Next.", "Hello world."), "case is part of the match")
    XCTAssertNil(stripped("", "Hello world."))
    XCTAssertNil(stripped("Anything at all.", "..."), "punctuation alone is no prefix")
    XCTAssertNil(stripped("Anything at all.", ""))
  }

  // MARK: Reused session safety net

  /// An empty key makes every connect a no-op, which stands in for a session that was not
  /// replaced between turns. With a key, every SMART turn that sent audio is followed by a
  /// new connection before the next turn opens (see the turn-start tests above), so this
  /// safety net has no production entry point to drive it through.
  private func reusedSessionClient(smart: Bool = true) -> GeminiLiveClient {
    let client = GeminiLiveClient(apiKey: "", smartTranscription: smart)
    XCTAssertEqual(completeTurn(client, final: "Hello world."), "Hello world.")
    return client
  }

  func testReusedSessionDeliversOnlyTheNewTurnsText() {
    let client = reusedSessionClient()
    XCTAssertEqual(committedSessionText(client), "Hello world.")
    client.startNewTurn()
    XCTAssertFalse(
      client.lastConnectionChangedDuringTurn, "a connect that never happened is not recorded")
    client.fixtureMessage(["interimInputTranscription": ["text": "next thing"]])
    XCTAssertEqual(client.fixtureText(), "next thing")
    var second: String?
    client.fixtureCompletion { result in
      if case .success(let value) = result { second = value.text }
    }
    client.fixtureMessage([
      "inputTranscription": ["text": "Hello world, next thing.\n"], "turnComplete": true,
    ])
    XCTAssertEqual(second, "next thing.")
    XCTAssertEqual(committedSessionText(client), "Hello world, next thing.")

    // The third turn is measured against everything the session has committed so far.
    client.startNewTurn()
    var third: String?
    client.fixtureCompletion { result in
      if case .success(let value) = result { third = value.text }
    }
    client.fixtureMessage([
      "inputTranscription": ["text": "Hello world, next thing. And a third."],
      "turnComplete": true,
    ])
    XCTAssertEqual(third, "And a third.")
    client.shutdown()
  }

  func testReusedSessionReplayAddsNoTextAndDoesNotFailTheTurn() {
    let client = reusedSessionClient()
    client.startNewTurn()
    client.fixtureMessage(["interimInputTranscription": ["text": "more words"]])
    var results = 0
    var second: String?
    client.fixtureCompletion { result in
      results += 1
      if case .success(let value) = result { second = value.text }
    }
    client.fixtureMessage(["inputTranscription": ["text": "Hello world."]])
    XCTAssertEqual(client.fixtureText(), "", "a replay of earlier turns is not this turn's text")
    XCTAssertFalse(client.recoveryGap)
    XCTAssertEqual(results, 0, "a replay does not settle the turn")
    client.fixtureMessage([
      "inputTranscription": ["text": "Hello world. More words."], "turnComplete": true,
    ])
    XCTAssertEqual(results, 1)
    XCTAssertEqual(second, "More words.")
    client.shutdown()
  }

  func testReusedSessionMismatchFailsACommittedLiveTurn() {
    let client = reusedSessionClient()
    var kinds: [String] = []
    client.onConnectionEvent = { kind, _, _ in kinds.append(kind) }
    var liveUpdates: [String] = []
    client.onLiveTextUpdate = { liveUpdates.append($0) }
    client.startNewTurn()
    var failures: [NSError] = []
    var successes = 0
    client.fixtureCompletion { result in
      switch result {
      case .success: successes += 1
      case .failure(let error): failures.append(error as NSError)
      }
    }
    client.fixtureMessage([
      "inputTranscription": ["text": "A rewritten opening, then new words."], "turnComplete": true,
    ])
    XCTAssertEqual(successes, 0, "text that cannot be separated is never delivered")
    XCTAssertEqual(failures.count, 1, "the live turn fails so the backup route settles it")
    XCTAssertEqual(failures.first?.domain, "Tok")
    XCTAssertEqual(failures.first?.code, -4)
    XCTAssertTrue(client.recoveryGap)
    XCTAssertFalse(client.canCommitTurn)
    XCTAssertFalse(client.isReady, "the socket that carried the stale text is retired")
    XCTAssertEqual(client.fixtureText(), "")
    XCTAssertEqual(liveUpdates, [], "the mixed transcript never reaches the HUD")
    XCTAssertEqual(kinds, ["lost_context_mismatch"], "a planned retirement, not a lost socket")

    // Further finals on the failed turn change nothing and report nothing.
    client.fixtureMessage(["inputTranscription": ["text": "Still not a continuation."]])
    XCTAssertEqual(failures.count, 1)
    XCTAssertEqual(kinds, ["lost_context_mismatch"])
    XCTAssertEqual(client.fixtureText(), "")
    client.shutdown()
  }

  func testReusedSessionMismatchDuringTheHoldMakesTheTurnUncommittable() {
    let client = reusedSessionClient()
    client.startNewTurn()
    XCTAssertTrue(client.canCommitTurn)
    client.fixtureMessage(["inputTranscription": ["text": "Unrelated words."]])
    XCTAssertTrue(client.recoveryGap)
    XCTAssertFalse(client.canCommitTurn, "the engine sends this turn straight to the backup route")
    var rejected = false
    client.fixtureBeginCommit { if case .failure = $0 { rejected = true } }
    XCTAssertTrue(rejected, "a commit attempted anyway fails at once")
    client.shutdown()
  }

  func testReusedVerbatimSessionKeepsFinalsAsSent() {
    let client = reusedSessionClient(smart: false)
    XCTAssertEqual(committedSessionText(client), "")
    client.startNewTurn()
    var second: String?
    client.fixtureCompletion { result in
      if case .success(let value) = result { second = value.text }
    }
    client.fixtureMessage([
      "inputTranscription": ["text": "Hello world. Said again."], "turnComplete": true,
    ])
    XCTAssertEqual(second, "Hello world. Said again.")
    client.shutdown()
  }

  // MARK: Whitespace

  func testWhitespaceOnlyPayloadsAreIgnoredAndTextReachesTheAccumulatorAsSent() {
    let client = GeminiLiveClient(apiKey: "")
    var liveUpdates: [String] = []
    client.onLiveTextUpdate = { liveUpdates.append($0) }
    client.fixtureOpen()
    client.fixtureMessage(["inputTranscription": ["text": " \n\t "]])
    client.fixtureMessage(["interimInputTranscription": ["text": "   "]])
    client.fixtureMessage(["inputAudioTranscription": ["text": "\n"]])
    XCTAssertEqual(client.fixtureText(), "")
    XCTAssertEqual(liveUpdates, [])
    client.fixtureMessage(["interimInputTranscription": ["text": "hello there"]])
    XCTAssertEqual(client.fixtureText(), "hello there")
    client.fixtureMessage(["inputTranscription": ["text": "Hello there.\n"]])
    XCTAssertEqual(client.fixtureText(), "Hello there.\n", "a final keeps its line break")
    client.fixtureMessage(["inputAudioTranscription": ["text": "Second sentence."]])
    XCTAssertEqual(client.fixtureText(), "Hello there.\nSecond sentence.")
    // A whitespace-only final gives way to the interim carried by the same message.
    client.fixtureMessage([
      "inputTranscription": ["text": "  "], "interimInputTranscription": ["text": "third"],
    ])
    XCTAssertEqual(client.fixtureText(), "Hello there.\nSecond sentence. third")
    XCTAssertEqual(liveUpdates.last, "Hello there.\nSecond sentence. third")
    client.shutdown()
  }

  // MARK: Finals within one turn

  private func turnText(smart: Bool, finals: [String]) -> String {
    let client = GeminiLiveClient(apiKey: "", smartTranscription: smart)
    client.fixtureOpen()
    for text in finals { client.fixtureMessage(["inputTranscription": ["text": text]]) }
    defer { client.shutdown() }
    return client.fixtureText()
  }

  func testALineBreakBetweenFinalsIsKept() {
    for smart in [true, false] {
      XCTAssertEqual(
        turnText(smart: smart, finals: ["Para one.\n", "Para two."]), "Para one.\nPara two.",
        "smart: \(smart)")
    }
  }

  func testSmartFinalThatRewritesTheJoinReplacesTheTurnText() {
    XCTAssertEqual(
      turnText(smart: true, finals: ["Hello world.", "Hello world, next sentence."]),
      "Hello world, next sentence.")
    XCTAssertEqual(
      turnText(
        smart: true,
        finals: [
          "Hello world.", "Hello world, next sentence.", "Hello world, next sentence; more.",
        ]
      ),
      "Hello world, next sentence; more.")
    // A rewrite earlier than the join is not an extension, so the segment rules apply and
    // no words are dropped.
    XCTAssertEqual(
      turnText(smart: true, finals: ["Hello world. Next.", "Hello world, next!"]),
      "Hello world. Next. Hello world, next!")
  }

  func testSmartFinalThatExtendsTheTurnTextExactlyStillReplacesIt() {
    XCTAssertEqual(
      turnText(smart: true, finals: ["Hello world.", "Hello world. Next sentence."]),
      "Hello world. Next sentence.")
  }

  func testSmartFinalsForSeparateSegmentsStillMerge() {
    XCTAssertEqual(
      turnText(smart: true, finals: ["First segment.", "Second segment."]),
      "First segment. Second segment.")
    XCTAssertEqual(
      turnText(smart: true, finals: ["Hello world.", "Hello world."]), "Hello world.",
      "a repeated final adds nothing")
  }

  func testVerbatimFinalsKeepTheSegmentRules() {
    XCTAssertEqual(
      turnText(smart: false, finals: ["Hello world.", "Hello world, next sentence."]),
      "Hello world. Hello world, next sentence.")
    XCTAssertEqual(
      turnText(smart: false, finals: ["Hello world.", "Hello world. Next sentence."]),
      "Hello world. Next sentence.")
    XCTAssertEqual(
      turnText(smart: false, finals: ["First segment.", "Second segment."]),
      "First segment. Second segment.")
  }

  func testReusedSessionRewrittenJoinWithinATurnReplacesTheTurnText() {
    let client = reusedSessionClient()
    client.startNewTurn()
    client.fixtureMessage(["inputTranscription": ["text": "Hello world. Send it."]])
    XCTAssertEqual(client.fixtureText(), "Send it.")
    var second: String?
    client.fixtureCompletion { result in
      if case .success(let value) = result { second = value.text }
    }
    client.fixtureMessage([
      "inputTranscription": ["text": "Hello world. Send it, then file it."], "turnComplete": true,
    ])
    XCTAssertEqual(second, "Send it, then file it.")
    client.shutdown()
  }
}
