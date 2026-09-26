// Copyright 2026 Adhish Thite
// SPDX-License-Identifier: Apache-2.0

import Foundation
import TokEngine

@main
struct SettingsReference {
  static let start = "<!-- BEGIN GENERATED SETTINGS -->"
  static let end = "<!-- END GENERATED SETTINGS -->"
  static let schemaStart = "<!-- BEGIN GENERATED METRICS SCHEMA -->"
  static let schemaEnd = "<!-- END GENERATED METRICS SCHEMA -->"

  static func main() {
    do { try run() } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }

  static func run() throws {
    let arguments = CommandLine.arguments
    guard (3...5).contains(arguments.count), ["--check", "--write"].contains(arguments[1]) else {
      throw failure(
        "Usage: TokSettingsReference --check|--write README.md [PRIVACY.md [.env.example]]")
    }
    for setting in SettingCatalog.all { try validateDefault(setting) }
    let write = arguments[1] == "--write"
    try update(
      URL(fileURLWithPath: arguments[2]), between: start, and: end, content: reference(),
      write: write, name: "Settings reference", count: "\(SettingCatalog.all.count) settings")
    if arguments.count == 5 {
      try updateWhole(
        URL(fileURLWithPath: arguments[4]), content: envTemplate(), write: write,
        name: "Environment template", count: "\(SettingCatalog.all.count) settings")
    }
    if arguments.count >= 4 {
      try update(
        URL(fileURLWithPath: arguments[3]), between: schemaStart, and: schemaEnd,
        content: MetricsSchema.markdown(), write: write, name: "Metrics schema",
        count: "\(MetricsSchema.events.count) metric events")
    }
  }

  /// Replaces or verifies the generated block between two markers in a document.
  static func update(
    _ url: URL, between start: String, and end: String, content body: String, write: Bool,
    name: String, count: String
  ) throws {
    let original = try String(contentsOf: url, encoding: .utf8)
    guard let opening = original.range(of: start),
      let closing = original.range(of: end, range: opening.upperBound..<original.endIndex)
    else { throw failure("\(url.lastPathComponent) is missing its generated markers.") }
    let content = "\n\n" + body + "\n"
    let range = opening.upperBound..<closing.lowerBound
    if write {
      try original.replacingCharacters(in: range, with: content).write(
        to: url, atomically: true, encoding: .utf8)
      print("Generated \(name.lowercased()) for \(count).")
    } else {
      guard String(original[range]) == content else {
        throw failure("\(name) is outdated. Run make settings-reference.")
      }
      print("PASS: \(url.lastPathComponent) matches all \(count).")
    }
  }

  /// Replaces or verifies a file that is generated whole.
  static func updateWhole(_ url: URL, content: String, write: Bool, name: String, count: String)
    throws
  {
    if write {
      try content.write(to: url, atomically: true, encoding: .utf8)
      print("Generated \(name.lowercased()) for \(count).")
    } else {
      guard (try? String(contentsOf: url, encoding: .utf8)) == content else {
        throw failure("\(name) is outdated. Run make settings-reference.")
      }
      print("PASS: \(url.lastPathComponent) matches all \(count).")
    }
  }

  /// The .env template: the two API keys, then every catalog setting at its built-in
  /// default, grouped as in Settings. `make run` imports it once.
  static func envTemplate() -> String {
    var lines = [
      "# Tok configuration template",
      "#",
      "# Copy this file to .env (ignored by git). `make run` imports .env once into Settings and",
      "# Keychain. Delete any line to leave that setting untouched. Import skips HISTORY_DB and",
      "# HISTORY_RETENTION_DAYS; change those in Settings. Values below are the built-in",
      "# defaults; README.md has the full reference.",
      "",
      "# Gemini API key (required). Create one at https://aistudio.google.com/",
      "# Saved to Keychain on import; never stored in preferences.",
      "GEMINI_API_KEY=",
      "",
      "# TypeSafe API key (optional). Create one at https://typesafe.ai/",
      "# Enables Jev judgments (correction scoring, analyzer confidence, per-turn quality",
      "# signals). Everything works without it; nothing is sent to TypeSafe when it is empty.",
      "TYPESAFE_API_KEY=",
    ]
    for group in SettingGroup.allCases {
      let settings = SettingCatalog.all.filter { $0.group == group }
      guard !settings.isEmpty else { continue }
      lines += ["", "# ---- \(group.rawValue) ----"]
      for setting in settings {
        lines += [
          "", "# \(setting.title): \(setting.help)", "# Values: \(envValues(setting.kind))",
          "\(setting.key)=\(setting.defaultValue)",
        ]
      }
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static func envValues(_ kind: SettingKind) -> String {
    switch kind {
    case .toggle: "true or false"
    case .text: "text"
    case .microphone: "empty for system default, auto, or a device name"
    case .integer(let range): "\(range.lowerBound) to \(range.upperBound)"
    case .decimal(let range):
      "\(String(format: "%g", range.lowerBound)) to \(String(format: "%g", range.upperBound))"
    case .choice(let options): "one of " + options.joined(separator: ", ")
    }
  }

  static func validateDefault(_ setting: SettingDefinition) throws {
    let valid: Bool
    switch setting.kind {
    case .text, .microphone: valid = true
    case .toggle: valid = ["true", "false"].contains(setting.defaultValue)
    case .choice(let options):
      valid = Set(options).count == options.count && options.contains(setting.defaultValue)
    case .integer(let range):
      valid = Int(setting.defaultValue).map { range.contains($0) } ?? false
    case .decimal(let range):
      valid = Double(setting.defaultValue).map { $0.isFinite && range.contains($0) } ?? false
    }
    guard valid else { throw failure("Default does not match its control: \(setting.key)") }
  }

  static func reference() -> String {
    var lines = [
      "## Settings reference", "",
      "Generated from `SettingCatalog`. Defaults below are built-in values, before imports or environment overrides.",
      "The API key is stored separately in Keychain and is never part of this table.", "",
      "History retention is changed through a confirmation in Settings. An empty vocabulary path uses Tok’s Application Support folder.",
      "",
    ]
    for group in SettingGroup.allCases {
      let settings = SettingCatalog.all.filter { $0.group == group }
      guard !settings.isEmpty else { continue }
      lines += [
        "### \(group.rawValue)", "", "| Setting | Key | Default | Values | Description |",
        "| --- | --- | --- | --- | --- |",
      ]
      for setting in settings {
        let cells = [
          setting.title, code(setting.key),
          setting.defaultValue.isEmpty ? "(empty)" : code(setting.defaultValue),
          values(setting.kind), setting.help,
        ]
        lines.append("| " + cells.map(escape).joined(separator: " | ") + " |")
      }
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  static func values(_ kind: SettingKind) -> String {
    switch kind {
    case .toggle: "true, false"
    case .text: "Text"
    case .microphone: "System Default, Automatic, or a connected microphone"
    case .integer(let range): "\(range.lowerBound) to \(range.upperBound)"
    case .decimal(let range): "\(range.lowerBound) to \(range.upperBound)"
    case .choice(let options): options.map(code).joined(separator: ", ")
    }
  }

  static func code(_ value: String) -> String {
    "<code>"
      + value.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;") + "</code>"
  }

  static func escape(_ value: String) -> String {
    value.replacingOccurrences(of: "|", with: "&#124;")
      .replacingOccurrences(of: "\n", with: "<br>")
  }

  static func failure(_ message: String) -> NSError {
    NSError(
      domain: "Tok.SettingsReference", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }
}
