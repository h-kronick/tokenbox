import SwiftUI
import Combine

/// Tracks which time period the display is showing.
enum TimePeriod: String, CaseIterable, Identifiable {
    case today = "Today"
    case week = "Week"
    case month = "Month"
    case allTime = "All Time"

    var id: String { rawValue }
}

/// Represents what the context panel (rows 2+3) is currently displaying.
struct ContextItem: Identifiable {
    let id = UUID()
    let label: String  // Row 2: up to 6 chars (centered by display)
    let value: String  // Row 3: up to 6 chars (e.g. "84.70K")
    var subtitle: String? = nil  // Optional e-ink subtitle (e.g. "3m ago")
}

/// App-wide state management.
@MainActor
final class AppState: ObservableObject {
    @Published var selectedPeriod: TimePeriod = .today
    @Published var isDashboardOpen: Bool = false
    @Published var currentContextIndex: Int = 0
    @Published var contextItems: [ContextItem] = []

    // Pinned top row: label + token count shown above the main display
    @Published var pinnedLabel: String = "TODAY"
    @Published var pinnedValue: String = "     0 "

    /// Which period is pinned to the top label row. Persisted in UserDefaults but
    /// always resets to "today" on launch (see init).
    /// Uses @Published (not @AppStorage) so that onChange in MainWindowView fires
    /// reliably when Settings updates this value from a separate window.
    @Published var pinnedDisplay: String = "today" {
        didSet {
            UserDefaults.standard.set(pinnedDisplay, forKey: "pinnedDisplay")
            NotificationCenter.default.post(name: .displaySettingsDidChange, object: nil)
        }
    }

    // Display strings driven by context rotation
    @Published var displayLabel: String = "WEEK"
    @Published var displayValue: String = "     0 "
    @Published var displaySubtitle: String? = nil

    /// When true, the main counter shows a running total updated with every streaming
    /// event for real-time split-flap flipping. Default ON — designed for both digital
    /// and physical displays (physical will catch up at its own mechanical speed).
    @AppStorage("realtimeFlipDisplay") var realtimeFlipDisplay: Bool = true

    private var rotationTimer: AnyCancellable?
    private let rotationInterval: TimeInterval = 15.0

    init() {
        // Start on the user's chosen default period (defaults to "today")
        let defaultPeriod = UserDefaults.standard.string(forKey: "defaultPeriod") ?? "today"
        pinnedDisplay = defaultPeriod
    }

    /// Weak references to data sources — set once by MainWindowView on appear.
    /// Allows the rotation timer to rebuild context items directly.
    weak var dataStore: TokenDataStore?
    weak var sharingManager: SharingManager?
    /// Closure that builds the friends list with proper model filter + self-detection.
    var buildFriendsList: (() -> [(name: String, tokens: String, lastTokenChange: String?)])?

    func startContextRotation() {
        rotationTimer?.cancel()
        rotationTimer = Timer.publish(every: rotationInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.rebuildAndAdvance()
            }
    }

    func stopContextRotation() {
        rotationTimer?.cancel()
    }

    /// Restart the rotation timer from now (e.g. after jumping to a new friend).
    private func restartRotationTimer() {
        rotationTimer?.cancel()
        rotationTimer = Timer.publish(every: rotationInterval, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.rebuildAndAdvance()
            }
    }

    /// Called every rotation tick — rebuilds items from live data then advances.
    private func rebuildAndAdvance() {
        let friends: [(name: String, tokens: String, lastTokenChange: String?)] = buildFriendsList?() ?? []
        updateContextItems(friends: friends, dataStore: dataStore)
        advanceContext()
    }

    func updateContextItems(friends: [(name: String, tokens: String, lastTokenChange: String?)], dataStore: TokenDataStore?) {
        var items: [ContextItem] = []

        // Update pinned top row
        updatePinnedDisplay(dataStore: dataStore)

        if !friends.isEmpty {
            // Sharing mode: only show friends — your data is already on the top row
            for friend in friends {
                let sub = friend.lastTokenChange.flatMap { Self.compactRelativeTime(from: $0) }
                items.append(ContextItem(label: friend.name, value: friend.tokens, subtitle: sub))
            }
        } else {
            // Default: rotate through WEEK, MONTH, TOTAL — skip the pinned one
            let weekStr = formatTokens(dataStore?.weekTokens ?? 0)
            let monthStr = formatTokens(dataStore?.monthTokens ?? 0)
            let totalStr = formatTokens(dataStore?.allTimeTokens ?? 0)

            if pinnedDisplay != "today" {
                let todayStr = formatTokens(dataStore?.todayTokens ?? 0)
                items.append(ContextItem(label: "TODAY", value: todayStr))
            }
            if pinnedDisplay != "week" {
                items.append(ContextItem(label: "WEEK", value: weekStr))
            }
            if pinnedDisplay != "month" {
                items.append(ContextItem(label: "MONTH", value: monthStr))
            }
            if pinnedDisplay != "allTime" {
                items.append(ContextItem(label: "TOTAL", value: totalStr))
            }
        }

        let previousCount = contextItems.count
        contextItems = items

        if items.count > previousCount {
            // New item added — jump to it immediately and restart rotation
            currentContextIndex = items.count - 1
            restartRotationTimer()
        } else if currentContextIndex >= items.count {
            currentContextIndex = 0
        }

        // Update the display
        if !contextItems.isEmpty, currentContextIndex < contextItems.count {
            let item = contextItems[currentContextIndex]
            displayLabel = item.label
            displayValue = item.value
            displaySubtitle = item.subtitle
        }

    }

