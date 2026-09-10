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
    guard [3, 4].contains(arguments.count), ["--check", "--write"].contains(arguments[1]) else {
      throw failure("Usage: TokSettingsReference --check|--write README.md [PRIVACY.md]")
    }
    for setting in SettingCatalog.all { try validateDefault(setting) }
    let write = arguments[1] == "--write"
    try update(
      URL(fileURLWithPath: arguments[2]), between: start, and: end, content: reference(),
      write: write, name: "Settings reference", count: "\(SettingCatalog.all.count) settings")
    if arguments.count == 4 {
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
