import Foundation

/// One usage metric event, built only from closed vocabularies, buckets, and counts.
public struct MetricEvent: Equatable, Sendable {
  public let name: String
  public let fields: [String: MetricValue]

  public init(name: String, envelope: MetricEnvelope, fields: [String: MetricValue]) {
    self.name = name
    var merged = envelope.fields
    merged["event"] = .string(name)
    for (key, value) in fields { merged[key] = value }
    self.fields = merged
  }

  /// Keys that are not in the schema. Empty for every event the engine builds.
  public var undocumentedKeys: Set<String> {
    let allowed = Set(MetricsSchema.common.map(\.name))
      .union(MetricsSchema.definition(named: name)?.fieldNames ?? [])
    return Set(fields.keys).subtracting(allowed)
  }

  public func json() throws -> Data {
    let object = fields.mapValues(\.json)
    return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  }

  public static func launch(
    envelope: MetricEnvelope, configuration: EngineConfiguration, daysSinceInstall: Int
  ) -> MetricEvent {
    let languages = configuration.languageCodes
    return MetricEvent(
      name: "app_launched", envelope: envelope,
      fields: [
        "days_since_install": MetricsBucket.days(daysSinceInstall),
        "language_count": .int(languages.count),
        "non_english": .bool(languages.contains { !$0.lowercased().hasPrefix("en") }),
        "smart_transcription": .bool(configuration.smartTranscription),
        "post_process": .bool(configuration.postProcessEnabled),
        "hotkey_mode": MetricsBucket.category(
          configuration.hotkeyMode, allowed: ["push_to_talk", "toggle"]),
        "overlay": .bool(configuration.showHUD),
        "sounds": .bool(configuration.soundFeedback),
        "privacy_mode": .bool(configuration.privacyMode),
        "history": .bool(configuration.historyEnabled),
        "warm_microphone": .bool(configuration.keepMicrophoneWarm),
      ])
  }

  public static func setup(
    envelope: MetricEnvelope, microphone: Bool, accessibility: Bool, inputMonitoring: Bool,
    apiKey: Bool
  ) -> MetricEvent {
    MetricEvent(
      name: "setup_state", envelope: envelope,
      fields: [
        "microphone": .bool(microphone), "accessibility": .bool(accessibility),
        "input_monitoring": .bool(inputMonitoring), "api_key": .bool(apiKey),
        "complete": .bool(microphone && accessibility && inputMonitoring && apiKey),
      ])
  }

  public static func dictation(envelope: MetricEnvelope, record: TurnRecord) -> MetricEvent {
    let route: String =
      switch record.isLiveRoute {
      case .some(true): "live"
      case .some(false): "fallback"
      case .none: "none"
      }
    return MetricEvent(
      name: "dictation", envelope: envelope,
      fields: [
        "outcome": MetricsBucket.category(
          record.outcome, allowed: ["success", "empty", "error", "delivery_failed"],
          empty: "other"),
        "route": .string(route),
        "delivery": MetricsBucket.category(
          record.deliveryOutcome, allowed: ["dispatched", "copied", "failed"]),
        "finish": MetricsBucket.category(
          record.finishMode, allowed: ["release", "lock_press", "lock_limit"], empty: "other"),
        "latency": MetricsBucket.latency(record.totalMs),
        "audio": MetricsBucket.audio(record.audioSeconds),
        "smart": .bool(record.smartMode),
        "cleanup": MetricsBucket.category(
          record.postProcessing?.status,
          allowed: ["off", "completed", "skipped", "timed_out", "failed"],
          empty: "off"),
        "had_error": .bool(!(record.error ?? "").isEmpty),
        "input_tokens": record.inputTokens.map(MetricValue.int) ?? .null,
        "output_tokens": record.outputTokens.map(MetricValue.int) ?? .null,
      ])
  }
}
