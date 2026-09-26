// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3
import XCTest

@testable import TokEngine

extension HotkeyManager {
  func fixturePress(_ pressed: Bool) {
    lastStateChangeTime = 0
    updateKeyState(pressed: pressed)
  }
}
