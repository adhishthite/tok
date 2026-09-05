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
}
