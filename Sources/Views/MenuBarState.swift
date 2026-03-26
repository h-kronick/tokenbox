import Foundation
import Combine

/// Standalone observable that polls TokenDataStore for the menu bar.
/// Owns its own GCD timer so it works reliably inside MenuBarExtra,
/// where @EnvironmentObject and Timer.publish don't propagate updates.
@MainActor
final class MenuBarState: ObservableObject {
    @Published var todayTokens: Int = 0
    @Published var todayCost: Double? = nil
    @Published var isLive: Bool = false
    @Published var tokenDelta: Int = 0

    /// The token count for the currently pinned period (with realtime updates for "today")
    @Published var displayTokens: Int = 0

    /// Label for the pinned period
    @Published var displayLabel: String = "today"

    /// Whether tokens are actively changing — more robust than isLive.
    /// True when displayTokens changed within the last 3 seconds.
    @Published var isStreaming: Bool = false

    /// Color phase for menu bar shimmer animation — cycles 0..<colorCount when streaming.
    /// Driven by a separate fast timer (150ms) to create smooth color cycling.
    @Published var colorPhase: Int = 0
    static let colorCount = 6

    private weak var dataStore: TokenDataStore?
    private weak var sharingManager: SharingManager?
    private var timer: DispatchSourceTimer?
    private var colorTimer: DispatchSourceTimer?
    private var lastKnownTokens: Int = 0
    private var lastChangeTime: Date = .distantPast

    init(dataStore: TokenDataStore, sharingManager: SharingManager? = nil) {
        self.dataStore = dataStore
        self.sharingManager = sharingManager
        startPolling()
    }

    private func startPolling() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(500))
        t.setEventHandler { [weak self] in
            self?.poll()
        }
        t.resume()
        timer = t
    }

    private func poll() {
        guard let ds = dataStore else { return }
        todayTokens = ds.todayTokens
        todayCost = ds.todayCost
        isLive = ds.isLive
        tokenDelta = ds.realtimeDelta

        let pinned = UserDefaults.standard.string(forKey: "pinnedDisplay") ?? "today"
        displayLabel = pinned

        let newTokens: Int
        // Use server aggregate when devices are linked (matches main display behavior)
        if let sm = sharingManager, sm.hasServerAggregate,
           let aggTokens = sm.aggregateTokens(for: ds.modelFilter, period: pinned) {
            switch pinned {
            case "today":
                newTokens = aggTokens + ds.realtimeDelta
            default:
                newTokens = aggTokens
            }
        } else {
            switch pinned {
            case "week":
                newTokens = ds.weekTokens
            case "month":
                newTokens = ds.monthTokens
            case "allTime":
                newTokens = ds.allTimeTokens
            default:
                newTokens = ds.realtimeDisplayTokens
            }
        }

        if newTokens != lastKnownTokens {
            lastKnownTokens = newTokens
            lastChangeTime = Date()
        }
        displayTokens = newTokens

        // Streaming = tokens changed within the last 3 seconds
        let wasStreaming = isStreaming
        isStreaming = Date().timeIntervalSince(lastChangeTime) < 3.0

        if isStreaming && !wasStreaming {
            startColorCycle()
        } else if !isStreaming && wasStreaming {
            stopColorCycle()
        }
    }

    private func startColorCycle() {
        guard colorTimer == nil else { return }
        colorPhase = 0
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: .milliseconds(150))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.colorPhase = (self.colorPhase + 1) % Self.colorCount
        }
        t.resume()
        colorTimer = t
    }

    private func stopColorCycle() {
        guard colorTimer != nil else { return }
        colorTimer?.cancel()
        colorTimer = nil
        colorPhase = 0
    }

    deinit {
        timer?.cancel()
        colorTimer?.cancel()
    }
}
