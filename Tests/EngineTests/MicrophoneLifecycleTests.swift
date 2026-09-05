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
