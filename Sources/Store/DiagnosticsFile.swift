// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Rolling on-disk diagnostics log (audit F36). The in-memory log in
/// `DictationStore` holds only the last 300 lines for one session; this file
/// keeps a persisted copy so a report can be saved after the app relaunches.
///
/// Not an actor: every access runs on one serial queue instead, so a plain
/// class can be `@unchecked Sendable` without actor-isolation overhead on the
/// hot diagnostic-append path.
final class DiagnosticsFile: @unchecked Sendable {
  /// 4 MB active file, one rolled file kept alongside it: about 8 MB total,
  /// which covers roughly a two-week analysis window on the owner's machine.
  static let defaultRollThreshold = 4 * 1024 * 1024

  private let queue = DispatchQueue(label: "com.adhishthite.tok.diagnostics-file", qos: .utility)
  private let fileURL: URL
  private let rolledURL: URL
  private let rollThreshold: Int
  private let formatter = ISO8601DateFormatter()
  private var handle: FileHandle?
  private var currentSize = 0
  /// Set once a write fails (missing volume, permissions); further writes are
  /// skipped rather than retried, since this file must never throw into the
  /// dictation path.
  private var failed = false

  init(directory: URL, rollThreshold: Int = DiagnosticsFile.defaultRollThreshold) {
    self.fileURL = directory.appendingPathComponent("diagnostics.log")
    self.rolledURL = directory.appendingPathComponent("diagnostics.1.log")
    self.rollThreshold = rollThreshold
  }

  /// Appends one timestamped line. Runs off the caller's thread; failures are
  /// swallowed after being latched so a broken disk cannot spam retries.
  func write(_ line: String) {
    let timestamp = formatter.string(from: Date())
    queue.async { [self] in
      guard !failed else { return }
      if handle == nil { openHandle() }
      guard let handle else {
        failed = true
        return
      }
      guard let data = "\(timestamp) \(line)\n".data(using: .utf8) else { return }
      do {
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        currentSize += data.count
      } catch {
        failed = true
        return
      }
      if currentSize > rollThreshold { roll() }
    }
  }

  /// Syncs the open handle to disk so a save-report immediately after a
  /// write sees everything written so far.
  func flush() {
    queue.sync { try? handle?.synchronize() }
  }

  /// Deletes both files. "Clear log" must clear the persisted copy too, or the control
  /// would promise a privacy action it does not perform.
  func clear() {
    queue.sync {
      try? handle?.close()
      handle = nil
      try? FileManager.default.removeItem(at: fileURL)
      try? FileManager.default.removeItem(at: rolledURL)
      currentSize = 0
      failed = false
    }
  }

  /// Flushes and releases the handle. Safe to call even if never opened.
  func close() {
    queue.sync {
      try? handle?.synchronize()
      try? handle?.close()
      handle = nil
    }
  }

  /// The rolled file's contents followed by the active file's, for a saved
  /// report. Runs on the same serial queue as writes, so it never reads a
  /// file mid-write.
  func reportContents() -> String {
    queue.sync {
      try? handle?.synchronize()
      let rolled = (try? String(contentsOf: rolledURL, encoding: .utf8)) ?? ""
      let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
      return rolled + current
    }
  }

  private func openHandle() {
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      if !FileManager.default.fileExists(atPath: fileURL.path) {
        guard
          FileManager.default.createFile(
            atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { return }
      }
      handle = try FileHandle(forWritingTo: fileURL)
      let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
      currentSize = (attributes[.size] as? Int) ?? 0
    } catch {
      handle = nil
    }
  }

  /// Renames the active file into the rolled slot, replacing any previous
  /// one, then starts a fresh file, so at most about 8 MB is ever kept.
  private func roll() {
    try? handle?.close()
    handle = nil
    try? FileManager.default.removeItem(at: rolledURL)
    try? FileManager.default.moveItem(at: fileURL, to: rolledURL)
    currentSize = 0
    openHandle()
  }
}
