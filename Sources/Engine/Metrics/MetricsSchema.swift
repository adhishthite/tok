/// The complete list of usage metric events and fields. PRIVACY.md is generated
/// from this table, and a test rejects any event whose keys are not listed here.
public enum MetricsSchema {
  public static let version = 1

  /// Fields present on every event.
  public static let common: [MetricFieldDefinition] = [
    MetricFieldDefinition("event", kind: "name", "Which event this is."),
    MetricFieldDefinition("schema", kind: "integer", "Schema version, currently 1."),
    MetricFieldDefinition(
      "install_id", kind: "random id",
      "Random identifier created on this Mac, rotated every 90 days, resettable in Settings."),
    MetricFieldDefinition("hour", kind: "timestamp", "UTC hour the event happened, no minutes."),
    MetricFieldDefinition("app_version", kind: "text", "Tok version, such as 0.1.3."),
    MetricFieldDefinition("build", kind: "text", "Tok build number."),
    MetricFieldDefinition("os_version", kind: "text", "macOS version, such as 15.6."),
    MetricFieldDefinition("arch", kind: "category", "arm64 or x86_64."),
  ]

  public static let events: [MetricEventDefinition] = [
    MetricEventDefinition(
      "app_launched", "Tok started.",
      fields: [
        MetricFieldDefinition(
          "days_since_install", kind: "bucket", "0, 1-7, 8-30, 31-90, or 90+."),
        MetricFieldDefinition("language_count", kind: "integer", "Number of configured languages."),
        MetricFieldDefinition(
          "non_english", kind: "boolean", "Whether any configured language is not English."),
        MetricFieldDefinition("smart_transcription", kind: "boolean", "Live cleanup setting."),
        MetricFieldDefinition("post_process", kind: "boolean", "Polish before pasting setting."),
        MetricFieldDefinition("hotkey_mode", kind: "category", "push_to_talk or toggle."),
        MetricFieldDefinition("overlay", kind: "boolean", "Dictation overlay setting."),
        MetricFieldDefinition("sounds", kind: "boolean", "Dictation sounds setting."),
        MetricFieldDefinition("privacy_mode", kind: "boolean", "Hide dictated words setting."),
        MetricFieldDefinition("history", kind: "boolean", "Local history setting."),
        MetricFieldDefinition("warm_microphone", kind: "boolean", "Keep microphone ready setting."),
      ]),
    MetricEventDefinition(
      "setup_state", "Permissions and key state at launch and when setup completes.",
      fields: [
        MetricFieldDefinition("microphone", kind: "boolean", "Microphone permission granted."),
        MetricFieldDefinition(
          "accessibility", kind: "boolean", "Accessibility permission granted."),
        MetricFieldDefinition(
          "input_monitoring", kind: "boolean", "Input Monitoring permission granted."),
        MetricFieldDefinition(
          "api_key", kind: "boolean", "Whether a key is stored. Never the key."),
        MetricFieldDefinition("complete", kind: "boolean", "Whether setup is finished."),
      ]),
    MetricEventDefinition(
      "dictation", "One dictation finished, with or without text.",
      fields: [
        MetricFieldDefinition(
          "outcome", kind: "category", "success, empty, error, delivery_failed, or other."),
        MetricFieldDefinition("route", kind: "category", "live, fallback, or none."),
        MetricFieldDefinition(
          "delivery", kind: "category", "dispatched, copied, failed, or none."),
        MetricFieldDefinition(
          "finish", kind: "category", "release, lock_press, lock_limit, or other."),
        MetricFieldDefinition(
          "latency", kind: "bucket",
          "Release to delivery in milliseconds: <500, 500-1000, 1000-2000, 2000-4000, or 4000+."),
        MetricFieldDefinition(
          "audio", kind: "bucket", "Audio seconds: <2, 2-5, 5-15, 15-60, or 60+."),
        MetricFieldDefinition("smart", kind: "boolean", "Live cleanup was on."),
        MetricFieldDefinition(
          "cleanup", kind: "category", "off, completed, skipped, timed_out, failed, or other."),
        MetricFieldDefinition("had_error", kind: "boolean", "Whether an error was recorded."),
        MetricFieldDefinition(
          "input_tokens", kind: "integer", "Raw input token count from the API, or null."),
        MetricFieldDefinition(
          "output_tokens", kind: "integer", "Raw output token count from the API, or null."),
      ]),
  ]

  public static func definition(named name: String) -> MetricEventDefinition? {
    events.first { $0.name == name }
  }

  /// Markdown tables for PRIVACY.md, in catalog order.
  public static func markdown() -> String {
    var lines = [
      "### Fields on every event", "", "| Field | Kind | Meaning |", "| --- | --- | --- |",
    ]
    lines += common.map(row)
    for event in events {
      lines += [
        "", "### \(event.name)", "", event.description, "", "| Field | Kind | Meaning |",
        "| --- | --- | --- |",
      ]
      lines += event.fields.map(row)
    }
    return lines.joined(separator: "\n")
  }

  private static func row(_ field: MetricFieldDefinition) -> String {
    "| `\(field.name)` | \(field.kind) | \(field.description) |"
  }
}
