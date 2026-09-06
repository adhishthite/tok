import SwiftUI
import TokEngine

struct PostProcessingDetailsView: View {
  let metrics: PostProcessingMetrics
  var body: some View {
    VStack(spacing: 8) {
      LabeledContent("Model", value: metrics.model ?? "Not recorded")
      LabeledContent("Added time", value: LatencySnapshot.milliseconds(metrics.latencyMs))
      LabeledContent("Input tokens", value: metrics.inputTokens.map(String.init) ?? "Not reported")
      LabeledContent(
        "Output tokens", value: metrics.outputTokens.map(String.init) ?? "Not reported")
      LabeledContent(
        "Thinking tokens", value: metrics.thinkingTokens.map(String.init) ?? "Not reported")
      LabeledContent(
        "Estimated cost",
        value: metrics.costUSD.map { String(format: "$%.6f", $0) } ?? "Not reported")
      LabeledContent("App context", value: metrics.appContextUsed ? "Included" : "Not included")
      if let reason = metrics.failureDescription {
        Text(reason).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
      }
    }.font(.caption).padding(.top, 8)
  }
}
