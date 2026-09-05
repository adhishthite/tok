import AppKit
import ApplicationServices
import QuartzCore

extension AuraView {
  enum GlowState {
    case idle
    case listening
    case processing
    case success
    case error
  }
}
