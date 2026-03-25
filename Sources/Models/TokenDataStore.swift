import Foundation
import os
import SwiftUI

/// The central data store for TokenBox. Published properties drive the UI.
/// Consumed by the app shell via @EnvironmentObject.
@MainActor
class TokenDataStore: ObservableObject {

    private let logger = Logger(subsystem: "com.tokenbox.app", category: "DataStore")

    // MARK: - Published Properties

    @Published var todayTokens: Int = 0
    @Published var todayCost: Double? = nil
    @Published var weekTokens: Int = 0
    @Published var monthTokens: Int = 0
    @Published var allTimeTokens: Int = 0
    @Published var sessionCountToday: Int = 0
    @Published var topModel: String = ""
    @Published var cacheEfficiency: Double = 0.0
    @Published var dailyHistory: [(date: String, tokens: Int)] = []
    @Published var modelBreakdown: [(model: String, tokens: Int)] = []
    @Published var todayByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = []
    @Published var weekByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = []
    @Published var monthByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = []
    @Published var allTimeByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = []
    @Published var topProjects: [(name: String, tokens: Int)] = []
    @Published var isLive: Bool = false

    /// Model filter for display — matches as substring (e.g. "opus" matches all Opus variants).
    /// Default "opus". Set to nil to show all models.
    @Published var modelFilter: String? = UserDefaults.standard.string(forKey: "modelFilter") ?? "opus" {
        didSet {
            UserDefaults.standard.set(modelFilter, forKey: "modelFilter")
            refresh()
            NotificationCenter.default.post(name: .displaySettingsDidChange, object: nil)
        }
    }

    /// Last time refresh() ran — used for "As of X" display
    @Published var lastRefreshDate: Date = Date()

    /// Delta from intermediate streaming events not yet absorbed by a DB refresh.
    /// Display shows: todayTokens + realtimeDelta for real-time flipping.
    /// Reset to 0 on each refresh() when completed events are committed to DB.
    @Published var realtimeDelta: Int = 0

    /// Computed display value: accurate DB total + live intermediate delta
    var realtimeDisplayTokens: Int {
        todayTokens + realtimeDelta
    }

    // MARK: - Dependencies

    private let db: Database
    private let pricingService: PricingService
    private let jsonlWatcher: JSONLWatcher
    private let liveWatcher: LiveFileWatcher
    private let aggregator: DataAggregator
    private var liveTimeoutTask: Task<Void, Never>?
    private var debouncedRefreshWork: DispatchWorkItem?
    private var periodicRefreshTimer: Timer?
    private var lastRefreshPSTDate: String = ""

    // MARK: - Init

    init(db: Database? = nil) {
        let database: Database
        if let db = db {
            database = db
        } else {
            do {
                database = try Database(path: Database.defaultPath)
            } catch {
                Logger(subsystem: "com.tokenbox.app", category: "DataStore")
                    .error("Failed to open database at default path: \(error.localizedDescription). Falling back to in-memory database.")
                do {
                    database = try Database()
                } catch {
                    fatalError("TokenDataStore: cannot create even an in-memory database: \(error)")
                }
            }
        }

        self.db = database
        self.pricingService = PricingService()
        self.jsonlWatcher = JSONLWatcher(db: database)
        self.liveWatcher = LiveFileWatcher()
        self.aggregator = DataAggregator(db: database)

        setupCallbacks()
    }

    /// Init with explicit dependencies (for testing).
    init(db: Database, pricingService: PricingService, jsonlWatcher: JSONLWatcher, liveWatcher: LiveFileWatcher) {
        self.db = db
        self.pricingService = pricingService
        self.jsonlWatcher = jsonlWatcher
        self.liveWatcher = liveWatcher
        self.aggregator = DataAggregator(db: db)

        setupCallbacks()
    }

    // MARK: - Public API

    func startWatching() {
        jsonlWatcher.start()
        liveWatcher.start()
        refresh()
        startPeriodicRefresh()
    }

    func stopWatching() {
        jsonlWatcher.stop()
        liveWatcher.stop()
        liveTimeoutTask?.cancel()
        periodicRefreshTimer?.invalidate()
        periodicRefreshTimer = nil
    }

    func refresh() {
        // Track PST date for day boundary detection
        let pstFormatter = DateFormatter()
        pstFormatter.dateFormat = "yyyy-MM-dd"
        pstFormatter.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        lastRefreshPSTDate = pstFormatter.string(from: Date())

        // Reset intermediate delta — DB totals now include completed events
        realtimeDelta = 0

        let calendar = Calendar.current
        let now = Date()
        let isoFormatter = ISO8601DateFormatter()

        // Compute local day boundaries, then convert to UTC for DB queries.
        // "Today" means the user's local calendar day, not UTC day.
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let startOfTodayStr = isoFormatter.string(from: startOfToday)
        let endOfTodayStr = isoFormatter.string(from: startOfTomorrow)

        // Track the last refresh time for display
        lastRefreshDate = now

        // Week start (Monday in user's locale)
        let weekStart = calendar.date(from: calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)) ?? now
        let weekStartStr = isoFormatter.string(from: weekStart)

        // Month start
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let monthStartStr = isoFormatter.string(from: monthStart)

