import SwiftUI

struct DiagnosticsView: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    VStack(spacing: 0) {
      LatencySummaryView(snapshot: store.lastLatency)
      Divider()
      DiagnosticLogView(
        entries: store.diagnostics, clear: store.clearDiagnostics,
        saveReport: { Task { await store.saveDiagnosticsReport() } })
      Divider()
      MetricsPayloadView()
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        Text("Build \(BuildIdentity.revision)").font(.caption).foregroundStyle(.secondary)
          .textSelection(.enabled)
        Text("A rolling log is kept at \(diagnosticsLogPath)").font(.caption)
          .foregroundStyle(.secondary).textSelection(.enabled)
      }.frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 6)
    }.frame(minWidth: 720, idealWidth: 860, minHeight: 460)
  }
  private var diagnosticsLogPath: String {
    store.settings.supportDirectory.appendingPathComponent("diagnostics.log").path
  }
}
