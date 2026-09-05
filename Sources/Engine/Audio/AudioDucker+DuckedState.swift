import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

extension AudioDucker {
  struct DuckedState {
    let deviceID: AudioDeviceID
    let levels: [ElementLevel]
  }
}
