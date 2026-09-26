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

extension CorrectionWatcher {
  struct Pair {
    let wrong: String
    let right: String
  }

  // A candidate correction before the genuineness gate (item 1): the changed word pair plus
  // the surrounding window sentences, which a Jev genuineness judgment needs for context.
  struct Candidate {
    let wrong: String
    let right: String
    let pastedWindow: String
    let editedWindow: String
  }
}
