import Foundation
import Observation
import TokEngine

/// The stats dashboard's state and the app-side writer for the stats stream. Every
/// settled turn is recorded here whether or not history is on.
@MainActor
@Observable
final class StatsViewStore {
  var range = StatsRange.week { didSet { reload() } }
  private(set) var report = StatsReport.empty(.week)
  private(set) var loading = false
  private(set) var error: String?
  /// Words dictated today, for the menu-bar glance. Refreshed after every turn.
  private(set) var wordsToday = 0
  var visible = false
  @ObservationIgnored private(set) var repository: StatsRepository?
  private(set) var isEnabled = true
  private var trackWords = true
  @ObservationIgnored private var typingWordsPerMinute = 40
  @ObservationIgnored private var reloadTask: Task<Void, Never>?
  @ObservationIgnored private var glanceTask: Task<Void, Never>?
  @ObservationIgnored private let now: () -> Date
  @ObservationIgnored private let calendar: Calendar

  init(now: @escaping () -> Date = Date.init, calendar: Calendar = .autoupdatingCurrent) {
    self.now = now
    self.calendar = calendar
  }

  /// Refresh local data on demand, on activation, and when the calendar day changes.
  func refresh() {
    refreshGlance()
    reload()
  }

  var fileURL: URL? { repository?.url }
  var tracksWords: Bool { isEnabled && trackWords }

  func configure(directory: URL, enabled: Bool, trackWords: Bool, typingWordsPerMinute: Int) {
    let url = directory.appendingPathComponent(StatsRepository.fileName)
    let changed =
      repository?.url != url || isEnabled != enabled || self.trackWords != trackWords
      || self.typingWordsPerMinute != typingWordsPerMinute
    if repository?.url != url {
      repository = StatsRepository(directory: directory, calendar: calendar)
    }
    isEnabled = enabled
    self.trackWords = trackWords
    self.typingWordsPerMinute = typingWordsPerMinute
    if changed { reload() }
  }

  /// Fire-and-forget from the turn-settled path. The write happens on the repository queue.
  func record(_ turn: TurnRecord) {
    guard isEnabled, let repository else { return }
    let trackWords = self.trackWords
    Task { [weak self] in
      do {
        try await repository.record(turn, trackWords: trackWords)
        guard let self else { return }
        self.refreshGlance()
        self.reload()
      } catch {
        self?.error = error.localizedDescription
      }
    }
  }

  func reload() {
    guard visible, let repository else { return }
    reloadTask?.cancel()
    loading = true
    let range = self.range
    let typingWordsPerMinute = self.typingWordsPerMinute
    let now = self.now()
    reloadTask = Task { [weak self] in
      do {
        let report = try await repository.report(
          range: range, typingWordsPerMinute: typingWordsPerMinute, now: now)
        guard !Task.isCancelled, let self else { return }
        self.report = report
        self.error = nil
        self.loading = false
      } catch is CancellationError {
      } catch {
        guard !Task.isCancelled else { return }
        self?.error = error.localizedDescription
        self?.loading = false
      }
    }
  }

  func refreshGlance() {
    guard let repository else { return }
    glanceTask?.cancel()
    let start = calendar.startOfDay(for: now())
    glanceTask = Task { [weak self] in
      guard let words = try? await repository.words(since: start), !Task.isCancelled else { return }
      self?.wordsToday = words
    }
  }

  func clear() async {
    guard let repository else { return }
    reloadTask?.cancel()
    glanceTask?.cancel()
    do {
      try await repository.clear()
      wordsToday = 0
      report = StatsReport.empty(range, typingWordsPerMinute: typingWordsPerMinute)
      reload()
    } catch {
      loading = false
      self.error = error.localizedDescription
    }
  }
}
