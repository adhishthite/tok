import Charts
import SwiftUI
import TokEngine

/// Words per bucket across the selected range. Hover or drag to read one bucket.
struct StatsActivityChart: View {
  let points: [StatsSeriesPoint]
  let bucket: StatsBucket
  let range: StatsRange
  @State private var selection: Date?
  private let calendar = Calendar.current

  var body: some View {
    Chart {
      ForEach(points) { point in
        BarMark(
          x: .value("Time", point.date, unit: bucket.component),
          y: .value("Words", point.words)
        )
        .foregroundStyle(barStyle(for: point))
        .cornerRadius(3)
      }
      if let selected {
        RuleMark(x: .value("Selected", selected.date, unit: bucket.component))
          .foregroundStyle(.secondary.opacity(0.35))
          .annotation(
            position: .top, spacing: 6,
            overflowResolution: .init(x: .fit(to: .chart), y: .disabled)
          ) {
            annotation(for: selected)
          }
      }
    }
    .chartXSelection(value: $selection)
    .chartXAxis {
      AxisMarks(values: axisValues) { _ in
        AxisGridLine()
        AxisValueLabel(format: axisFormat)
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in
        AxisGridLine()
        AxisValueLabel()
      }
    }
    .frame(height: 220)
    .accessibilityLabel("Words dictated over time")
  }

  private var selected: StatsSeriesPoint? {
    guard let selection,
      let start = calendar.dateInterval(of: bucket.component, for: selection)?.start
    else { return nil }
    return points.first { $0.date == start }
  }

  private func barStyle(for point: StatsSeriesPoint) -> some ShapeStyle {
    let dimmed = selected != nil && selected?.date != point.date
    return Color.accentColor.opacity(dimmed ? 0.35 : 1)
  }

  private func annotation(for point: StatsSeriesPoint) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(point.date, format: labelFormat).font(.caption.weight(.semibold))
      Text("\(StatsFormat.count(point.words)) words · \(point.dictations) dictations")
        .font(.caption)
      if let rate = point.wordsPerMinute {
        Text(StatsFormat.rate(rate)).font(.caption).foregroundStyle(.secondary)
      }
    }
    .padding(8)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
  }

  private var axisValues: AxisMarkValues {
    switch (bucket, range) {
    case (.hour, _): .stride(by: .hour, count: 6)
    case (.day, .week): .stride(by: .day)
    case (.day, _): .stride(by: .day, count: 7)
    case (.month, _): .stride(by: .month)
    }
  }

  private var axisFormat: Date.FormatStyle {
    switch (bucket, range) {
    case (.hour, _): .dateTime.hour()
    case (.day, .week): .dateTime.weekday(.abbreviated)
    case (.day, .month): .dateTime.day()
    case (.day, _): .dateTime.month(.abbreviated).day()
    case (.month, .year): .dateTime.month(.abbreviated)
    case (.month, _): .dateTime.month(.abbreviated).year(.twoDigits)
    }
  }

  private var labelFormat: Date.FormatStyle {
    switch bucket {
    case .hour: .dateTime.hour()
    case .day: .dateTime.weekday(.abbreviated).day().month(.abbreviated)
    case .month: .dateTime.month(.wide).year()
    }
  }
}
