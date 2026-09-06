import SwiftUI

struct LatencySummaryView: View {
  let snapshot: LatencySnapshot?
  var body: some View {
    HStack(alignment: .top, spacing: 28) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Latest dictation").font(.headline)
        Text(LatencySnapshot.milliseconds(snapshot?.total)).font(.title).monospacedDigit()
        Text(snapshot.map { "\($0.route) · \($0.delivery)" } ?? "Dictate to see timing here.")
          .font(.caption).foregroundStyle(.secondary)
      }
      .help(
        "Time from key release to paste dispatch or clipboard delivery. Paste dispatch does not confirm receipt by the destination app."
      )
      Spacer(minLength: 0)
      VStack(alignment: .leading, spacing: 8) {
        LabeledContent("Audio finish", value: LatencySnapshot.milliseconds(snapshot?.capture))
        LabeledContent(
          "Transcription", value: LatencySnapshot.milliseconds(snapshot?.transcription))
        LabeledContent(
          "Cleanup",
          value: snapshot?.postProcessing.map {
            $0.status == "off" ? "Off" : LatencySnapshot.milliseconds($0.latencyMs)
          } ?? "Not recorded")
        LabeledContent("Delivery", value: LatencySnapshot.milliseconds(snapshot?.injection))
        if let metrics = snapshot?.postProcessing, metrics.status != "off" {
          Text(metrics.displayStatus).font(.caption).foregroundStyle(.secondary)
          DisclosureGroup("Cleanup details") {
            PostProcessingDetailsView(metrics: metrics)
          }.font(.caption)
        }
      }.font(.callout).monospacedDigit().frame(width: 250)
    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
      .background(Color(nsColor: .windowBackgroundColor))
  }
}
