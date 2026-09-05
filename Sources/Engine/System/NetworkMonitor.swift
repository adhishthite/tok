import AVFoundation
import AppKit
import AudioToolbox
import Carbon
import CoreAudio
import Foundation
import IOKit
import Network
import SQLite3

final class NetworkMonitor {
  static let shared = NetworkMonitor()

  private let monitor = NWPathMonitor()
  let queue = DispatchQueue(label: "com.adhishthite.tok.netpath", qos: .utility)
  let lock = NSLock()
  // Optimistic until the first path update lands - a slow monitor must never block a
  // dictation on a healthy network.
  private var online = true

  var isOnline: Bool {
    lock.lock()
    let value = online
    lock.unlock()
    return value
  }

  func start() {
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self = self else { return }
      let nowOnline = (path.status == .satisfied)
      self.lock.lock()
      let wasOnline = self.online
      self.online = nowOnline
      self.lock.unlock()
      guard wasOnline != nowOnline else { return }
      if nowOnline {
        Log.success("NET", "Internet connection restored.")
      } else {
        Log.warn("NET", "Internet connection lost - dictation will refuse until it returns.")
      }
    }
    monitor.start(queue: queue)
  }
}
