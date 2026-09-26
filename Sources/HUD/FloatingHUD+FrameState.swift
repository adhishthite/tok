// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import AppKit
import ApplicationServices
import QuartzCore

extension FloatingHUD {
  struct FrameState: Equatable {
    let presence: CGFloat
    let width: CGFloat
    let bounds: CGRect
    let notchHeight: CGFloat
    let physicalNotch: Bool
    let style: String
    let privacy: Bool
    let reducedMotion: Bool
  }
}
