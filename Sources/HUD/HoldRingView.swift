import AppKit
import ApplicationServices
import QuartzCore

final class HoldRingView: NSView {
  override func makeBackingLayer() -> CALayer {
    let shape = CAShapeLayer()
    shape.fillColor = nil
    shape.lineCap = .round
    shape.strokeEnd = 0.0
    shape.opacity = 0.0
    shape.shadowOffset = .zero
    shape.shadowRadius = 4.0
    shape.shadowOpacity = 0.85
    shape.actions = [
      "path": NSNull(), "strokeEnd": NSNull(), "opacity": NSNull(), "lineWidth": NSNull(),
      "strokeColor": NSNull(), "shadowColor": NSNull(), "bounds": NSNull(), "position": NSNull(),
    ]
    return shape
  }

  private var shape: CAShapeLayer? { layer as? CAShapeLayer }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
  }

  var path: CGPath? {
    didSet { shape?.path = path }
  }
  var progress: CGFloat = 0.0 {
    didSet { shape?.strokeEnd = progress }
  }
  var lineWidth: CGFloat = 2.5 {
    didSet { shape?.lineWidth = lineWidth }
  }
  var strength: Float = 0.0 {
    didSet { shape?.opacity = strength }
  }
  var color: CGColor = NSColor.white.cgColor {
    didSet {
      shape?.strokeColor = color
      shape?.shadowColor = color
    }
  }
}
