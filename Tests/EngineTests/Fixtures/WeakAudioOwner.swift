@testable import TokEngine

@MainActor
final class WeakAudioOwner: Sendable {
  weak var value: AudioCaptureEngine?
}
