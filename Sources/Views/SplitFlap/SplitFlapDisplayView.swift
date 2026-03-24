import Combine
import SwiftUI

/// The complete split-flap display with four rows.
/// This is the public API consumed by the App Shell (Teammate 3).
///
/// - Row 1 (top): Pinned label (e-ink panel, e.g. "TODAY") — 57% width, centered
/// - Row 2: Pinned token counter (7 split-flap modules) — full width
/// - Row 3: Rotating context label (e-ink panel, centered) — 57% width, centered
/// - Row 4 (bottom): Rotating context value (7 split-flap modules) — full width
///
/// Proportions match the physical device: 2.9" e-ink (67mm) above 7×15mm modules (117mm).
struct SplitFlapDisplayView: View {
    @Binding var pinnedLabel: String
    @Binding var pinnedValue: String
    @Binding var contextLabel: String
    @Binding var contextValue: String
    var contextSubtitle: String? = nil
    var modelName: String = "Opus"

    var theme: SplitFlapTheme = .classicAmber
    var soundEnabled: Bool = true
    var animationSpeed: Double = 1.0

    /// Physical proportions: e-ink active width (67mm) / flap row width (117mm)
    private let einkWidthRatio: CGFloat = 0.57

    @State private var showInfo = false
    @State private var now = Date()

    /// Timer that fires every 60s to keep the "Resets in" countdown current
    private let minuteTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    /// Uniform character set (used as fallback for SplitFlapRow's required parameter).
    private var flapCharacterSet: [Character] {
        SplitFlapModule.digitCharacterSet + ["K", "M", "B", "T"]
    }

    /// Per-position character sets for token rows, tuned to what each flap actually shows.
    private var tokenPerPositionSets: [[Character]] {
        let digitOnly: [Character] = [" "] + (0...9).map { Character(String($0)) }
        let dotOnly: [Character] = [" ", "."]
        let suffixFlap: [Character] = digitOnly + ["K", "M", "B", "T"]
        return [
            digitOnly,  // pos 0
            digitOnly,  // pos 1
            digitOnly,  // pos 2
            dotOnly,    // pos 3
            digitOnly,  // pos 4
            digitOnly,  // pos 5
            suffixFlap, // pos 6
        ]
    }

    var body: some View {
        SplitFlapHousing(theme: theme) {
            VStack(spacing: 6) {
                // Row 1: Pinned label (e-ink panel with model + reset subtitle)
                ZStack(alignment: .topTrailing) {
                    EInkLabelView(
                        text: pinnedLabel,
                        subtitleLeft: modelName,
                        subtitleRight: resetsInString,
                        theme: theme
                    )
                    .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 52)
                    .padding(.horizontal, horizontalInset)

                    // Info button overlay
                    Button {
                        showInfo.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 8))
                            .foregroundColor(theme.labelColor.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 0, y: -2)
                    .popover(isPresented: $showInfo, arrowEdge: .top) {
                        infoPopover
                    }
                }

                // Row 2: Pinned token counter (7 split-flap modules)
                SplitFlapRow(
                    text: padTokenString(pinnedValue),
                    characterSet: flapCharacterSet,
                    moduleCount: 7,
                    perPositionSets: tokenPerPositionSets,
                    theme: theme,
                    animationSpeed: animationSpeed,
                    soundEnabled: soundEnabled
                )
                .frame(height: 50)

                Spacer().frame(height: 2)

                // Row 3: Rotating context label (e-ink panel, centered)
                EInkLabelView(
                    text: contextLabel,
                    subtitleRight: contextSubtitle,
                    theme: theme
                )
                .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                .padding(.horizontal, horizontalInset)

                // Row 4: Rotating context value (7 split-flap modules)
                SplitFlapRow(
                    text: padTokenString(contextValue),
                    characterSet: flapCharacterSet,
                    moduleCount: 7,
                    perPositionSets: tokenPerPositionSets,
                    theme: theme,
                    animationSpeed: animationSpeed,
                    soundEnabled: soundEnabled
                )
                .frame(height: 50)
            }
        }
        .onReceive(minuteTimer) { now = $0 }
        .onAppear { now = Date() }
    }

    /// Horizontal inset to make e-ink panels ~57% of flap row width, centered
    private var horizontalInset: CGFloat {
        // Each side gets (1 - 0.57) / 2 = 0.215 of the total width
        // With 16pt housing padding already applied, we need additional inset
        // relative to the content area. Approximate with fixed value.
        56
    }

    // MARK: - Info Popover

    private var infoPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's shown")
                .font(.system(size: 12, weight: .semibold))
            Text("Output tokens generated by Claude (\(modelName) model). Input tokens, cache reads, and cache writes are excluded from this count.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Divider()

            Text("How tracking works")
                .font(.system(size: 12, weight: .semibold))
            Text("TokenBox reads Claude Code session logs from ~/.claude/projects/ and backfills all history automatically. Real-time updates come from the status hook.\n\nCounts start from when Claude Code was first used on this machine — not from when TokenBox was installed.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)

            Divider()

            Text("Not tracked")
                .font(.system(size: 12, weight: .semibold))
            Text("• Direct API usage\n• Claude.ai web chat usage\n• Usage on other machines")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(12)
        .frame(width: 280)
    }

    // MARK: - Computed Properties

    /// Compact time remaining until midnight (daily token reset).
    /// Short format for e-ink subtitle: "11h 46m", "46m", "<1m"
    private var resetsInString: String {
        let calendar = Calendar.current
        guard let midnight = calendar.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0, second: 0), matchingPolicy: .nextTime) else {
            return "0:00"
        }
        let total = Int(midnight.timeIntervalSince(now))
        let h = total / 3600
        let m = (total % 3600) / 60
        if total < 60 {
            return "resets in <1m"
        } else if h == 0 {
            return "resets in \(m)m"
        }
        return "resets in \(h)h \(m)m"
    }

    /// Pad or truncate a token string to 7 characters.
    private func padTokenString(_ str: String) -> String {
        let s = str.prefix(7)
        return s.count < 7
            ? s + String(repeating: " ", count: 7 - s.count)
            : String(s)
    }

    /// Pad or truncate an alpha label to 7 characters, centered (e.g. " MONTH ").
    private func padAlphaString(_ str: String) -> String {
        let s = String(str.uppercased().prefix(7))
        guard s.count < 7 else { return s }
        let totalPad = 7 - s.count
        let leftPad = totalPad / 2
        let rightPad = totalPad - leftPad
        return String(repeating: " ", count: leftPad) + s + String(repeating: " ", count: rightPad)
    }
}
