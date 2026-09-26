// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One experimental condition: a name and the settings it changes from the owner's
/// configuration. Each arm changes one factor against `baseline`.
struct HarnessArm {
  let name: String
  let overrides: [String: String]

  static let catalog: [HarnessArm] = [
    HarnessArm(name: "baseline", overrides: [:]),
    HarnessArm(
      name: "warm90", overrides: ["KEEP_MICROPHONE_WARM": "true", "MIC_IDLE_TIMEOUT": "90"]),
    HarnessArm(name: "aligned", overrides: ["WS_ENDPOINT_ALIGNED": "true"]),
    HarnessArm(name: "legacy", overrides: ["WS_ENDPOINT_ALIGNED": "false"]),
    HarnessArm(name: "flush700", overrides: ["SILENCE_FLUSH_MS": "700"]),
    HarnessArm(name: "flush200", overrides: ["SILENCE_FLUSH_MS": "200"]),
    HarnessArm(name: "flush100", overrides: ["SILENCE_FLUSH_MS": "100"]),
    HarnessArm(name: "flush0", overrides: ["SILENCE_FLUSH_MS": "0"]),
    HarnessArm(name: "chunk100", overrides: ["CHUNK_MS": "100"]),
    HarnessArm(name: "chunk50", overrides: ["CHUNK_MS": "50"]),
    // Acoustic only: the trailing-capture floor never runs in direct mode.
    HarnessArm(name: "min30", overrides: ["POST_ROLL_MIN_MS": "30"]),
    HarnessArm(name: "min15", overrides: ["POST_ROLL_MIN_MS": "15"]),
    HarnessArm(name: "verbatim", overrides: ["SMART_TRANSCRIPTION": "false"]),
    // Acoustic only: the fixed quiet line, as before QUIET_MARGIN_DB existed.
    HarnessArm(name: "fixedquiet", overrides: ["QUIET_MARGIN_DB": "0"]),
  ]

  static func named(_ name: String) -> HarnessArm? { catalog.first { $0.name == name } }
}
