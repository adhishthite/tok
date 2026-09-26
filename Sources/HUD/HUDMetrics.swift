// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import QuartzCore

enum HUDMetrics {
  static let minPillWidth: CGFloat = 330
  static let maxPillWidth: CGFloat = 520
  static let pillHeight: CGFloat = 52
  // A deliberate air gap beneath the notch: the aura's light spill needs visible
  // wallpaper between the bezel and the pill to land on.
  static let pillGap: CGFloat = 14.0
  // Host-panel margins: side room for the layer shadow, bottom room for shadow spread
  // plus unfurl's height overshoot.
  static let hostMarginX: CGFloat = 40.0
  static let hostMarginBottom: CGFloat = 44.0

  // The host spans from the screen's TOP edge (the morph membrane must start hidden
  // inside the notch cutout) down past the pill's resting place.
  static func hostSize(notchHeight: CGFloat) -> CGSize {
    CGSize(
      width: maxPillWidth + hostMarginX * 2.0,
      height: notchHeight + pillGap + pillHeight + hostMarginBottom)
  }
}
