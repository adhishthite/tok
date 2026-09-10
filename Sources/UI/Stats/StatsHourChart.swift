import Charts
import SwiftUI

/// Words by local hour of day, so the user can see when they dictate most.
struct StatsHourChart: View {
  let hours: [Int]
  var body: some View {
    Chart(Array(hours.enumerated()), id: \.offset) { hour, words in
      BarMark(
        xStart: .value("Start", hour), xEnd: .value("End", hour + 1),
        y: .value("Words", words)
      )
      .foregroundStyle(Color.accentColor.gradient)
    }
    .chartXScale(domain: 0...24)
    .chartXAxis {
      AxisMarks(values: [0, 6, 12, 18, 24]) { value in
        AxisGridLine()
        AxisValueLabel {
          if let hour = value.as(Int.self) { Text(Self.label(hour: hour)) }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading) { _ in
        AxisGridLine()
        AxisValueLabel()
      }
    }
    .frame(height: 160)
    .accessibilityLabel("Words by hour of day")
  }

  private static func label(hour: Int) -> String {
    let calendar = Calendar.current
    guard let date = calendar.date(bySettingHour: hour % 24, minute: 0, second: 0, of: Date())
    else { return "\(hour)" }
    return date.formatted(.dateTime.hour())
  }
}
