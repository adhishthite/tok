import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class CancellableRequest {
  let lock = NSLock()
  var cancelled = false
  private var task: URLSessionTask?
  var retry: DispatchWorkItem?
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }

  func start(_ task: URLSessionTask) {
    lock.lock()
    let stop = cancelled
    if !stop { self.task = task }
    lock.unlock()
    if stop { task.cancel() } else { task.resume() }
  }

  func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
    let item = DispatchWorkItem { [weak self] in
      guard let self = self else { return }
      self.lock.lock()
      let stop = self.cancelled
      self.retry = nil
      self.lock.unlock()
      if !stop { work() }
    }
    lock.lock()
    let stop = cancelled
    if !stop { retry = item }
    lock.unlock()
    if !stop { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: item) }
  }

  func completedTask() {
    lock.lock()
    task = nil
    lock.unlock()
  }

  func cancel() {
    lock.lock()
    cancelled = true
    let task = self.task
    let retry = self.retry
    self.task = nil
    self.retry = nil
    lock.unlock()
    retry?.cancel()
    task?.cancel()
  }
}
