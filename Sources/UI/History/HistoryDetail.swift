import SwiftUI
import TokEngine

struct HistoryDetail: View {
  let entry: HistoryEntry
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text(entry.date, format: .dateTime.day().month().hour().minute()).foregroundStyle(
          .secondary)
        Text(entry.text.isEmpty ? "No transcript" : entry.text).textSelection(.enabled)
        if !entry.error.isEmpty { Text(entry.error).foregroundStyle(.secondary) }
        Divider()
        LabeledContent("Application", value: entry.app.isEmpty ? "Unknown" : entry.app)
        LabeledContent("Delivery", value: entry.delivery.isEmpty ? entry.outcome : entry.delivery)
        LabeledContent(
          "Estimated cost", value: entry.cost.map { String(format: "$%.5f", $0) } ?? "Not reported")
        LabeledContent(
          "Status", value: entry.outcome.replacingOccurrences(of: "_", with: " ").capitalized)
        DisclosureGroup("Technical details") {
          VStack(spacing: 10) {
            LabeledContent(
              "Audio duration",
              value: entry.audioSeconds.map { String(format: "%.2f s", $0) } ?? "Not measured")
            LabeledContent("Route", value: entry.route)
            LabeledContent("Model", value: entry.model)
            LabeledContent("Event queue", value: milliseconds(entry.eventQueueMs))
            LabeledContent("Capture", value: milliseconds(entry.captureMs))
            LabeledContent("First token", value: milliseconds(entry.firstTokenMs))
            LabeledContent("API", value: milliseconds(entry.apiMs))
            LabeledContent("Injection", value: milliseconds(entry.injectionMs))
            LabeledContent("Total", value: milliseconds(entry.totalMs))
            LabeledContent("Ready again", value: milliseconds(entry.readyMs))
            LabeledContent(
              "Input tokens", value: entry.inputTokens.map(String.init) ?? "Not reported")
            LabeledContent(
              "Output tokens", value: entry.outputTokens.map(String.init) ?? "Not reported")
            LabeledContent("Finish", value: entry.finishMode)
          }.font(.caption).padding(.top, 10)
        }
      }.padding(20)
    }.frame(minWidth: 260, idealWidth: 320, maxWidth: 400)
  }
  private func milliseconds(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "Not measured"
  }
}
