import Foundation
import XCTest

@testable import TokEngine

final class AlgorithmTests: XCTestCase {
  func testConfigurationNormalizesAndClamps() {
    let config = EngineConfiguration.load(values: [
      "PRE_ROLL_MS": "2000", "POST_ROLL_MS": "-1", "CHUNK_MS": "1",
      "TRAIL_SILENCE_DB": "-100", "HOLD_TO_LOCK": "100", "LEARN_DELAY_MS": "1",
      "LANGUAGE_CODES": "en-in,pa-guru-in", "VAD_MODE": "TUNED",
    ])
    XCTAssertEqual(config.preRollMs, 1000)
    XCTAssertEqual(config.postRollMs, 0)
    XCTAssertEqual(config.chunkMs, 20)
    XCTAssertEqual(config.trailSilenceDb, -80)
    XCTAssertEqual(config.holdToLockSec, 60)
    XCTAssertEqual(config.learnDelayMs, 2000)
    XCTAssertEqual(config.languageCodes, ["en-IN", "pa-Guru-IN"])
    XCTAssertEqual(config.vadMode, "tuned")
    XCTAssertTrue(
      EngineConfiguration.load(values: ["LANGUAGE_CODES": "auto"]).languageCodes.isEmpty)
    XCTAssertEqual(EngineConfiguration.load(values: [:]).restFallbackTimeout, 4)
  }

  func testTrailingCaptureFloorDefaultsAndClamps() {
    XCTAssertEqual(EngineConfiguration.load(values: [:]).postRollMinMs, 30)
    XCTAssertEqual(EngineConfiguration.load(values: ["POST_ROLL_MIN_MS": "999"]).postRollMinMs, 250)
    XCTAssertEqual(EngineConfiguration.load(values: ["POST_ROLL_MIN_MS": "-5"]).postRollMinMs, 0)
  }

  func testVocabularyParsingAndCasePreserveCanonicalTerms() {
    let config = EngineConfiguration.load(
      values: [:],
      vocabularyText: """
        # context: Architecture
        cooper netties => Kubernetes
        cloud code => Claude Code
        NPM => npm
        gRPC
        grpc
        => invalid
        """)
    XCTAssertEqual(config.customVocabulary, ["gRPC", "Kubernetes", "Claude Code", "npm"])
    XCTAssertEqual(config.analyzeContext, "Architecture")
    XCTAssertEqual(
      try ReplacementEngine.apply(
        "COOPER NETTIES, cloud code and NPM.", compiled: config.compiledReplacementRules),
      "Kubernetes, Claude Code and npm.")
    XCTAssertEqual(
      try ReplacementEngine.apply("cloud codec", compiled: config.compiledReplacementRules),
      "cloud codec")
  }

  func testWAVHeaderAndPCMByteOrder() {
    let pcm = Data([0x00, 0x80, 0xFF, 0x7F])
    let wav = WAVEncoder.encode(from: pcm)
    XCTAssertEqual(wav.count, 48)
    XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
    XCTAssertEqual(Array(wav[4..<8]), [40, 0, 0, 0])
    XCTAssertEqual(Array(wav[24..<28]), [0x80, 0x3E, 0, 0])
    XCTAssertEqual(Array(wav[40..<44]), [4, 0, 0, 0])
    XCTAssertEqual(wav.suffix(4), pcm)
  }

  func testRESTGateAcceptsDictationAndRejectsModelFraming() {
    for text in ["Sure, sounds good.", "As an AI engineer, I review models.", "मी उद्या येईन."] {
      XCTAssertNil(RestValidationGate.rejectionReason(text), text)
    }
    for text in [
      "Here's the transcription: hello", "As an AI assistant, I cannot help.",
      "The audio says hello.",
    ] {
      XCTAssertNotNil(RestValidationGate.rejectionReason(text), text)
    }
    XCTAssertEqual(RestValidationGate.clean("```text\nTranscript: \"Hello.\"\n```"), "Hello.")
  }
}
