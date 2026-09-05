import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

extension TextInjector {
  enum Outcome { case dispatched, clipboardUnavailable, dispatchCancelled, failed }
}
