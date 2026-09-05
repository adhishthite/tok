import AppKit
import ApplicationServices
import QuartzCore

final class HUDPanel: NSPanel {
  override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
    frameRect
  }
}
