import Foundation
import Observation
import TokEngine

/// Records opt-in usage metrics to a local queue. This build has no sender:
/// events stay on this Mac until a transport ships in a later release, and
/// the queue is capped so it cannot grow without bound.
@MainActor
@Observable
final class MetricsStore {
  static let installIDKey = "TokMetricsInstallID"
  static let installIDCreatedKey = "TokMetricsInstallIDCreated"
  static let firstLaunchKey = "TokMetricsFirstLaunch"
  static let rotationDays = 90
  static let queueLimit = 500

  private(set) var enabled = false
  private(set) var installID = ""
  private(set) var queuedCount = 0
  private(set) var lastPayload: String?
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let queueURL: URL
  @ObservationIgnored private let now: () -> Date

  init(
    defaults: UserDefaults = .standard, supportDirectory: URL, now: @escaping () -> Date = Date.init
  ) {
    self.defaults = defaults
    self.queueURL = supportDirectory.appendingPathComponent("metrics-queue.jsonl")
    self.now = now
  }

  /// Applies the setting. Turning metrics off deletes anything queued.
  func configure(enabled: Bool) {
    self.enabled = enabled
    guard enabled else {
      deleteQueue()
      return
    }
    if defaults.object(forKey: Self.firstLaunchKey) == nil {
      defaults.set(now(), forKey: Self.firstLaunchKey)
    }
    installID = currentInstallID()
    refreshQueueState()
  }

  var daysSinceInstall: Int {
    guard let first = defaults.object(forKey: Self.firstLaunchKey) as? Date else { return 0 }
    return max(0, Int(now().timeIntervalSince(first) / 86400))
  }

  func envelope() -> MetricEnvelope {
    let os = ProcessInfo.processInfo.operatingSystemVersion
    let info = Bundle.main.infoDictionary ?? [:]
    return MetricEnvelope(
      installID: installID,
      appVersion: info["CFBundleShortVersionString"] as? String ?? "development",
      build: info["CFBundleVersion"] as? String ?? "0",
      osVersion: "\(os.majorVersion).\(os.minorVersion)", arch: Self.architecture, date: now())
  }

  /// Appends one event. Events with keys outside the schema are refused.
  func record(_ event: MetricEvent) {
    guard enabled, event.undocumentedKeys.isEmpty, let data = try? event.json() else { return }
    var lines = queuedLines()
    lines.append(String(decoding: data, as: UTF8.self))
    if lines.count > Self.queueLimit { lines.removeFirst(lines.count - Self.queueLimit) }
    writeQueue(lines)
  }

  func resetInstallID() {
    defaults.removeObject(forKey: Self.installIDKey)
    defaults.removeObject(forKey: Self.installIDCreatedKey)
    deleteQueue()
    if enabled { installID = currentInstallID() }
  }

  func deleteQueue() {
    try? FileManager.default.removeItem(at: queueURL)
    queuedCount = 0
    lastPayload = nil
  }

  var queuedPayloads: [String] { queuedLines() }

  private func currentInstallID() -> String {
    let created = defaults.object(forKey: Self.installIDCreatedKey) as? Date
    let age = created.map { now().timeIntervalSince($0) / 86400 } ?? .infinity
    if let id = defaults.string(forKey: Self.installIDKey), age < Double(Self.rotationDays) {
      return id
    }
    let id = UUID().uuidString.lowercased()
    defaults.set(id, forKey: Self.installIDKey)
    defaults.set(now(), forKey: Self.installIDCreatedKey)
    return id
  }

  private func queuedLines() -> [String] {
    guard let text = try? String(contentsOf: queueURL, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
  }

  private func writeQueue(_ lines: [String]) {
    let text = lines.joined(separator: "\n") + "\n"
    do {
      try FileManager.default.createDirectory(
        at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      try text.write(to: queueURL, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: queueURL.path)
    } catch {
      return
    }
    refreshQueueState()
  }

  private func refreshQueueState() {
    let lines = queuedLines()
    queuedCount = lines.count
    lastPayload = lines.last.flatMap(Self.prettyJSON)
  }

  private static func prettyJSON(_ line: String) -> String? {
    guard let data = line.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data),
      let pretty = try? JSONSerialization.data(
        withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    else { return nil }
    return String(decoding: pretty, as: UTF8.self)
  }

  private static var architecture: String {
    #if arch(arm64)
      "arm64"
    #else
      "x86_64"
    #endif
  }
}
