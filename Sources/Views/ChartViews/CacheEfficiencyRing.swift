import SwiftUI

/// Circular progress ring showing cache hit rate percentage.
struct CacheEfficiencyRing: View {
    let efficiency: Double  // 0.0 to 1.0
    var accentColor: Color = Color(hex: 0xd4a843)

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                // Background ring
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 6)

                // Progress ring
                Circle()
                    .trim(from: 0, to: efficiency)
                    .stroke(
                        accentColor,
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                // Percentage text
                Text(String(format: "%.0f%%", efficiency * 100))
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .monospacedDigit()
            }
            .frame(width: 60, height: 60)

            VStack(alignment: .leading, spacing: 2) {
                Text("Cache Read Hit Rate")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Tokens served from cache vs. total input")
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }
        }
    }
}
