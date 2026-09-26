// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

/// Measures the room through the default input while nothing plays and no engine holds the
/// microphone. Only levels are computed; no audio is stored.
enum AmbientProbe {
  /// Median frame level in dBFS over `seconds`, or nil when the input cannot start.
  static func medianLevel(seconds: TimeInterval = 3) -> Double? {
    let engine = AVAudioEngine()
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    let lock = NSLock()
    var levels: [Double] = []
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
      var sum: Float = 0
      for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
      let rms = sqrt(sum / Float(buffer.frameLength))
      lock.lock()
      levels.append(20 * log10(Double(max(rms, 1e-9))))
      lock.unlock()
    }
    defer {
      input.removeTap(onBus: 0)
      engine.stop()
    }
    do { try engine.start() } catch { return nil }
    Thread.sleep(forTimeInterval: seconds)
    lock.lock()
    // The first buffers after start carry the input's own settling.
    let sorted = levels.dropFirst(5).sorted()
    lock.unlock()
    return sorted.isEmpty ? nil : sorted[sorted.count / 2]
  }
}
