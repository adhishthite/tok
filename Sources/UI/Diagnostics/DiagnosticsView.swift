import SwiftUI

struct DiagnosticsView: View {
  @Environment(DictationStore.self) private var store
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text(store.lastLatencyLine).font(.system(.callout, design: .monospaced)).textSelection(
        .enabled)
      Divider()
      ScrollView {
        Text(store.diagnostics.joined(separator: "\n"))
          .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }.padding(20).frame(minWidth: 600, minHeight: 300)
  }
}
