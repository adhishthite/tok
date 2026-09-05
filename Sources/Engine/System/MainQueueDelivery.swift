import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class MainQueueDelivery<Value> {
  let lock = NSLock()
  var latest: Value?
  var scheduled = false
  let consume: (Value) -> Void
  init(_ consume: @escaping (Value) -> Void) { self.consume = consume }
  func submit(_ value: Value) {
    lock.lock()
    latest = value
    let start = !scheduled
    scheduled = true
    lock.unlock()
    guard start else { return }
    DispatchQueue.main.async {
      self.lock.lock()
      let value = self.latest
      self.latest = nil
      self.scheduled = false
      self.lock.unlock()
      if let value = value { self.consume(value) }
    }
  }
}
