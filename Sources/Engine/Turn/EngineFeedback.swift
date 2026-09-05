import Foundation

final class EngineFeedback {
  weak var delegate: DictationEngineDelegate?

  func ready() { delegate?.engineDidEmit(.ready) }
  func showStarting() { delegate?.engineDidEmit(.starting) }
  func showListening(lockAfter: TimeInterval? = nil) {
    delegate?.engineDidEmit(.listening(lockAfter: lockAfter))
  }
  func showLocked() { delegate?.engineDidEmit(.locked) }
  func showProcessing() { delegate?.engineDidEmit(.processing) }
  func showBusy() { delegate?.engineDidEmit(.busy) }
  func hide() { delegate?.engineDidEmit(.hidden) }
  func micReleased() { delegate?.engineDidEmit(.microphoneReleased) }
  func showError(message: String) { delegate?.engineDidEmit(.failure(message)) }
  func showSuccess(text: String) { delegate?.engineDidEmit(.success(text)) }
  func updateLiveText(_ text: String) { delegate?.engineDidEmit(.liveText(text)) }
  func updateAudioLevel(db: Double) { delegate?.engineDidEmit(.audioLevel(db)) }
  func captureStarted(pid: Int32?, followFocus: Bool) {
    delegate?.engineDidEmit(.captureStarted(pid: pid, followFocus: followFocus))
  }
}
