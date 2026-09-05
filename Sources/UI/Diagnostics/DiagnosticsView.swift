import SwiftUI

struct DiagnosticsView: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    VStack(spacing: 0) {
      LatencySummaryView(snapshot: store.lastLatency)
      Divider()
      DiagnosticLogView(entries: store.diagnostics, clear: store.clearDiagnostics)
    }.frame(minWidth: 720, idealWidth: 860, minHeight: 460)
  }
}
