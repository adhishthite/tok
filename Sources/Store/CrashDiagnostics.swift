// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MetricKit

/// Crash and hang diagnostics that macOS delivers through MetricKit, usually at the next
/// launch, kept on disk so a saved diagnostics report can carry them (#13). Nothing here
/// uses the network: the payloads leave the Mac only inside a report the user saves.
///
/// Same pattern as `DiagnosticsFile`: every file operation runs on one serial queue.
final class CrashDiagnostics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
  /// About 10 reports and 2 MB on disk at most; PRIVACY.md states both.
  static let defaultMaxFiles = 10
  static let defaultMaxBytes = 2 * 1024 * 1024

  private let queue = DispatchQueue(label: "com.adhishthite.tok.crash-diagnostics", qos: .utility)
  let directory: URL
  private let maxFiles: Int
  private let maxBytes: Int
  /// Orders files written in the same millisecond. Read and written on `queue` only.
  private var sequence = 0

  init(
    supportDirectory: URL, maxFiles: Int = CrashDiagnostics.defaultMaxFiles,
    maxBytes: Int = CrashDiagnostics.defaultMaxBytes
  ) {
    self.directory = supportDirectory.appendingPathComponent("crash-diagnostics", isDirectory: true)
    self.maxFiles = maxFiles
    self.maxBytes = maxBytes
  }

  /// Main thread only.
  private(set) var isRegistered = false

  /// Once per launch. The subscription lasts for the app run: pausing dictation or losing
  /// a permission must not end crash reporting, and process exit removes it.
  func register() {
    guard !isRegistered else { return }
    MXMetricManager.shared.add(self)
    isRegistered = true
  }

  /// Keeps crash and hang diagnostics only. CPU, disk-write and launch diagnostics, and
  /// the performance metrics payloads, are out of scope.
  func didReceive(_ payloads: [MXDiagnosticPayload]) {
    var entries: [(kind: String, json: Data)] = []
    for payload in payloads {
      entries += (payload.crashDiagnostics ?? []).map { ("crash", $0.jsonRepresentation()) }
      entries += (payload.hangDiagnostics ?? []).map { ("hang", $0.jsonRepresentation()) }
    }
    store(entries)
  }

  /// Writes each entry to its own 0o600 file, then deletes the oldest files until both
  /// bounds hold. An entry larger than the byte bound is skipped, since keeping it would
  /// delete every other report.
  func store(_ entries: [(kind: String, json: Data)]) {
    guard !entries.isEmpty else { return }
    queue.sync {
      let manager = FileManager.default
      guard
        (try? manager.createDirectory(
          at: directory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])) != nil
      else { return }
      let stamp = String(format: "%013.0f", Date().timeIntervalSince1970 * 1000)
      for entry in entries where entry.json.count <= maxBytes {
        sequence += 1
        let name = "\(stamp)-\(String(format: "%06d", sequence))-\(entry.kind).json"
        manager.createFile(
          atPath: directory.appendingPathComponent(name).path, contents: entry.json,
          attributes: [.posixPermissions: 0o600])
      }
      trim()
    }
  }

  /// A report section with every stored diagnostic, oldest first, or an empty string when
  /// there are none, so a report without crashes reads as it did before.
  func reportSection() -> String {
    queue.sync {
      let files = storedFiles()
      guard !files.isEmpty else { return "" }
      var section = "\nCrash and hang diagnostics (MetricKit, unsymbolicated):\n"
      for file in files {
        let json = (try? String(contentsOf: file.url, encoding: .utf8)) ?? ""
        section += "--- \(file.url.lastPathComponent)\n\(json)\n"
      }
      return section
    }
  }

  /// Deletes every stored diagnostic. Part of "Clear log", like `DiagnosticsFile.clear()`.
  func clear() {
    queue.sync { _ = try? FileManager.default.removeItem(at: directory) }
  }

  private func trim() {
    var files = storedFiles()
    var total = files.reduce(0) { $0 + $1.size }
    while !files.isEmpty, files.count > maxFiles || total > maxBytes {
      let oldest = files.removeFirst()
      try? FileManager.default.removeItem(at: oldest.url)
      total -= oldest.size
    }
  }

  /// Stored files, oldest first: names start with a fixed-width millisecond timestamp and
  /// sequence number, so name order is write order.
  private func storedFiles() -> [(url: URL, size: Int)] {
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return
      urls
      .filter { $0.pathExtension == "json" }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { ($0, (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
  }
}
