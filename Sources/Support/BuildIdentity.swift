// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

enum BuildIdentity {
  static var revision: String {
    Bundle.main.object(forInfoDictionaryKey: "TokSourceRevision") as? String ?? "unversioned"
  }
  /// Marketing version with the build number, which support needs for update reports.
  static var version: String {
    let info = Bundle.main.infoDictionary ?? [:]
    guard let short = info["CFBundleShortVersionString"] as? String else { return "Development" }
    guard let build = info["CFBundleVersion"] as? String, build != short else { return short }
    return "\(short) (\(build))"
  }
  static var copyright: String {
    Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
      ?? "Copyright 2026 Adhish Thite."
  }
  /// One line for support reports: app version, source revision, and macOS version.
  static var report: String {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    return "Tok \(version), revision \(revision), \(os)"
  }
}
