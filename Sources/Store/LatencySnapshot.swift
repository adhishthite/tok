import Foundation
import TokEngine

/// A diagnostics summary containing no transcript or application identity.
struct LatencySnapshot {
  let total: Double?
  let capture: Double?
  let transcription: Double?
  let injection: Double?
  let route: String
  let delivery: String
  let postProcessing: PostProcessingMetrics?
  let totalCost: Double?

  init(record: TurnRecord) {
    postProcessing = record.postProcessing
    totalCost = Self.valid(record.costUSD)
    total = Self.valid(record.totalMs)
    capture = Self.valid(record.captureFinalizeMs)
    transcription = Self.valid(record.roundtripMs)
    injection = Self.valid(record.injectMs)
    route = record.isLiveRoute.map { $0 ? "Live" : "REST" } ?? "Unknown route"
    delivery = DeliveryLabel.delivery(record.deliveryOutcome ?? "")
  }

  private static func valid(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value >= 0 else { return nil }
    return value
  }

  static func milliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "Not measured"
  }
}
