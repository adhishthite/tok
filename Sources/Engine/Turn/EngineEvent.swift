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
  case liveText(String)
  case audioLevel(Double)
  case captureStarted(pid: Int32?, followFocus: Bool)
  case turnSettled(TurnRecord)
  case diagnostic(String)
  // A history write failed or recovered (nil). Surfaced in Settings, unlike a log line.
  case historyError(String?)
}
