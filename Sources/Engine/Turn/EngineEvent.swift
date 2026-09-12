import Foundation

public enum EngineEvent: Sendable {
  case ready
  case starting
  case listening(lockAfter: TimeInterval?)
  case locked
  case processing
  case busy
  case hidden
  case microphoneReleased
  case failure(String)
  case success(String)
  // The user stopped the turn (Escape, a chord-free second press). Nothing was pasted and
  // nothing failed, so it is neither success nor failure.
  case cancelled
  case liveText(String)
  case audioLevel(Double)
  case captureStarted(pid: Int32?, followFocus: Bool)
  case turnSettled(TurnRecord)
  case diagnostic(String)
  // A history write failed or recovered (nil). Surfaced in Settings, unlike a log line.
  case historyError(String?)
  // Progress inside a long finish, shown as the processing header: "Still working",
  // "Using backup route" (audit F09) and the limit notices (audit F06). Only meaningful
  // between `processing` and the turn's success or failure.
  case processingStatus(String)
}
