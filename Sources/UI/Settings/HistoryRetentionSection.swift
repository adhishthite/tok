import SwiftUI

struct HistoryRetentionSection: View {
  @Environment(DictationStore.self) private var store
  @State private var pending = 0
  @State private var confirm = false
  var body: some View {
    Section {
      Picker(
        "Keep history",
        selection: Binding(
          get: { Int(store.settings.string("HISTORY_RETENTION_DAYS")) ?? 0 },
          set: { value in
            if value == 0 {
              store.settings.set("HISTORY_RETENTION_DAYS", "0")
            } else {
              pending = value
              confirm = true
            }
          })
      ) {
        Text("Forever").tag(0)
        Text("7 days").tag(7)
        Text("30 days").tag(30)
        Text("90 days").tag(90)
        Text("1 year").tag(365)
      }.disabled(store.settings.isOverridden("HISTORY_RETENTION_DAYS"))
      if let error = store.retentionError { Text(error).font(.caption).foregroundStyle(.secondary) }
    } footer: {
      Text(
        "A limited retention period automatically deletes older dictations and observed corrections."
      )
    }
    .confirmationDialog("Delete history older than \(pending) days?", isPresented: $confirm) {
      Button("Apply retention", role: .destructive) {
        store.settings.set("HISTORY_RETENTION_DAYS", String(pending))
      }
    } message: {
      Text("Existing older records will be deleted. Vocabulary and settings are kept.")
    }
  }
}
