import SwiftUI
import AppKit

/// Menu bar label — shows the user's token count directly in the menu bar.
/// White when idle. When tokens are streaming, cycles through warm amber/gold
/// shades at 150ms intervals (timer-driven, not SwiftUI animation — proven
/// reliable in MenuBarExtra context, same pattern as Parrot app).
struct MenuBarIcon: View {
    @ObservedObject var state: MenuBarState

    var body: some View {
        let color = state.isStreaming
            ? Self.streamingColors[state.colorPhase % Self.streamingColors.count]
            : Self.idleColor
        Image(nsImage: Self.renderText(formatMenuBarTokens(state.displayTokens), color: color))
    }

    // MARK: - Colors

    /// Warm golden shimmer palette — cycles through these when streaming.
    /// Goes from deep amber → bright gold → warm white → back, creating a "glowing" effect.
    private static let streamingColors: [NSColor] = [
        NSColor(srgbRed: 180/255.0, green: 140/255.0, blue: 50/255.0, alpha: 1),   // deep amber
        NSColor(srgbRed: 212/255.0, green: 168/255.0, blue: 67/255.0, alpha: 1),   // classic amber
        NSColor(srgbRed: 235/255.0, green: 195/255.0, blue: 85/255.0, alpha: 1),   // bright gold
        NSColor(srgbRed: 250/255.0, green: 220/255.0, blue: 130/255.0, alpha: 1),  // warm highlight
        NSColor(srgbRed: 235/255.0, green: 195/255.0, blue: 85/255.0, alpha: 1),   // bright gold
        NSColor(srgbRed: 212/255.0, green: 168/255.0, blue: 67/255.0, alpha: 1),   // classic amber
    ]

    private static let idleColor = NSColor(srgbRed: 0.92, green: 0.92, blue: 0.92, alpha: 1)
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)

    // MARK: - Rendering

    private static func renderText(_ text: String, color: NSColor) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color
        ]
        let attrStr = NSAttributedString(string: text, attributes: attrs)
        let size = attrStr.size()
        let imageSize = NSSize(width: ceil(size.width) + 2, height: ceil(size.height))

        let image = NSImage(size: imageSize, flipped: false) { _ in
            attrStr.draw(at: NSPoint(x: 1, y: 0))
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Format token count for menu bar display — 2 decimal places, compact suffix.
func formatMenuBarTokens(_ count: Int) -> String {
    switch count {
    case 0..<1_000:
        return "\(count)"
    case 1_000..<1_000_000:
        return String(format: "%.2fK", Double(count) / 1_000.0)
    case 1_000_000..<1_000_000_000:
        return String(format: "%.2fM", Double(count) / 1_000_000.0)
    default:
        return String(format: "%.2fB", Double(count) / 1_000_000_000.0)
    }
}
