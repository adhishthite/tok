import Foundation

/// The per-Mac facts attached to every event. Built by the app, never by the engine.
public struct MetricEnvelope: Sendable {
  public var installID: String
  public var appVersion: String
  public var build: String
  public var osVersion: String
  public var arch: String
  public var date: Date
  public init(
    installID: String, appVersion: String, build: String, osVersion: String, arch: String,
    date: Date = Date()
  ) {
    self.installID = installID
    self.appVersion = appVersion
    self.build = build
    self.osVersion = osVersion
    self.arch = arch
    self.date = date
  }
  var fields: [String: MetricValue] {
    var formatter = Date.ISO8601FormatStyle(timeZone: .gmt)
    formatter = formatter.year().month().day().dateSeparator(.dash).dateTimeSeparator(.standard)
      .time(includingFractionalSeconds: false)
    let hour = String(date.formatted(formatter).prefix(13))
    return [
      "schema": .int(MetricsSchema.version), "install_id": .string(installID),
      "hour": .string(hour), "app_version": .string(appVersion), "build": .string(build),
      "os_version": .string(osVersion), "arch": .string(arch),
    ]
  }
}
