import Foundation
import TokEngine

/// One line of build/harness/runs/<run>.jsonl: what the harness did (clip, gap, timing)
/// next to what the engine recorded. Transcript text is synthetic, from phrases.json.
struct HarnessTurnRow: Encodable {
  let runId: String
  let startedAt: String
  let round: Int
  let arm: String
  let turnIndex: Int
  let turnInBlock: Int
  let clipId: String
  let phraseId: String
  let ttsModel: String
  let voice: String
  let accent: String
  let style: String
  let language: String
  let codeSwitch: Bool
  let clipSpeechS: Double
  let plannedGapS: Double
  let actualGapS: Double
  let leadMs: Double
  let tailMs: Double
  let captureStarted: Bool
  var failures: [String]
  let keepMicWarm: Bool
  let micIdleTimeoutS: Int
  let endpointAligned: Bool
  let silenceFlushMs: Int
  /// Median room level before this arm block, with nothing playing.
  let ambientDb: Double?

  /// "acoustic": speakers into the microphone through the full engine. "direct": audio
  /// streamed straight into the Live client, so no capture fields and no total_ms.
  var mode = "acoustic"
  var outcome: String?
  var totalMs: Double?
  var roundtripMs: Double?
  var captureStartMs: Double?
  var captureFinalizeMs: Double?
  var injectMs: Double?
  var micStateAtKeydown: String?
  var msSincePrevCapture: Double?
  var socketStateAtKeydown: String?
  var settlePath: String?
  var finalizeExit: String?
  var quietResets: Int?
  var trailWaitMs: Double?
  var hedgeFired: Bool?
  var hedgeWinner: String?
  var commitToFinalMs: Double?
  var commitToTurnCompleteMs: Double?
  var reference: String
  var hypothesis: String?
  var accuracy: WordAccuracy?

  mutating func apply(_ record: TurnRecord) {
    outcome = record.outcome
    totalMs = record.totalMs
    roundtripMs = record.roundtripMs
    captureStartMs = record.captureStartMs
    captureFinalizeMs = record.captureFinalizeMs
    injectMs = record.injectMs
    micStateAtKeydown = record.micStateAtKeydown
    msSincePrevCapture = record.msSincePrevCapture
    socketStateAtKeydown = record.socketStateAtKeydown
    settlePath = record.settlePath
    finalizeExit = record.finalizeExit
    quietResets = record.quietResets
    trailWaitMs = record.trailWaitMs
    hedgeFired = record.hedgeFired
    hedgeWinner = record.hedgeWinner
    commitToFinalMs = record.commitToFinalMs
    commitToTurnCompleteMs = record.commitToTurnCompleteMs
    hypothesis = record.text
    accuracy = WordAccuracy(reference: reference, hypothesis: record.text ?? "")
  }
}
