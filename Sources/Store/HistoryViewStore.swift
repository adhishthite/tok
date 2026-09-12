import AppKit
import Observation
import TokEngine

@MainActor
@Observable
final class HistoryViewStore {
  var search = "" { didSet { reload(debounceSearch: true, resetLimit: true) } }
  var days = 7 {
    didSet { reload(resetLimit: true) }
  }
  var selection: Set<Int64> = []
  private(set) var entries: [HistoryEntry] = []
  private(set) var statistics = HistoryStatistics.empty
  private(set) var loading = false
  private(set) var error: String?
  var visible = false
  /// Audit F31: History capped silently at this many rows. Kept, but now visible
  /// and raisable, instead of a hard ceiling the user never sees.
  static let pageSize = 500
  private(set) var limit = pageSize
  /// Total rows matching the current filter, independent of `limit`.
  private(set) var totalCount = 0
  @ObservationIgnored private var repository = HistoryRepository(path: "")
  @ObservationIgnored private var queryTask: Task<Void, Never>?

  func configure(path: String) {
    repository = HistoryRepository(path: path)
    if visible { reload() }
  }
  /// True while another page can still be loaded. Past the repository's row cap the
  /// table cannot grow, so the button gives way to a pointer at CSV export.
  var canShowMore: Bool { totalCount > entries.count && limit < HistoryRepository.maxRows }
  /// Raises the visible row cap by one page and reloads. Simple "show more"
  /// instead of cursor pagination, per the audit remedy.
  func showMore() {
    limit += Self.pageSize
    reload()
  }
  func reload(debounceSearch: Bool = false, resetLimit: Bool = false) {
    guard visible else { return }
    if resetLimit { limit = Self.pageSize }
    queryTask?.cancel()
    loading = true
    queryTask = Task { [weak self] in
      do {
        if debounceSearch { try await Task.sleep(for: .milliseconds(180)) }
        try Task.checkCancellation()
        guard let self else { return }
        let since =
          self.days == 1
          ? Calendar.current.startOfDay(for: Date())
          : self.days == 0
            ? Date(timeIntervalSince1970: 0)
            : Calendar.current.date(byAdding: .day, value: -self.days, to: Date())!
        async let rows = self.repository.entries(
          search: self.search, since: since, limit: self.limit)
        async let stats = self.repository.statistics(since: since)
        async let total = self.repository.count(search: self.search, since: since)
        let result = try await (rows, stats, total)
        guard !Task.isCancelled else { return }
        self.entries = result.0
        self.statistics = result.1
        self.totalCount = result.2
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
  var selectedText: String {
    entries.filter { selection.contains($0.id) }.map(\.text).joined(separator: "\n\n")
  }
  func copySelection() {
    let text = selectedText
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
        var lines = [
          "Date,Text,Application,Route,Status,Words,Cost USD,Total ms,Cleanup status,Cleanup model,Cleanup ms,Cleanup input tokens,Cleanup output tokens,Cleanup thinking tokens,Cleanup cost USD,Cleanup error,Cleanup app context,Transcription cost USD"
        ]
        for row in all {
          var fields: [String] = [
            row.date.ISO8601Format(), row.text, row.app, row.route, row.outcome, String(row.words),
            row.cost.map { String($0) } ?? "", row.totalMs.map { String($0) } ?? "",
          ]
          let cleanup = row.postProcessing
          fields += [
            cleanup?.status ?? "", cleanup?.model ?? "",
            cleanup?.latencyMs.map { String($0) } ?? "",
            cleanup?.inputTokens.map { String($0) } ?? "",
            cleanup?.outputTokens.map { String($0) } ?? "",
            cleanup?.thinkingTokens.map { String($0) } ?? "",
            cleanup?.costUSD.map { String($0) } ?? "",
            cleanup?.errorCode ?? "", cleanup.map { String($0.appContextUsed) } ?? "",
            row.transcriptionCost.map { String($0) } ?? "",
          ]
          lines.append(fields.map(CSVField.encode).joined(separator: ","))
        }
        try (lines.joined(separator: "\r\n") + "\r\n").write(
          to: url, atomically: true, encoding: .utf8)
      }.value
    } catch { self.error = "Could not export history. Check the destination and try again." }
  }
}
