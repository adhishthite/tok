// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import QuartzCore

extension OrbView {
  enum OrbState {
    case listening
    case processing
    case success
    case error
    case locked
  }
}
