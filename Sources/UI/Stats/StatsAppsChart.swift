import Charts
import SwiftUI
import TokEngine

/// Words per destination application, most first.
struct StatsAppsChart: View {
  let apps: [StatsAppShare]
  var body: some View {
    Chart(apps) { app in
      BarMark(x: .value("Words", app.words), y: .value("Application", app.name))
        .foregroundStyle(Color.accentColor.gradient)
        .cornerRadius(3)
        .annotation(position: .trailing, spacing: 6) {
          Text(StatsFormat.count(app.words)).font(.caption2).foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }
    .chartXAxis(.hidden)
    .chartYScale(domain: apps.map(\.name))
    .chartYAxis {
      AxisMarks { _ in AxisValueLabel() }
    }
    .frame(height: CGFloat(max(apps.count, 1)) * 30 + 8)
    .accessibilityLabel("Words by application")
  }
}
