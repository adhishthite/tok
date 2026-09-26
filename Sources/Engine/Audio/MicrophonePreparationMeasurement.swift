// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

public struct MicrophonePreparationMeasurement: Sendable {
  public let milliseconds: Double
  public let engineRunning: Bool
  public let audioUnitStatus: Int32
  public let audioUnitRunning: UInt32
}
