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

final class LiveWriteProbe {
  let lock = NSLock()
  var messages: [String] = []
  var completions: [(Error?) -> Void] = []
  func accept(_ text: String, _ completion: @escaping (Error?) -> Void) {
    lock.lock()
    messages.append(text)
    completions.append(completion)
    lock.unlock()
  }
  func finish(_ index: Int, error: Error? = nil) {
    lock.lock()
    let callback = completions[index]
    lock.unlock()
    callback(error)
  }
  var sent: [String] {
    lock.lock()
    defer { lock.unlock() }
    return messages
  }
}
