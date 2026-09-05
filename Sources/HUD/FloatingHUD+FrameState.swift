import AppKit
import ApplicationServices
import QuartzCore

extension FloatingHUD {
  struct FrameState: Equatable {
    let presence: CGFloat
    let width: CGFloat
    let bounds: CGRect
    let notchHeight: CGFloat
    let physicalNotch: Bool
    let style: String
    let privacy: Bool
    let reducedMotion: Bool
  }
}
