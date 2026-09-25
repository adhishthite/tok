import AVFoundation
import Foundation

/// Clip audio as the Live socket receives it from the capture engine: 16 kHz mono
/// little-endian Int16, at a microphone-like level, over a low room-tone floor.
enum DirectAudio {
  static let sampleRate = 16_000.0
  /// Peak level for speech. Real turns peak near -21 dBFS (peak_db in history.db).
  static let speechPeakDbfs = -20.0
  /// Room tone under and around the speech. Pure digital silence would make the
  /// server's end-of-speech detection look better than it is on a real microphone.
  static let noiseDbfs = -60.0

  /// The clip resampled to 16 kHz mono and scaled so its peak sits at speechPeakDbfs.
  static func speech(url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let source = file.processingFormat
    guard
      let input = AVAudioPCMBuffer(
        pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length)),
      let target = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
      let converter = AVAudioConverter(from: source, to: target)
    else { throw HarnessError.setup("cannot convert \(url.lastPathComponent)") }
    try file.read(into: input)
    let capacity =
      AVAudioFrameCount(Double(input.frameLength) * sampleRate / source.sampleRate) + 1024
    guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
      throw HarnessError.setup("cannot allocate audio for \(url.lastPathComponent)")
    }
    var supplied = false
    var conversionError: NSError?
    converter.convert(to: output, error: &conversionError) { _, status in
      if supplied {
        status.pointee = .endOfStream
        return nil
      }
      supplied = true
      status.pointee = .haveData
      return input
    }
    if let conversionError { throw conversionError }
    guard let channel = output.floatChannelData?[0] else {
      throw HarnessError.setup("empty audio in \(url.lastPathComponent)")
    }
    let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    let peak = samples.map(abs).max() ?? 0
    guard peak > 0 else { return samples }
    let gain = Float(pow(10, speechPeakDbfs / 20)) / peak
    return samples.map { $0 * gain }
  }

  /// Room tone of the given length, from a seeded generator so runs repeat.
  static func noise(milliseconds: Double, using rng: inout SeededGenerator) -> [Float] {
    let count = Int(milliseconds * sampleRate / 1000)
    // Uniform noise with this amplitude has an RMS of amplitude / sqrt(3).
    let amplitude = Float(pow(10, noiseDbfs / 20) * 3.0.squareRoot())
    return (0..<count).map { _ in Float.random(in: -amplitude...amplitude, using: &rng) }
  }

  /// Adds room tone under speech in place.
  static func addNoise(to samples: inout [Float], using rng: inout SeededGenerator) {
    let amplitude = Float(pow(10, noiseDbfs / 20) * 3.0.squareRoot())
    for index in samples.indices {
      samples[index] += Float.random(in: -amplitude...amplitude, using: &rng)
    }
  }

  static func pcm16(_ samples: [Float]) -> Data {
    var data = Data(capacity: samples.count * 2)
    for sample in samples {
      let value = Int16(max(-1, min(1, sample)) * Float(Int16.max))
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    return data
  }
}
