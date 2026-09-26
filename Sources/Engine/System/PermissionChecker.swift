// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import ApplicationServices

enum PermissionChecker {
  static func verifyAll() -> (accessibility: Bool, microphone: Bool) {
    (AXIsProcessTrusted(), AVCaptureDevice.authorizationStatus(for: .audio) == .authorized)
  }
}
