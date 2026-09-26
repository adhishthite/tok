// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns the recovery state machine and hardware calls on one serial queue.
/// Callers receive callbacks on main and never synchronously wait for hardware.
// Mutable state is protected by lock (epoch/health) or confined to queue
// (activeEpoch/controller). Hardware closures run only on queue; client callbacks on main.
final class MicrophoneLifecycle: @unchecked Sendable {
  let queue = DispatchQueue(label: "com.adhishthite.tok.microphone", qos: .userInitiated)
  private let lock = NSLock()
  private var epoch: UInt64 = 0
  private var activeEpoch: UInt64 = 0  // Hardware queue only.
  private var healthyBufferTime: TimeInterval?
  private let rebuild: () -> Bool
  private let stop: () -> Void
  private let running: () -> Bool
  private let interrupted: (String) -> Void
  private lazy var controller = MicRecoveryController(
    rebuild: rebuild,
    stop: { [unowned self] in
      stop()
      publishHealth(nil)
    },
    running: running,
    interrupted: { [unowned self] reason in
      publishHealth(nil)
      let token = activeEpoch
      DispatchQueue.main.async { [weak self] in
        guard let self, self.isCurrent(token) else { return }
        self.interrupted(reason)
      }
    },
    schedule: { [unowned self] delay, action in
      queue.asyncAfter(deadline: .now() + delay, execute: action)
    }
  )

  init(
    rebuild: @escaping () -> Bool, stop: @escaping () -> Void,
    running: @escaping () -> Bool, interrupted: @escaping (String) -> Void
  ) {
    self.rebuild = rebuild
    self.stop = stop
    self.running = running
    self.interrupted = interrupted
  }

  var healthy: Bool {
    lock.lock()
    let time = healthyBufferTime
    lock.unlock()
    return time.map { ProcessInfo.processInfo.systemUptime - $0 < 0.75 } ?? false
  }

  var generation: UInt64 {
    dispatchPrecondition(condition: .onQueue(queue))
    return controller.generation
  }

  private func currentEpoch(invalidate: Bool = false) -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    if invalidate {
      epoch &+= 1
      healthyBufferTime = nil
    }
    return epoch
  }

  private func isCurrent(_ token: UInt64) -> Bool { currentEpoch() == token }

  private func publishHealth(_ time: TimeInterval?) {
    lock.lock()
    if activeEpoch == epoch { healthyBufferTime = time }
    lock.unlock()
  }

  func start() {
    let token = currentEpoch()
    queue.async { [self] in
      guard isCurrent(token) else { return }
      activeEpoch = token
      controller.start()
    }
  }

  func ensureReady(_ completion: @escaping (Bool) -> Void) {
    let token = currentEpoch()
    queue.async { [self] in
      guard isCurrent(token) else {
        DispatchQueue.main.async { completion(false) }
        return
      }
      activeEpoch = token
      controller.ensureReady { [weak self] ready in
        guard let self else { return }
        publishHealth(ready ? controller.lastBuffer : nil)
        DispatchQueue.main.async { [self] in completion(ready && self.isCurrent(token)) }
      }
    }
  }

  func cancelPendingReadiness() {
    _ = currentEpoch(invalidate: true)
    queue.async { [self] in controller.cancelPendingReadiness() }
  }

  func suspend(completion: @escaping () -> Void = {}) {
    let token = currentEpoch(invalidate: true)
    queue.async { [self] in
      activeEpoch = token
      controller.suspend()
      DispatchQueue.main.async { [self] in
        if isCurrent(token) { completion() }
      }
    }
  }

  func configurationChanged() {
    queue.async { [self] in controller.configurationChanged() }
  }

  func receivedBuffer(generation: UInt64, at time: TimeInterval) {
    queue.async { [self] in receivedBufferOnQueue(generation: generation, at: time) }
  }

  /// Buffer-health entry point for callers that already run on `queue`, such as the capture
  /// engine's coalescing delivery. Health must not travel through main: a main-thread stall
  /// would age the buffer past the controller's 0.75 s freshness window and interrupt a live
  /// hold even though audio kept flowing.
  func receivedBufferOnQueue(generation: UInt64, at time: TimeInterval) {
    dispatchPrecondition(condition: .onQueue(queue))
    controller.receivedBuffer(generation: generation, at: time)
    publishHealth(controller.healthy ? controller.lastBuffer : nil)
  }
}
