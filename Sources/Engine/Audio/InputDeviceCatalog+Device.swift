import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

extension InputDeviceCatalog {
  struct Device {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transport: String
    let isDefault: Bool

    var label: String { "\(name) [\(transport)]" }
  }
}
