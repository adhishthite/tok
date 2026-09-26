// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TokEngine

struct MicrophoneChoice: Identifiable, Equatable {
  let id: String
  let label: String

  static func options(devices: [InputDeviceCatalog.Device], selection: String) -> [Self] {
    let defaultName = devices.first(where: \.isDefault)?.name
    var result: [Self] = [
      Self(id: "", label: defaultName.map { "System Default (\($0))" } ?? "System Default"),
      Self(id: "auto", label: "Automatic"),
    ]
    var used: Set<String> = ["", "auto"]
    for device in devices.sorted(by: {
      $0.name.localizedStandardCompare($1.name) == .orderedAscending
    }) {
      let value = device.uid.isEmpty ? device.name : device.uid
      guard used.insert(value).inserted else { continue }
      result.append(Self(id: value, label: device.name))
    }
    if !used.contains(selection) {
      let match = InputDeviceCatalog.match(selection, in: devices)
      let label: String
      if selection.lowercased() == "auto" {
        label = "Automatic"
      } else if let match {
        label = "\(match.name) (saved choice)"
      } else {
        label = "Unavailable microphone"
      }
      result.append(Self(id: selection, label: label))
    }
    return result
  }
}
