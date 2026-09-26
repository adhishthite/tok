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

extension GeminiLiveClient {
  struct PendingWrite {
    let id: UInt64
    let text: String
    let admittedAt: Double
    let writes: DispatchGroup
  }
}
