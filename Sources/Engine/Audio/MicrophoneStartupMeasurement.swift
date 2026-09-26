// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct MicrophoneStartupMeasurement: Sendable {
  public let readinessMilliseconds: Double
  public let synchronousSetupMilliseconds: Double
}
