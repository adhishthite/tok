import SwiftUI
import TokEngine

/// A ranked list of words with a proportional bar, for the most and least used lists.
struct StatsWordList: View {
  let words: [StatsWordCount]
  var limit = 12
  private var shown: [StatsWordCount] { Array(words.prefix(limit)) }
  private var maximum: Int { shown.map(\.count).max() ?? 1 }
  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 7) {
      ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
        GridRow {
          Text("\(index + 1)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
            .gridColumnAlignment(.trailing)
          Text(item.word).lineLimit(1)
          Capsule()
            .fill(Color.accentColor.opacity(0.55))
            .frame(width: max(4, 72 * CGFloat(item.count) / CGFloat(max(maximum, 1))), height: 5)
          Text(StatsFormat.count(item.count)).font(.callout).foregroundStyle(.secondary)
            .monospacedDigit().gridColumnAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
      }
    }
  }
}
