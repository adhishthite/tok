// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

// The dispatch source is immutable; the file stamp is protected by the lock.
final class VocabularyWatcher: @unchecked Sendable {
  private let source: DispatchSourceFileSystemObject
  private let url: URL
  private let changed: @Sendable () -> Void
  private let lock = NSLock()
  private var stamp: String?

  init?(url: URL, changed: @escaping @Sendable () -> Void) {
    let descriptor = open(url.deletingLastPathComponent().path, O_EVTONLY)
    guard descriptor >= 0 else { return nil }
    self.url = url
    self.changed = changed
    stamp = Self.fileStamp(url)
    source = DispatchSource.makeFileSystemObjectSource(
      fileDescriptor: descriptor,
      eventMask: [.write, .rename, .delete],
      queue: DispatchQueue(label: "com.adhishthite.tok.vocabulary-watch", qos: .utility))
    source.setEventHandler { [weak self] in self?.check() }
    source.setCancelHandler { close(descriptor) }
    source.resume()
  }

  func stop() { source.cancel() }
  deinit { source.cancel() }

  private func check() {
    let current = Self.fileStamp(url)
    lock.lock()
    let different = current != stamp
    stamp = current
    lock.unlock()
    if different { changed() }
  }
  private static func fileStamp(_ url: URL) -> String? {
    guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
      let modified = values[.modificationDate] as? Date,
      let size = values[.size] as? NSNumber
    else { return nil }
    return "\(modified.timeIntervalSince1970):\(size.int64Value)"
  }
}
