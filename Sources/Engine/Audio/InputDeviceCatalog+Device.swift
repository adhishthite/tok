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
  public struct Device: Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let transport: String
    public let isDefault: Bool

    public init(id: AudioDeviceID, name: String, uid: String, transport: String, isDefault: Bool) {
      self.id = id
      self.name = name
      self.uid = uid
      self.transport = transport
      self.isDefault = isDefault
    }

    var label: String { "\(name) [\(transport)]" }
  }
}
