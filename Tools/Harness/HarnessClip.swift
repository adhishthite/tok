// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One entry of build/harness/clips/manifest.json, written by Scripts/harness_clips.py.
struct HarnessClip: Decodable {
  let clipId: String
  let phraseId: String
  let text: String
  /// ISO 639-1 code. Absent in manifests written before languages were added: English.
  let language: String?
  let codeSwitch: Bool
  let ttsModel: String
  let voice: String
  let accent: String
  let style: String
  let durationS: Double
  let speechOnsetS: Double
  let speechOffsetS: Double
  let validationWer: Double

  struct Manifest: Decodable { let clips: [HarnessClip] }

  static func load(directory: URL) throws -> [HarnessClip] {
    let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(Manifest.self, from: data).clips.filter {
      FileManager.default.fileExists(
        atPath: directory.appendingPathComponent("\($0.clipId).wav").path)
    }
  }
}
