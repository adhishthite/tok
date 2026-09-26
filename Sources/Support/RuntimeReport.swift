// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

enum RuntimeReport {
  private static let queue = DispatchQueue(
    label: "com.adhishthite.tok.runtime-report", qos: .utility)
  @MainActor static func write(
    status: String, permissions: PermissionStatus, hasAPIKey: Bool, latency: String
  ) {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      guard let flag = arguments.firstIndex(of: "--status-file"),
        arguments.indices.contains(flag + 1)
      else { return }
      let url = URL(fileURLWithPath: arguments[flag + 1])
      let values: [String: Any] = [
        "windows": NSApplication.shared.windows.filter { $0.isVisible }.map { $0.title },
        "pid": ProcessInfo.processInfo.processIdentifier, "status": status,
        "microphone": permissions.microphone,
        "accessibility": permissions.accessibility, "inputMonitoring": permissions.inputMonitoring,
        "hasAPIKey": hasAPIKey, "latency": latency,
        "build": BuildIdentity.revision,
      ]
      guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
      else { return }
      queue.async {
        try? data.write(to: url, options: .atomic)
      }
    #endif
  }
}
