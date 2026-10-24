// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import XCTest

@testable import TokEngine

/// Covers #16: the REST payload is lossless FLAC, smaller than WAV, and falls back to WAV.
final class RestAudioEncoderTests: XCTestCase {
  /// Ten seconds of a voiced-like signal: two harmonics under a slow envelope plus low
  /// deterministic noise, so it compresses like speech rather than like silence.
  private func speechLikePCM(seconds: Double = 10) -> Data {
    let count = Int(seconds * 16_000)
    var generator = UInt32(7)
    var samples = [Int16](repeating: 0, count: count)
    for index in 0..<count {
      let time = Double(index) / 16_000
      let envelope = 0.5 + 0.5 * sin(2 * .pi * 3 * time)
      let voice = sin(2 * .pi * 180 * time) + 0.4 * sin(2 * .pi * 360 * time)
      generator = generator &* 1_664_525 &+ 1_013_904_223
      let noise = Double(Int(generator >> 24) - 128)
      samples[index] = Int16(clamping: Int(6000 * envelope * voice + noise))
    }
    return samples.withUnsafeBytes { Data($0) }
  }

  private func decode(_ data: Data) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "\(UUID().uuidString).flac")
    try data.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    let file = try AVAudioFile(
      forReading: url, commonFormat: .pcmFormatInt16, interleaved: true)
    XCTAssertEqual(file.fileFormat.sampleRate, 16_000)
    XCTAssertEqual(file.fileFormat.channelCount, 1)
    let buffer = try XCTUnwrap(
      AVAudioPCMBuffer(
        pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = try XCTUnwrap(buffer.int16ChannelData)
    return Data(bytes: samples[0], count: Int(buffer.frameLength) * 2)
  }

  func testSpeechEncodesAsSmallerLosslessFLAC() throws {
    let pcm = speechLikePCM()
    let audio = RestAudioEncoder.encode(pcm: pcm)
    XCTAssertEqual(audio.mimeType, "audio/flac")
    XCTAssertLessThan(audio.data.count, pcm.count + 44)
    XCTAssertEqual(audio.data.prefix(4), Data("fLaC".utf8))
    XCTAssertEqual(try decode(audio.data), pcm, "FLAC must round-trip sample-exact")
  }

  func testEncoderFailureFallsBackToWAV() {
    let pcm = speechLikePCM(seconds: 1)
    let audio = RestAudioEncoder.encode(pcm: pcm) { _ in
      throw NSError(domain: "fixture", code: -50)
    }
    XCTAssertEqual(audio.mimeType, "audio/wav")
    XCTAssertEqual(audio.data, WAVEncoder.encode(from: pcm, sampleRate: 16000, channels: 1))
  }

  func testIncompressibleAudioStaysWAVSoItNeverExceedsTheWAVBound() {
    var generator = UInt64(11)
    let samples = (0..<32_000).map { _ -> Int16 in
      generator = generator &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int16(truncatingIfNeeded: generator >> 48)
    }
    let pcm = samples.withUnsafeBytes { Data($0) }
    let audio = RestAudioEncoder.encode(pcm: pcm)
    XCTAssertEqual(audio.mimeType, "audio/wav")
    XCTAssertEqual(audio.data.count, pcm.count + 44)
  }

  func testRequestPartCarriesTheEncoderMimeTypeAndBytes() throws {
    let audio = RestAudioEncoder.encode(pcm: speechLikePCM(seconds: 1))
    let part = GeminiRestClient.audioPart(audio)
    let json = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: Data(part.utf8)) as? [String: [String: String]])
    XCTAssertEqual(json["inlineData"]?["mimeType"], "audio/flac")
    XCTAssertEqual(Data(base64Encoded: json["inlineData"]?["data"] ?? ""), audio.data)
  }
}
