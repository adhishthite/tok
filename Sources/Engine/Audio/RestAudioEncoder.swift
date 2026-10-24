// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioToolbox
import Foundation

/// Encodes a turn's 16 kHz Int16 mono PCM for the REST route (#16). FLAC is lossless, so it
/// cannot change what the model hears, and it shrinks the upload on the slow links where
/// REST stands in for the live route. Encoding stays in memory: speech never touches disk.
enum RestAudioEncoder {
  static let sampleRate = 16_000.0

  /// FLAC when it encodes and comes out smaller than WAV, otherwise WAV. WAV is the upper
  /// bound GeminiRestClient sizes turns against, so the fallback always fits. Tests pass a
  /// failing `flacEncoder` to reach the fallback.
  static func encode(
    pcm: Data, flacEncoder: (Data) throws -> Data = { try RestAudioEncoder.flac(pcm: $0) }
  ) -> (data: Data, mimeType: String) {
    let wav = {
      (data: WAVEncoder.encode(from: pcm, sampleRate: 16000, channels: 1), mimeType: "audio/wav")
    }
    do {
      let flac = try flacEncoder(pcm)
      return flac.count < pcm.count + 44 ? (flac, "audio/flac") : wav()
    } catch {
      reportFailureOnce(error)
      return wav()
    }
  }

  /// A FLAC file in memory: AVAudioConverter makes the FLAC packets, and AudioFile writes
  /// them with the converter's stream info through callbacks into `buffer`.
  static func flac(pcm: Data) throws -> Data {
    var description = AudioStreamBasicDescription(
      mSampleRate: sampleRate, mFormatID: kAudioFormatFLAC,
      mFormatFlags: kAppleLosslessFormatFlag_16BitSourceData, mBytesPerPacket: 0,
      mFramesPerPacket: 0, mBytesPerFrame: 0, mChannelsPerFrame: 1, mBitsPerChannel: 0,
      mReserved: 0)
    var descriptionSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try check(
      AudioFormatGetProperty(
        kAudioFormatProperty_FormatInfo, 0, nil, &descriptionSize, &description),
      "format info")
    guard
      let pcmFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true),
      let flacFormat = AVAudioFormat(streamDescription: &description),
      let converter = AVAudioConverter(from: pcmFormat, to: flacFormat),
      let input = AVAudioPCMBuffer(
        pcmFormat: pcmFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
      let samples = input.int16ChannelData
    else { throw encoderError("setup", kAudioFileUnspecifiedError) }
    input.frameLength = input.frameCapacity
    pcm.withUnsafeBytes { raw in
      if let base = raw.baseAddress { memcpy(samples[0], base, Int(input.frameLength) * 2) }
    }

    let buffer = NSMutableData()
    var fileID: AudioFileID?
    try check(
      AudioFileInitializeWithCallbacks(
        Unmanaged.passUnretained(buffer).toOpaque(), readCallback, writeCallback,
        sizeCallback, setSizeCallback, kAudioFileFLACType, &description, [], &fileID),
      "open")
    guard let fileID else { throw encoderError("open", kAudioFileUnspecifiedError) }
    var closed = false
    defer { if !closed { AudioFileClose(fileID) } }

    let output = AVAudioCompressedBuffer(
      format: flacFormat, packetCapacity: 16,
      maximumPacketSize: converter.maximumOutputPacketSize)
    var supplied = false
    var cookieWritten = false
    var packetIndex: Int64 = 0
    while true {
      var conversionError: NSError?
      let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
        if supplied || input.frameLength == 0 {
          inputStatus.pointee = .endOfStream
          return nil
        }
        supplied = true
        inputStatus.pointee = .haveData
        return input
      }
      if status == .error {
        throw conversionError ?? encoderError("convert", kAudioFileUnspecifiedError)
      }
      if !cookieWritten {
        try writeStreamInfo(converter, to: fileID)
        cookieWritten = true
      }
      if output.packetCount > 0 {
        var packets = UInt32(output.packetCount)
        try check(
          AudioFileWritePackets(
            fileID, false, output.byteLength, output.packetDescriptions, packetIndex, &packets,
            output.data),
          "write")
        packetIndex += Int64(packets)
      }
      if status == .endOfStream { break }
    }
    // The stream info written before encoding has no sample count or frame sizes, and a
    // decoder then reads the file as empty. Write the final one, and trim the last
    // packet's padding with the packet table.
    try writeStreamInfo(converter, to: fileID)
    let framesPerPacket = Int64(description.mFramesPerPacket)
    let validFrames = Int64(input.frameLength)
    var table = AudioFilePacketTableInfo(
      mNumberValidFrames: validFrames, mPrimingFrames: 0,
      mRemainderFrames: Int32(max(0, packetIndex * framesPerPacket - validFrames)))
    try check(
      AudioFileSetProperty(
        fileID, kAudioFilePropertyPacketTableInfo,
        UInt32(MemoryLayout<AudioFilePacketTableInfo>.size), &table),
      "packet table")
    // Close writes the final headers; its status matters too.
    closed = true
    try check(AudioFileClose(fileID), "finish")
    return buffer as Data
  }

  private static func writeStreamInfo(_ converter: AVAudioConverter, to fileID: AudioFileID) throws
  {
    guard let cookie = converter.magicCookie else { return }
    var bytes = [UInt8](cookie)
    try check(
      AudioFileSetProperty(fileID, kAudioFilePropertyMagicCookieData, UInt32(bytes.count), &bytes),
      "stream info")
  }

  private nonisolated(unsafe) static var failureReported = false
  private static let failureLock = NSLock()

  /// One warning per launch: a broken encoder would otherwise log on every REST turn.
  private static func reportFailureOnce(_ error: Error) {
    failureLock.lock()
    let first = !failureReported
    failureReported = true
    failureLock.unlock()
    if first {
      Log.warn("REST", "FLAC encode failed (\(error)); sending WAV for this launch's REST turns.")
    }
  }

  private static func check(_ status: OSStatus, _ step: String) throws {
    if status != noErr { throw encoderError(step, status) }
  }

  private static func encoderError(_ step: String, _ status: OSStatus) -> NSError {
    NSError(
      domain: "Tok.RestAudioEncoder", code: Int(status),
      userInfo: [NSLocalizedDescriptionKey: "FLAC \(step) failed (\(status))"])
  }

  private static func data(_ context: UnsafeMutableRawPointer) -> NSMutableData {
    Unmanaged<NSMutableData>.fromOpaque(context).takeUnretainedValue()
  }

  private static let readCallback: AudioFile_ReadProc = { context, position, count, out, actual in
    let buffer = data(context)
    let start = min(Int(position), buffer.length)
    let length = min(Int(count), buffer.length - start)
    if length > 0 { memcpy(out, buffer.bytes + start, length) }
    actual.pointee = UInt32(max(0, length))
    return noErr
  }

  private static let writeCallback: AudioFile_WriteProc = {
    context, position, count, input, actual in
    let buffer = data(context)
    let end = Int(position) + Int(count)
    if end > buffer.length { buffer.length = end }
    buffer.replaceBytes(in: NSRange(location: Int(position), length: Int(count)), withBytes: input)
    actual.pointee = count
    return noErr
  }

  private static let sizeCallback: AudioFile_GetSizeProc = { context in
    Int64(data(context).length)
  }

  private static let setSizeCallback: AudioFile_SetSizeProc = { context, size in
    data(context).length = Int(size)
    return noErr
  }
}
