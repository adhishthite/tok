import SwiftUI
import TokEngine

struct HistoryView: View {
  @Environment(DictationStore.self) private var store
  @State private var confirmDelete = false
  @State private var confirmClear = false
  var body: some View {
    @Bindable var history = store.history
    VStack(spacing: 0) {
      HStack(spacing: 24) {
        HistoryMetric(title: "Completed", value: String(history.statistics.count))
        HistoryMetric(title: "Words", value: String(history.statistics.words))
        HistoryMetric(
          title: "Estimated cost", value: String(format: "$%.3f", history.statistics.cost))
        HistoryMetric(
          title: "Median latency",
          value: history.statistics.medianMs.map { String(format: "%.0f ms", $0) } ?? "Not measured"
        )
        HistoryMetric(
          title: "95th percentile",
          value: history.statistics.p95Ms.map { String(format: "%.0f ms", $0) } ?? "Not measured")
      }.padding(20)
      Divider()
      HSplitView {
        Table(history.entries, selection: $history.selection) {
          TableColumn("Date") { row in
            Text(row.date, format: .dateTime.month().day().hour().minute())
          }.width(min: 120, ideal: 150, max: 180)
          TableColumn("Dictation") { row in
            Text(row.preview.isEmpty ? row.outcome : row.preview).lineLimit(1)
          }
          TableColumn("Application", value: \.app).width(min: 80, ideal: 120, max: 180)
          TableColumn("Latency") { row in
            Text(row.totalMs.map { String(format: "%.0f ms", $0) } ?? "Not measured")
              .monospacedDigit()
          }.width(95)
        }
        .contextMenu {
          Button("Copy") { history.copySelection() }.disabled(history.selection.isEmpty)
          Button("Delete…", role: .destructive) { confirmDelete = true }.disabled(
            history.selection.isEmpty)
        }
        .overlay {
          if history.entries.isEmpty && !history.loading {
            ContentUnavailableView(
              history.search.isEmpty ? "No dictations yet" : "No matching dictations",
              systemImage: "text.bubble",
              description: Text(
                history.search.isEmpty
                  ? "Your saved dictations will appear here." : "Try another search or date range.")
            )
          }
        }
        if history.selection.count == 1,
          let entry = history.entries.first(where: { history.selection.contains($0.id) })
        {
          HistoryDetail(entry: entry)
        }
      }
      if let error = history.error { Text(error).font(.callout).foregroundStyle(.red).padding(8) }
    }
    .searchable(text: $history.search, prompt: "Search dictations")
    .toolbar {
      ToolbarItem {
        Picker("Date range", selection: $history.days) {
          Text("Today").tag(1)
          Text("7 days").tag(7)
          Text("30 days").tag(30)
          Text("All time").tag(0)
        }.pickerStyle(.segmented).frame(width: 280)
      }
      ToolbarItem {
        Menu {
          Button("Export CSV…") { Task { await history.exportCSV() } }
          Button("Delete selected…", role: .destructive) { confirmDelete = true }.disabled(
            history.selection.isEmpty)
          Divider()
          Button("Clear all history…", role: .destructive) { confirmClear = true }
        } label: {
          Label("History actions", systemImage: "ellipsis.circle")
        }
      }
    }
    .frame(minWidth: 760, minHeight: 460)
    .task {
      history.visible = true
      history.configure(path: store.settings.configuration.historyDbPath)
      history.reload()
    }
    .onDisappear { history.visible = false }
    .confirmationDialog("Delete selected dictations?", isPresented: $confirmDelete) {
      Button("Delete dictations", role: .destructive) { Task { await history.deleteSelection() } }
    }
    .confirmationDialog("Clear all dictation history?", isPresented: $confirmClear) {
      Button("Clear history", role: .destructive) { Task { await history.clear() } }
    } message: {
      Text(
        "This removes saved dictations and observed corrections. Vocabulary and settings are kept.")
    }
  }
}
