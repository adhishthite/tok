import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

extension DictationEngine {
  enum TurnOutcome {
    case success(
      text: String, transport: String, firstTokenMs: Double, roundtripMs: Double,
      audioDuration: Double, keyUpTime: CFAbsoluteTime, captureFinalizeMs: Double,
      fallbackReason: String?,
      isLiveRoute: Bool, inputTokens: Int?, outputTokens: Int?)
    // The live STT model heard nothing and the clip's energy profile agrees: a real
    // no-speech turn, not an error - nothing is pasted and no fallback is attempted.
    case empty(audioDuration: Double)
    case failure(Error)
  }
}