        let endStr = isoFormatter.string(from: now)

        // 30 days ago for history (local dates for daily_summary)
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let todayLocalStr = dateFormatter.string(from: now)
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now) ?? now
        let thirtyDaysAgoStr = dateFormatter.string(from: thirtyDaysAgo)

        do {
            // Token counts — output only, filtered by selected model
            todayTokens = try db.totalTokens(from: startOfTodayStr, to: endOfTodayStr, modelFilter: modelFilter)
            weekTokens = try db.totalTokens(from: weekStartStr, to: endStr, modelFilter: modelFilter)
            monthTokens = try db.totalTokens(from: monthStartStr, to: endStr, modelFilter: modelFilter)
            allTimeTokens = try db.totalTokens(modelFilter: modelFilter)

            // Per-model breakdowns for each period (unfiltered — used by sharing)
            todayByModel = try db.tokensByModel(from: startOfTodayStr, to: endOfTodayStr)
            weekByModel = try db.tokensByModel(from: weekStartStr, to: endStr)
            monthByModel = try db.tokensByModel(from: monthStartStr, to: endStr)
            allTimeByModel = try db.tokensByModel()

            // Session count
            sessionCountToday = try db.sessionCount(from: startOfTodayStr, to: endOfTodayStr)

            // Model breakdown
            let breakdown = try db.modelBreakdown(from: startOfTodayStr, to: endOfTodayStr)
            modelBreakdown = breakdown
            topModel = breakdown.first?.model ?? ""

            // Cache efficiency
            cacheEfficiency = try db.cacheEfficiency(from: startOfTodayStr, to: endOfTodayStr)

            // Top projects
            topProjects = try db.topProjects(from: startOfTodayStr, to: endOfTodayStr)

            // Cost estimate for today
            let todayEvents = try db.queryTokenEvents(from: startOfTodayStr, to: endOfTodayStr)
            var totalCost: Double = 0
            var hasCost = false
            for event in todayEvents {
                if let cost = event.costUsd {
                    totalCost += cost
                    hasCost = true
                } else if let estimated = pricingService.estimateCost(for: event) {
                    totalCost += estimated
                    hasCost = true
                }
            }
            todayCost = hasCost ? totalCost : nil

            // Daily history (from daily_summary for performance)
            try aggregator.rollupDate(todayLocalStr)
            dailyHistory = try db.dailyHistory(from: thirtyDaysAgoStr, to: todayLocalStr)
        } catch {
            // Log but don't crash
            logger.error("Refresh error: \(error.localizedDescription)")
        }
    }

    /// Debounced refresh — coalesces rapid calls (e.g. from streaming events) into one
    /// refresh after 500ms of quiet. Non-live callers should use refresh() directly.
    private func debouncedRefresh() {
        debouncedRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refresh()
            }
        }
        debouncedRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // MARK: - Periodic Refresh

    private func startPeriodicRefresh() {
        // Check every 60 seconds if the PST day has changed
        periodicRefreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDayBoundary()
            }
        }
        // Also refresh on app becoming active (handles macOS app suspension)
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.checkDayBoundary()
            }
        }
    }

    private func checkDayBoundary() {
        let pst = TimeZone(identifier: "America/Los_Angeles")!
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = pst
        let currentPSTDate = formatter.string(from: Date())

        if currentPSTDate != lastRefreshPSTDate {
            lastRefreshPSTDate = currentPSTDate
            refresh()
        }
    }

    // MARK: - Private

    private func setupCallbacks() {
        jsonlWatcher.onEventsIngested = { [weak self] _ in
            Task { @MainActor in
                self?.debouncedRefresh()
            }
        }

        // Real-time display: accumulate intermediate events as a delta on top of DB totals
        jsonlWatcher.onDisplayEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                // Only accumulate delta for the selected model filter
                if let filter = self.modelFilter {
                    guard event.model.lowercased().contains(filter.lowercased()) else { return }
                }
                self.realtimeDelta += event.outputTokens
            }
        }

        liveWatcher.onLiveEvent = { [weak self] event in
            Task { @MainActor in
                self?.handleLiveEvent(event)
            }
        }

    }

    private func handleLiveEvent(_ event: LiveEvent) {
        isLive = true

        // Feed real-time display delta — only for selected model
        let matchesFilter: Bool
        if let filter = modelFilter {
            matchesFilter = event.model.lowercased().contains(filter.lowercased())
        } else {
            matchesFilter = true
        }
        if matchesFilter {
            realtimeDelta += event.out
        }

        // Reset live timeout — mark as not live after 30s of inactivity
        liveTimeoutTask?.cancel()
        liveTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if !Task.isCancelled {
                self.isLive = false
            }
        }

        // Insert the live event into the database
        let tokenEvent = TokenEvent(
            timestamp: event.ts,
            source: "claude_code",
            sessionId: event.sid,
            project: nil,
            model: event.model,
            inputTokens: event.in,
            outputTokens: event.out,
            cacheCreate: event.cw,
            cacheRead: event.cr,
            costUsd: event.cost > 0 ? event.cost : nil
        )

        do {
            try db.insertTokenEvent(tokenEvent)
        } catch {
            // Dedup conflict is expected
        }

        debouncedRefresh()
    }
}
