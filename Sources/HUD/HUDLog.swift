// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import os

enum HUDLog {
  private static let logger = os.Logger(subsystem: "com.adhishthite.tok", category: "hud")
  static func info(_ category: String, _ message: String) {
    logger.debug("\(message, privacy: .private)")
  }
}
