import AppKit
import Observation
import TokEngine

@MainActor
@Observable
final class HistoryViewStore {
  var search = "" { didSet { reload() } }
  var days = 7 { didSet { reload() } }
  var selection: Set<Int64> = []
  private(set) var entries: [HistoryEntry] = []
  private(set) var statistics = HistoryStatistics.empty
  private(set) var loading = false
  private(set) var error: String?
  var visible = false
  @ObservationIgnored private var repository = HistoryRepository(path: "")
  @ObservationIgnored private var queryTask: Task<Void, Never>?

  func configure(path: String) {
    repository = HistoryRepository(path: path)
    if visible { reload() }
  }
  func reload() {
    guard visible else { return }
    queryTask?.cancel()
    queryTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .milliseconds(180))
        guard let self else { return }
        self.loading = true
        let since =
          self.days == 1
          ? Calendar.current.startOfDay(for: Date())
          : self.days == 0
            ? Date(timeIntervalSince1970: 0)
            : Calendar.current.date(byAdding: .day, value: -self.days, to: Date())!
        async let rows = self.repository.entries(search: self.search, since: since)
        async let stats = self.repository.statistics(since: since)
        let result = try await (rows, stats)
        guard !Task.isCancelled else { return }
        self.entries = result.0
        self.statistics = result.1
        self.selection.formIntersection(Set(result.0.map(\.id)))
        self.error = nil
        self.loading = false
      } catch is CancellationError {} catch {
        guard !Task.isCancelled else { return }
        self?.error = error.localizedDescription
        self?.loading = false
      }
    }
  }
  func deleteSelection() async {
    do {
      try await repository.delete(ids: selection)
      selection = []
      reload()
    } catch { self.error = error.localizedDescription }
  }
  func clear() async {
    do {
      try await repository.clear()
      selection = []
      reload()
    } catch { self.error = error.localizedDescription }
  }
  func copySelection() {
    let text = entries.filter { selection.contains($0.id) }.map(\.text).joined(separator: "\n\n")
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }
  func exportCSV() async {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Tok history.csv"
    panel.message = "Exports all history. Spreadsheet formula prefixes in text are escaped."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let all = try await repository.entries(limit: 0)
      try await Task.detached(priority: .utility) {
        var lines = ["Date,Text,Application,Route,Status,Words,Cost USD,Total ms"]
        for row in all {
          let fields = [
            row.date.ISO8601Format(), row.text, row.app, row.route, row.outcome, String(row.words),
            row.cost.map { String($0) } ?? "", row.totalMs.map { String($0) } ?? "",
          ]
          lines.append(fields.map(CSVField.encode).joined(separator: ","))
        }
        try (lines.joined(separator: "\r\n") + "\r\n").write(
          to: url, atomically: true, encoding: .utf8)
      }.value
    } catch { self.error = "Could not export history. Check the destination and try again." }
  }
}
