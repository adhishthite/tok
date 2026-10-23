// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest

@testable import TokEngine

/// Guards the Live input contract: raw 16 kHz 16-bit PCM, base64 in a JSON
/// envelope (decision record: adhishthite/tok#17). A format change shows up here.
final class LiveAudioFrameTests: XCTestCase {
  func testFrameCarriesRawPCMWithTheDocumentedMimeType() throws {
    let pcm = Data((0..<3200).map { UInt8($0 % 251) })
    let frame = GeminiLiveClient.audioChunkFrame(pcm)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])
    let realtime = try XCTUnwrap(object["realtimeInput"] as? [String: Any])
    let audio = try XCTUnwrap(realtime["audio"] as? [String: String])
    XCTAssertEqual(audio["mimeType"], "audio/pcm;rate=16000")
    XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(audio["data"])), pcm)
  }

  func testTenSecondsAtDefaultChunkSizeKeepsTheCurrentByteBudget() {
    let chunkBytes = 16_000 * 2 * EngineConfiguration().chunkMs / 1000
    XCTAssertEqual(chunkBytes, 3200)
    let frameBytes = GeminiLiveClient.audioChunkFrame(Data(count: chunkBytes)).utf8.count
    // 69-byte prefix + 4,268 bytes of base64 + 4-byte suffix, 100 frames per 10 s.
    XCTAssertEqual(frameBytes * 100, 434_100)
  }
}
