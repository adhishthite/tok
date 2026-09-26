// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit

// Tok's original vector artwork. Run `make icon` to regenerate the macOS asset set.
@MainActor
func drawIcon(pixels: Int) throws -> Data {
  guard
    let bitmap = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
  else { throw CocoaError(.coderInvalidValue) }
  NSGraphicsContext.saveGraphicsState()
  defer { NSGraphicsContext.restoreGraphicsState() }
  NSGraphicsContext.current = context
  context.imageInterpolation = .high
  context.cgContext.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))
  context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)

  let tile = NSBezierPath(
    roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
    xRadius: 184, yRadius: 184)
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
  shadow.shadowBlurRadius = 24
  shadow.shadowOffset = NSSize(width: 0, height: -14)
  shadow.set()
  NSColor(srgbRed: 0.18, green: 0.38, blue: 0.82, alpha: 1).setFill()
  tile.fill()
  NSGraphicsContext.restoreGraphicsState()

  let blue = NSGradient(
    starting: NSColor(srgbRed: 0.31, green: 0.62, blue: 1, alpha: 1),
    ending: NSColor(srgbRed: 0.15, green: 0.31, blue: 0.78, alpha: 1))!
  blue.draw(in: tile, angle: -90)
  NSColor.white.withAlphaComponent(0.22).setStroke()
  tile.lineWidth = 2
  tile.stroke()

  // Three bars at the smallest size avoid subpixel gaps. Larger sizes use five.
  let heights: [CGFloat] = pixels <= 16 ? [230, 430, 230] : [130, 280, 430, 280, 130]
  let width: CGFloat = pixels <= 16 ? 100 : 72
  let gap: CGFloat = pixels <= 16 ? 48 : 40
  let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
  NSGraphicsContext.saveGraphicsState()
  let markShadow = NSShadow()
  markShadow.shadowColor = NSColor(srgbRed: 0.03, green: 0.16, blue: 0.48, alpha: 0.20)
  markShadow.shadowOffset = NSSize(width: 0, height: -5)
  markShadow.shadowBlurRadius = 8
  markShadow.set()
  NSColor.white.setFill()
  for (index, height) in heights.enumerated() {
    NSBezierPath(
      roundedRect: NSRect(
        x: (1024 - total) / 2 + CGFloat(index) * (width + gap),
        y: 520 - height / 2, width: width, height: height),
      xRadius: width / 2, yRadius: width / 2
    ).fill()
  }
  NSGraphicsContext.restoreGraphicsState()
  guard let png = bitmap.representation(using: .png, properties: [:]) else {
    throw CocoaError(.coderInvalidValue)
  }
  return png
}

let output = URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
  for scale in [1, 2] {
    let filename = "icon_\(points)x\(points)@\(scale)x.png"
    let png = try MainActor.assumeIsolated { try drawIcon(pixels: points * scale) }
    try png.write(to: output.appendingPathComponent(filename))
    images.append([
      "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": filename,
    ])
  }
}
let manifest: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
  .write(to: output.appendingPathComponent("Contents.json"))
print("Generated all 10 macOS AppIcon representations.")
