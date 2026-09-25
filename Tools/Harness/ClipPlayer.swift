import AVFoundation
import Foundation

/// Plays clips through one output engine that runs for the whole harness run, so the
/// speakers never pay a cold start and every clip is placed on the host clock. All clips
/// must share one sample rate and channel count (Scripts/harness_clips.py writes them so).
final class ClipPlayer {
  private let engine = AVAudioEngine()
  private let node = AVAudioPlayerNode()
  private let format: AVAudioFormat

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
  /// Output latency is subtracted from the render time, so `instant` is acoustic.
  func play(url: URL, at instant: TimeInterval) throws {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat == format else {
      throw HarnessError.setup("\(url.lastPathComponent) does not match the clip bank format")
    }
    let latency = engine.outputNode.presentationLatency
    let renderAt = AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: instant - latency))
    node.scheduleFile(file, at: renderAt)
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
