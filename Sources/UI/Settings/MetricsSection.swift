import SwiftUI
import TokEngine

/// The usage metrics toggle with the controls that make it trustworthy.
struct MetricsSection: View {
  @Environment(DictationStore.self) private var store
  @Environment(\.openWindow) private var openWindow
  var body: some View {
    Section {
      if let setting = SettingCatalog.all.first(where: { $0.key == "SHARE_USAGE_METRICS" }) {
        SettingRow(setting: setting)
      }
      if store.metrics.enabled {
        LabeledContent {
          Button("Reset") { store.metrics.resetInstallID() }
        } label: {
          Text("Install ID")
          Text(store.metrics.installID).font(.caption.monospaced()).foregroundStyle(.secondary)
            .textSelection(.enabled)
        }
        LabeledContent {
          HStack {
            Button("View") { openWindow(id: "diagnostics") }
            Button("Delete") { store.metrics.deleteQueue() }.disabled(
              store.metrics.queuedCount == 0)
          }
        } label: {
          Text("Queued events")
          Text(queueSummary).font(.caption).foregroundStyle(.secondary)
        }
      }
    } header: {
      Text("Usage metrics")
    } footer: {
      Text(
        "This version keeps events on this Mac and sends nothing. A later version that sends them will say so in its release notes and here."
      )
    }
  }
  private var queueSummary: String {
    switch store.metrics.queuedCount {
    case 0: "None recorded yet."
    case 1: "1 event, kept locally."
    case let count: "\(count) events, kept locally."
    }
  }
}
