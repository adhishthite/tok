// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import TokEngine
import XCTest

@testable import Tok

@MainActor
final class MicrophonePickerTests: XCTestCase {
  private let devices: [InputDeviceCatalog.Device] = [
    .init(
      id: 1, name: "MacBook Pro Microphone", uid: "builtin", transport: "builtin", isDefault: true),
    .init(id: 2, name: "Studio Microphone", uid: "usb-studio", transport: "usb", isDefault: false),
  ]

  func testChoicesPreserveDefaultAutomaticAndUnavailableSelections() {
    let choices = MicrophoneChoice.options(devices: devices, selection: "disconnected-uid")
    XCTAssertEqual(choices.first?.id, "")
    XCTAssertEqual(choices.first?.label, "System Default (MacBook Pro Microphone)")
    XCTAssertTrue(choices.contains { $0.id == "auto" })
    XCTAssertTrue(choices.contains { $0.id == "usb-studio" && $0.label == "Studio Microphone" })
    XCTAssertEqual(choices.last?.id, "disconnected-uid")
    XCTAssertEqual(choices.last?.label, "Unavailable microphone")
    XCTAssertEqual(Set(choices.map(\.id)).count, choices.count)
  }

  func testImportedNameMatchKeepsItsOriginalValue() {
    let choices = MicrophoneChoice.options(devices: devices, selection: "studio")
    XCTAssertEqual(choices.last?.id, "studio")
    XCTAssertEqual(choices.last?.label, "Studio Microphone (saved choice)")
  }

  func testRenderNativeMicrophonePicker() throws {
    let view = NSHostingView(
      rootView:
        Form {
          MicrophonePickerContent(selection: .constant("usb-studio"), devices: devices)
          Text("Choose a microphone or follow your Mac’s sound settings.")
            .font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped).frame(width: 560, height: 160))
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 560, height: 160),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/tok-microphone-picker.png"))
    XCTAssertGreaterThan(bitmap.pixelsWide, 500)
  }
}
