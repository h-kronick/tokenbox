import SwiftUI
import Charts

/// Daily token bar chart for the last 30 days.
struct TimelineChartView: View {
    let data: [(date: String, tokens: Int)]
    var accentColor: Color = Color(hex: 0xd4a843)

    var body: some View {
        if data.isEmpty {
            Text("No data yet")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(data, id: \.date) { item in
                BarMark(
                    x: .value("Date", item.date),
                    y: .value("Tokens", item.tokens)
                )
                .foregroundStyle(accentColor.gradient)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    if let intVal = value.as(Int.self) {
                        AxisValueLabel {
                            Text(formatCompactTokens(intVal))
                                .font(.system(size: 8))
                        }
                    }
                    AxisGridLine()
                }
            }
        }
    }
}
