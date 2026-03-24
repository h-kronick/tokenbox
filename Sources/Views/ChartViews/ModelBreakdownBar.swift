import SwiftUI

/// Horizontal stacked bar showing model proportions (Opus / Sonnet / Haiku).
struct ModelBreakdownBar: View {
    let data: [(model: String, tokens: Int)]

    private var total: Int {
        data.reduce(0) { $0 + $1.tokens }
    }

    var body: some View {
        if total == 0 {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.2))
        } else {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(data, id: \.model) { item in
                        let fraction = CGFloat(item.tokens) / CGFloat(total)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(colorForModel(item.model))
                            .frame(width: max(geo.size.width * fraction, 2))
                            .overlay(
                                Text(shortModelName(item.model))
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundColor(.white)
                                    .opacity(fraction > 0.15 ? 1 : 0)
                            )
                    }
                }
            }
        }
    }

    private func colorForModel(_ model: String) -> Color {
        if model.contains("opus") { return Color(hex: 0xd4a843) }
        if model.contains("sonnet") { return Color(hex: 0x6699cc) }
        if model.contains("haiku") { return Color(hex: 0x66cc99) }
        return Color.gray
    }

    private func shortModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }
}
