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
  ]

  static func named(_ name: String) -> HarnessArm? { catalog.first { $0.name == name } }
}
