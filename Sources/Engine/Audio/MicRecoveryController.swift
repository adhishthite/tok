import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class MicRecoveryController {
  var rebuild: () -> Bool
  var stop: () -> Void
  var running: () -> Bool
  var interrupted: (String) -> Void
  var clock: () -> TimeInterval
  var schedule: (Double, @escaping () -> Void) -> Void
  private(set) var desiredRunning = false
  private(set) var ready = false
  private(set) var generation: UInt64 = 0
  private var attempt = 0
  private var startedAt: TimeInterval = 0
  private var lastBuffer: TimeInterval?
  private var waiting: [(Bool) -> Void] = []
  private var configurationPending = false

  init(
    rebuild: @escaping () -> Bool, stop: @escaping () -> Void,
    running: @escaping () -> Bool, interrupted: @escaping (String) -> Void,
    clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
    schedule: @escaping (Double, @escaping () -> Void) -> Void = { delay, action in
      DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
  ) {
    self.rebuild = rebuild
    self.stop = stop
    self.running = running
    self.interrupted = interrupted
    self.clock = clock
    self.schedule = schedule
  }

  var healthy: Bool {
    ready && running() && lastBuffer.map { clock() - $0 < 0.75 } == true
  }

  @discardableResult func start() -> Bool {
    desiredRunning = true
    attempt = 0
    return restart()
  }

  func ensureReady(_ completion: @escaping (Bool) -> Void) {
    if healthy {
      completion(true)
      return
    }
    waiting.append(completion)
    if !configurationPending && (!desiredRunning || attempt == 0 || attempt >= 3) { _ = start() }
  }

  func cancelPendingReadiness() {
    complete(false)
  }

  func suspend() {
    desiredRunning = false
    ready = false
    attempt = 0
    configurationPending = false
    generation &+= 1
    stop()
    complete(false)
  }

  func configurationChanged() {
    interrupted("Microphone configuration changed")
    guard desiredRunning else {
      stop()
      ready = false
      return
    }
    // Notifications produced during a rebuild share its existing bounded retry budget.
    guard !configurationPending, ready || attempt == 0 else { return }
    if attempt >= 3 {
      generation &+= 1
      ready = false
      stop()
      complete(false)
      return
    }
    ready = false
    configurationPending = true
    let token = generation
    schedule(0.1) { [weak self] in
      guard let self, self.desiredRunning, self.generation == token else { return }
      self.configurationPending = false
      _ = self.restart()
    }
  }

  func receivedBuffer(generation expected: UInt64, at time: TimeInterval) {
    guard desiredRunning, !configurationPending, generation == expected, running(),
      clock() - time < 0.75
    else { return }
    lastBuffer = time
    ready = true
    if clock() - startedAt >= 1 { attempt = 0 }
    complete(true)
  }

  @discardableResult private func restart() -> Bool {
    configurationPending = false
    generation &+= 1
    let token = generation
    ready = false
    lastBuffer = nil
    attempt += 1
    startedAt = clock()
    stop()
    let started = rebuild()
    schedule(0.25) { [weak self] in self?.check(generation: token) }
    return started
  }

  func check(generation expected: UInt64) {
    guard desiredRunning, !configurationPending, generation == expected else { return }
    if healthy {
      if clock() - startedAt >= 1 { attempt = 0 }
      schedule(0.25) { [weak self] in self?.check(generation: expected) }
      return
    }
    if running(), !ready, clock() - startedAt < 0.75 {
      schedule(0.25) { [weak self] in self?.check(generation: expected) }
      return
    }
    interrupted("Microphone stopped delivering audio")
    if attempt < 3 {
      _ = restart()
    } else {
      ready = false
      stop()
      complete(false)
    }
  }

  private func complete(_ success: Bool) {
    let callbacks = waiting
    waiting.removeAll()
    for callback in callbacks { callback(success) }
  }
}
