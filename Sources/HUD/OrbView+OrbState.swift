import AppKit
import ApplicationServices
import QuartzCore

extension OrbView {
  enum OrbState {
    case listening
    case processing
    case success
    case error
    case locked
  }
}
