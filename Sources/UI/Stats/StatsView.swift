import AppKit
import SwiftUI
import TokEngine

/// The stats dashboard window: headline numbers, activity charts, and word lists for
/// one calendar range.
struct StatsView: View {
  @Environment(DictationStore.self) private var store
  @State private var confirmReset = false
  private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

  var body: some View {
    @Bindable var stats = store.stats
    let report = stats.report
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        LazyVGrid(columns: columns, spacing: 12) { tiles(report) }
        StatsTypingSpeedRow()
        if report.attempts == 0 && !stats.loading {
          emptyState(report)
        } else {
          StatsCard(title: "Words dictated", subtitle: seriesSubtitle(report)) {
            StatsActivityChart(points: report.series, bucket: report.bucket, range: report.range)
          }
          HStack(alignment: .top, spacing: 16) {
            StatsCard(title: "By application", subtitle: "Where your words went") {
              if report.apps.isEmpty {
                note("No applications recorded yet.")
              } else {
                StatsAppsChart(apps: report.apps)
              }
            }
            StatsCard(title: "Time of day", subtitle: "Words by hour") {
              StatsHourChart(hours: report.hours)
            }
          }
          wordsSection(report)
          StatsCard(title: "Details") { details(report) }
        }
        if let error = stats.error { Text(error).font(.callout).foregroundStyle(.red) }
      }
      .padding(20)
    }
    .background(Color(nsColor: .windowBackgroundColor))
    .safeAreaInset(edge: .top, spacing: 0) {
      if !stats.isEnabled { trackingOffBanner }
    }
    .toolbar {
      ToolbarItem {
        Picker("Range", selection: $stats.range) {
          ForEach(StatsRange.allCases) { range in Text(range.title).tag(range) }
        }.pickerStyle(.segmented).frame(width: 440)
      }
      ToolbarItem {
        Button("Refresh", systemImage: "arrow.clockwise") { stats.refresh() }
          .keyboardShortcut("r")
          .help("Refresh stats from this Mac (Command-R)")
          .disabled(stats.loading)
      }
      ToolbarItem {
        Menu {
          Button("Show stats file") { revealFile() }
          Divider()
          Button("Reset stats…", role: .destructive) { confirmReset = true }
        } label: {
          Label("Stats actions", systemImage: "ellipsis.circle")
        }
      }
    }
    .frame(minWidth: 840, minHeight: 600)
    .task {
      stats.visible = true
      stats.refresh()
    }
    .onDisappear { stats.visible = false }
    .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
      stats.refresh()
    }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification))
    { _ in
      stats.refresh()
    }
    .onReceive(
      NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
    ) { _ in
      stats.refresh()
    }
    .confirmationDialog("Reset all dictation stats?", isPresented: $confirmReset) {
      Button("Reset stats", role: .destructive) { Task { await stats.clear() } }
    } message: {
      Text("Words, streaks, and time saved start again from zero. History and vocabulary are kept.")
    }
  }

  @ViewBuilder private func tiles(_ report: StatsReport) -> some View {
    StatsTile(
      title: "Words", value: StatsFormat.count(report.words),
      detail: StatsFormat.change(report.wordsChange, against: report.range.previousTitle)
        ?? sinceDetail(report),
      rising: report.wordsChange.flatMap { $0 == 0 ? nil : $0 > 0 })
    StatsTile(
      title: "Time saved", value: StatsFormat.duration(report.savedSeconds),
      detail: report.words == 0
        ? "Compared with typing the same words."
        : "Typing \(StatsFormat.count(report.words)) words takes about \(StatsFormat.duration(report.typingSeconds))."
    )
    StatsTile(
      title: "Speaking rate", value: StatsFormat.rate(report.wordsPerMinute),
      detail: report.wordsPerMinute.map {
        "\(StatsFormat.decimal($0 / Double(max(1, report.typingWordsPerMinute))))× your typing speed."
      } ?? "Words per minute of speech.")
    StatsTile(
      title: "Dictations", value: StatsFormat.count(report.dictations),
      detail: report.averageWords.map {
        "\(StatsFormat.decimal($0, digits: 0)) words each on average."
      }
        ?? "Dictations that produced text.")
    StatsTile(
      title: "Speaking time", value: StatsFormat.duration(report.speakingSeconds),
      detail: "Plus \(StatsFormat.duration(report.latencySeconds)) waiting for text.")
    StatsTile(
      title: "Streak",
      value: "\(report.currentStreakDays) \(report.currentStreakDays == 1 ? "day" : "days")",
      detail:
        "Best \(report.bestStreakDays) \(report.bestStreakDays == 1 ? "day" : "days"). Active on \(report.activeDays) \(report.activeDays == 1 ? "day" : "days") in this range."
    )
  }

  @ViewBuilder private func wordsSection(_ report: StatsReport) -> some View {
    if store.settings.bool("PRIVACY_MODE") {
      StatsCard(title: "Words") {
        note("Hidden while “Hide dictated words on screen” is on.")
      }
    } else if !store.stats.tracksWords {
      StatsCard(title: "Words") {
        HStack {
          note("Word usage is not being tracked. Existing counts are kept.")
          Spacer()
          Button("Turn on") {
            store.settings.set("STATS", "true")
            store.settings.set("STATS_WORDS", "true")
          }.controlSize(.small)
        }
      }
    } else {
      HStack(alignment: .top, spacing: 16) {
        StatsCard(
          title: "Most used words",
          subtitle:
            "\(StatsFormat.count(report.distinctWords)) distinct words. Common function words are not counted."
        ) {
          if report.topWords.isEmpty {
            note("No words counted yet.")
          } else {
            StatsWordList(words: report.topWords)
          }
        }
        StatsCard(title: "Rarely used words", subtitle: "Words you dictate least often.") {
          if report.rareWords.isEmpty {
            note("No words counted yet.")
          } else {
            StatsWordList(words: report.rareWords)
          }
        }
      }
    }
  }

  private func details(_ report: StatsReport) -> some View {
    Grid(alignment: .leading, horizontalSpacing: 32, verticalSpacing: 8) {
      GridRow {
        LabeledContent("Characters", value: StatsFormat.count(report.characters))
        LabeledContent(
          "Longest dictation",
          value: report.longestWords == 0
            ? "None" : "\(StatsFormat.count(report.longestWords)) words")
      }
      GridRow {
        LabeledContent(
          "Median latency",
          value: report.medianLatencyMs.map { String(format: "%.0f ms", $0) } ?? "Not measured")
        LabeledContent(
          "Empty or failed turns", value: StatsFormat.count(report.attempts - report.dictations))
      }
      GridRow {
        LabeledContent(
          "First dictation",
          value: report.firstDate.map { $0.formatted(.dateTime.day().month().year()) } ?? "None")
        LabeledContent("Typing speed assumed", value: "\(report.typingWordsPerMinute) wpm")
      }
    }
    .font(.callout)
  }

  private func emptyState(_ report: StatsReport) -> some View {
    StatsCard {
      ContentUnavailableView {
        Label(
          report.range == .all
            ? "No dictations yet" : "No dictations \(report.range.title.lowercased())",
          systemImage: "chart.bar.xaxis")
      } description: {
        Text(
          report.range == .all
            ? "Hold \(store.shortcutLabel) and speak. Your words, speaking rate, and time saved will appear here."
            : "Pick a wider range or dictate something.")
      }
      .frame(maxWidth: .infinity, minHeight: 220)
    }
  }

  private var trackingOffBanner: some View {
    HStack {
      Label("Stats tracking is off. New dictations are not counted.", systemImage: "pause.circle")
      Spacer()
      Button("Turn on") { store.settings.set("STATS", "true") }
        .controlSize(.small).disabled(store.settings.isOverridden("STATS"))
    }
    .font(.callout).foregroundStyle(.secondary)
    .padding(.horizontal, 20).padding(.vertical, 8)
    .background(.bar)
  }

  private func note(_ text: String) -> some View {
    Text(text).font(.callout).foregroundStyle(.secondary)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func sinceDetail(_ report: StatsReport) -> String? {
    guard report.range == .all, let first = report.firstDate else { return nil }
    return "Since \(first.formatted(.dateTime.day().month().year()))."
  }

  private func seriesSubtitle(_ report: StatsReport) -> String {
    switch report.bucket {
    case .hour: "Per hour"
    case .day: "Per day"
    case .month: "Per month"
    }
  }

  private func revealFile() {
    guard let url = store.stats.fileURL else { return }
    if FileManager.default.fileExists(atPath: url.path) {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    } else {
      NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
    }
  }
}