    private func updatePinnedDisplay(dataStore: TokenDataStore?) {
        guard let store = dataStore else { return }
        switch pinnedDisplay {
        case "today":
            pinnedLabel = "TODAY"
            let tokens = realtimeFlipDisplay ? store.realtimeDisplayTokens : store.todayTokens
            pinnedValue = formatTokens(tokens)
        case "week":
            pinnedLabel = "WEEK"
            pinnedValue = formatTokens(store.weekTokens)
        case "month":
            pinnedLabel = "MONTH"
            pinnedValue = formatTokens(store.monthTokens)
        case "allTime":
            pinnedLabel = "TOTAL"
            pinnedValue = formatTokens(store.allTimeTokens)
        default:
            pinnedLabel = "TODAY"
            let tokens = realtimeFlipDisplay ? store.realtimeDisplayTokens : store.todayTokens
            pinnedValue = formatTokens(tokens)
        }
    }

    private func advanceContext() {
        guard !contextItems.isEmpty else { return }
        currentContextIndex = (currentContextIndex + 1) % contextItems.count
        let item = contextItems[currentContextIndex]
        displayLabel = item.label
        displayValue = item.value
        displaySubtitle = item.subtitle
    }

    /// Only update pinned row values — called from data refreshes without rebuilding context items.
    func refreshPinnedDisplay(dataStore: TokenDataStore?) {
        updatePinnedDisplay(dataStore: dataStore)
    }

    /// Compact relative time for e-ink subtitle: "3s ago", "5m ago", "2h ago", "1d ago"
    static func compactRelativeTime(from iso: String) -> String? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = fmt.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return nil
        }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 0 { return "now" }
        if seconds < 60 { return "\(seconds)s ago" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        return "\(days)d ago"
    }
}

// MARK: - Formatting

/// Format token count for the 6-module split-flap display.
/// All outputs are exactly 6 characters, right-aligned, space-padded.
/// Uses adaptive decimal precision: 2 decimals when it fits, 1 when it doesn't.
///
/// Examples:
///   42      → "    42"     (raw number)
///   999     → "   999"     (raw number)
///   1000    → " 1.00K"     (2 decimals, fits in 6)
///   84700   → "84.70K"     (2 decimals, exactly 6)
///   101230  → "101.2K"     (1 decimal, 3-digit integer part)
///   999000  → "999.0K"     (1 decimal)
///   2145000 → " 2.15M"     (2 decimals, fits in 6)
func formatTokens(_ count: Int) -> String {
    let raw: String
    switch count {
    case 0..<1_000:
        raw = "\(count)"
    case 1_000..<99_995:
        raw = String(format: "%.2fK", Double(count) / 1_000.0)
    case 99_995..<999_950:
        raw = String(format: "%.1fK", Double(count) / 1_000.0)
    case 999_950..<99_995_000:
        raw = String(format: "%.2fM", Double(count) / 1_000_000.0)
    case 99_995_000..<999_950_000:
        raw = String(format: "%.1fM", Double(count) / 1_000_000.0)
    case 999_950_000..<99_995_000_000:
        raw = String(format: "%.2fB", Double(count) / 1_000_000_000.0)
    default:
        raw = String(format: "%.1fB", Double(count) / 1_000_000_000.0)
    }
    // Right-align to 6 characters, leading spaces for blank flaps
    if raw.count < 6 {
        return String(repeating: " ", count: 6 - raw.count) + raw
    }
    return String(raw.prefix(6))
}

func formatModelShort(_ model: String) -> String {
    if model.contains("opus") { return "OPUS" }
    if model.contains("sonnet") { return "SONNET" }
    if model.contains("haiku") { return "HAIKU" }
    return String(model.prefix(6)).uppercased()
}

func formatCompactTokens(_ count: Int) -> String {
    switch count {
    case 0..<1_000:
        return "\(count)"
    case 1_000..<1_000_000:
        return String(format: "%.1fK", Double(count) / 1_000.0)
    case 1_000_000..<1_000_000_000:
        return String(format: "%.1fM", Double(count) / 1_000_000.0)
    default:
        return String(format: "%.1fB", Double(count) / 1_000_000_000.0)
    }
}
