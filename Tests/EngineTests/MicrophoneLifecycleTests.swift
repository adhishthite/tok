import XCTest

@testable import TokEngine

@MainActor
final class MicrophoneLifecycleTests: XCTestCase {
  func testAudioOwnerSurvivesUntilQueuedShutdownFinishes() async {
    let entered = expectation(description: "Queue held")
    let released = expectation(description: "Owner released after shutdown")
    let gate = DispatchSemaphore(value: 0)
    var audio: AudioCaptureEngine? = AudioCaptureEngine()
    XCTAssertTrue(audio!.setup(startImmediately: false))
    let lifecycle = audio!.lifecycle
    let owner = WeakAudioOwner()
    owner.value = audio
    lifecycle.queue.async {
      entered.fulfill()
      XCTAssertEqual(gate.wait(timeout: .now() + 2), .success)
    }
    await fulfillment(of: [entered], timeout: 1)
    audio!.stopEngine()
    audio = nil
    XCTAssertNotNil(owner.value)
    gate.signal()
    lifecycle.queue.async {
      DispatchQueue.main.async {
        XCTAssertNil(owner.value)
        released.fulfill()
      }
    }
    await fulfillment(of: [released], timeout: 1)
  }

  func testHardwareStartDoesNotBlockMainAndReadinessReturnsOnMain() async {
    let entered = expectation(description: "Hardware start entered")
    let ready = expectation(description: "Readiness delivered")
    let stopped = expectation(description: "Hardware stopped")
    let release = DispatchSemaphore(value: 0)
    var running = false  // Accessed only on the lifecycle queue.
    let lifecycle = MicrophoneLifecycle(
      rebuild: {
        XCTAssertFalse(Thread.isMainThread)
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        running = true
        return true
      }, stop: { running = false }, running: { running }, interrupted: { _ in })
    lifecycle.ensureReady { result in
      XCTAssertTrue(Thread.isMainThread)
      XCTAssertTrue(result)
      ready.fulfill()
    }
    await fulfillment(of: [entered], timeout: 1)
    XCTAssertFalse(lifecycle.healthy)
    // Main remains free to cancel or render while the hardware operation waits.
    release.signal()
    lifecycle.queue.async {
      lifecycle.receivedBuffer(
        generation: lifecycle.generation, at: ProcessInfo.processInfo.systemUptime)
    }
    await fulfillment(of: [ready], timeout: 1)
    XCTAssertTrue(lifecycle.healthy)
    lifecycle.suspend { stopped.fulfill() }
    XCTAssertFalse(lifecycle.healthy)
    await fulfillment(of: [stopped], timeout: 1)
  }

  func testCancellationDuringStartCannotReportLateSuccess() async {
    let entered = expectation(description: "Hardware start entered")
    let cancelled = expectation(description: "Readiness cancelled")
    let stopped = expectation(description: "Hardware stopped")
    let release = DispatchSemaphore(value: 0)
    var running = false
    let lifecycle = MicrophoneLifecycle(
      rebuild: {
        entered.fulfill()
        XCTAssertEqual(release.wait(timeout: .now() + 2), .success)
        running = true
        return true
      }, stop: { running = false }, running: { running }, interrupted: { _ in })
    lifecycle.ensureReady { result in
      XCTAssertFalse(result)
      cancelled.fulfill()
    }
    await fulfillment(of: [entered], timeout: 1)
    lifecycle.cancelPendingReadiness()
    lifecycle.suspend { stopped.fulfill() }
    release.signal()
    lifecycle.receivedBuffer(generation: 1, at: ProcessInfo.processInfo.systemUptime)
    await fulfillment(of: [cancelled, stopped], timeout: 1)
    XCTAssertFalse(lifecycle.healthy)
  }

  // Audit F15. Buffer health used to reach the recovery controller through the main queue,
  // so a stalled main thread aged every buffer past the 0.75 s freshness window and killed
  // a live hold. Health now lands on the lifecycle queue, which main cannot block.
  func testStalledMainThreadCannotFakeADeadMicrophone() async {
    let rebuilt = expectation(description: "Hardware rebuilt after audio really stopped")
    rebuilt.assertForOverFulfill = false
    var rebuilds = 0  // Lifecycle queue only.
    var running = false  // Lifecycle queue only.
    var interruptions = 0  // Main only.
    let lifecycle = MicrophoneLifecycle(
      rebuild: {
        rebuilds += 1
        running = true
        if rebuilds > 1 { rebuilt.fulfill() }
        return true
      }, stop: { running = false }, running: { running },
      interrupted: { _ in interruptions += 1 })
    // Wired exactly as AudioCaptureEngine wires its health delivery.
    let delivery = QueueDelivery<(UInt64, TimeInterval)>(queue: lifecycle.queue) { value in
      lifecycle.receivedBufferOnQueue(generation: value.0, at: value.1)
    }
    lifecycle.start()
    var generation: UInt64 = 0
    lifecycle.queue.sync { generation = lifecycle.generation }

    // A second of healthy buffers, submitted off main like the audio tap does.
    let tap = DispatchQueue(label: "tok.tests.tap")
    for step in 0..<25 {
      tap.asyncAfter(deadline: .now() + Double(step) * 0.04) {
        delivery.submit((generation, ProcessInfo.processInfo.systemUptime))
      }
    }
    // Main is unavailable for the whole hold.
    Thread.sleep(forTimeInterval: 1.1)
    try? await Task.sleep(nanoseconds: 150_000_000)
    XCTAssertEqual(interruptions, 0, "a blocked main thread must not interrupt live capture")
    var rebuildsAfterStall = 0
    lifecycle.queue.sync { rebuildsAfterStall = rebuilds }
    XCTAssertEqual(rebuildsAfterStall, 1, "live audio must not trigger a rebuild")
    XCTAssertTrue(lifecycle.healthy)

    // Audio really stops: recovery must still fire.
    await fulfillment(of: [rebuilt], timeout: 4)
    XCTAssertGreaterThan(interruptions, 0)
    lifecycle.suspend()
  }

  // The delivery target is the regression: main must never sit between the audio tap and
  // the recovery controller.
  func testCaptureEngineDeliversHealthToTheLifecycleQueue() {
    let audio = AudioCaptureEngine()
    XCTAssertTrue(audio.setup(startImmediately: false))
    XCTAssertTrue(audio.healthDelivery.queue === audio.lifecycle.queue)
    XCTAssertFalse(audio.healthDelivery.queue === DispatchQueue.main)
  }

  func testCancellationRejectsSuccessAlreadyQueuedForMain() async {
    let callback = expectation(description: "Queued success invalidated")
    let queued = DispatchSemaphore(value: 0)
    var running = false
    let lifecycle = MicrophoneLifecycle(
      rebuild: {
        running = true
        return true
      }, stop: { running = false },
      running: { running }, interrupted: { _ in })
    lifecycle.ensureReady { result in
      XCTAssertFalse(result)
      callback.fulfill()
    }
    lifecycle.queue.async {
      lifecycle.receivedBuffer(
        generation: lifecycle.generation, at: ProcessInfo.processInfo.systemUptime)
      lifecycle.queue.async { queued.signal() }
    }
    // Deliberately hold main in this test until the worker has queued its result.
    XCTAssertEqual(queued.wait(timeout: .now() + 1), .success)
    lifecycle.cancelPendingReadiness()
    await fulfillment(of: [callback], timeout: 1)
    lifecycle.suspend()
  }
}
