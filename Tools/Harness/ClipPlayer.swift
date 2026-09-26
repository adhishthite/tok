// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Plays clips through one output engine that runs for the whole harness run, so the
/// speakers never pay a cold start and every clip is placed on the host clock. All clips
/// must share one sample rate and channel count (Scripts/harness_clips.py writes them so).
final class ClipPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format: AVAudioFormat
  private let doneLock = NSLock()
  private let done = DispatchSemaphore(value: 0)
  private var playedBackAt: TimeInterval?

  init(format: AVAudioFormat) throws {
    self.format = format
    engine.attach(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
    try engine.start()
    node.play()
  }

  static func format(of url: URL) throws -> AVAudioFormat {
    try AVAudioFile(forReading: url).processingFormat
  }

  /// Seconds on the host clock (mach_absolute_time), the clock `play` schedules against.
  static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }

  /// Schedules a clip so its first sample leaves the speaker at `instant` (host seconds).
  /// Output latency is subtracted from the render time, so `instant` is acoustic. Returns
  /// the instant the clip should finish if the output keeps time.
  @discardableResult
  func play(url: URL, at instant: TimeInterval) throws -> TimeInterval {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat == format else {
      throw HarnessError.setup("\(url.lastPathComponent) does not match the clip bank format")
    }
    doneLock.lock()
    playedBackAt = nil
    doneLock.unlock()
    while done.wait(timeout: .now()) == .success {}
    let latency = engine.outputNode.presentationLatency
    let renderAt = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: instant - latency))
    node.scheduleFile(file, at: renderAt, completionCallbackType: .dataPlayedBack) {
      [weak self] _ in
      guard let self else { return }
      self.doneLock.lock()
      if self.playedBackAt == nil { self.playedBackAt = Self.now }
      self.doneLock.unlock()
      self.done.signal()
    }
    return instant + Double(file.length) / file.processingFormat.sampleRate
  }

  /// When the current clip actually finished leaving the speaker, waiting up to
  /// `timeout` for it. Nil when it is still playing after the wait.
  func playedBack(timeout: TimeInterval) -> TimeInterval? {
    doneLock.lock()
    if let playedBackAt {
      doneLock.unlock()
      return playedBackAt
    }
    doneLock.unlock()
    guard done.wait(timeout: .now() + timeout) == .success else { return nil }
    doneLock.lock()
    defer { doneLock.unlock() }
    return playedBackAt
  }

  func stopClip() {
    node.stop()
    node.play()
  }

  func shutdown() {
    node.stop()
    engine.stop()
  }
}
