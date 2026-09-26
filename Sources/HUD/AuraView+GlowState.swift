// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import QuartzCore

extension AuraView {
  enum GlowState {
    case idle
    case listening
    case processing
    case success
    case error
  }
}
