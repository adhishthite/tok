import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

extension ClipboardPreparation {
  struct Snapshot {
    let version: Int
    let contents: Contents
  }
}
