import Foundation
@preconcurrency import SQLite

/// SQLite database layer for TokenBox.
/// Database location: ~/Library/Application Support/TokenBox/tokenbox.db
final class Database: Sendable {

    let db: Connection

    // MARK: - Table definitions

    // token_events
    static let tokenEvents = Table("token_events")
    static let teId = SQLite.Expression<Int64>("id")
    static let teTimestamp = SQLite.Expression<String>("timestamp")
    static let teSource = SQLite.Expression<String>("source")
    static let teSessionId = SQLite.Expression<String?>("session_id")
    static let teProject = SQLite.Expression<String?>("project")
    static let teModel = SQLite.Expression<String>("model")
    static let teInputTokens = SQLite.Expression<Int>("input_tokens")
    static let teOutputTokens = SQLite.Expression<Int>("output_tokens")
    static let teCacheCreate = SQLite.Expression<Int>("cache_create")
    static let teCacheRead = SQLite.Expression<Int>("cache_read")
    static let teCostUsd = SQLite.Expression<Double?>("cost_usd")

    // daily_summary
    static let dailySummary = Table("daily_summary")
    static let dsDate = SQLite.Expression<String>("date")
    static let dsSource = SQLite.Expression<String>("source")
    static let dsModel = SQLite.Expression<String>("model")
    static let dsTotalInput = SQLite.Expression<Int>("total_input")
    static let dsTotalOutput = SQLite.Expression<Int>("total_output")
    static let dsTotalCacheR = SQLite.Expression<Int>("total_cache_r")
    static let dsTotalCacheW = SQLite.Expression<Int>("total_cache_w")
    static let dsTotalCost = SQLite.Expression<Double?>("total_cost")
    static let dsSessionCount = SQLite.Expression<Int>("session_count")

    // friends
    static let friends = Table("friends")
    static let fFriendId = SQLite.Expression<String>("friend_id")
    static let fDisplayName = SQLite.Expression<String>("display_name")
    static let fPublicKey = SQLite.Expression<String>("public_key")
    static let fFirstSeen = SQLite.Expression<String>("first_seen")
    static let fLastUpdated = SQLite.Expression<String>("last_updated")

    // friend_snapshots
    static let friendSnapshots = Table("friend_snapshots")
    static let fsId = SQLite.Expression<Int64>("id")
    static let fsFriendId = SQLite.Expression<String>("friend_id")
    static let fsSnapshotDate = SQLite.Expression<String>("snapshot_date")
    static let fsPeriodFrom = SQLite.Expression<String>("period_from")
    static let fsPeriodTo = SQLite.Expression<String>("period_to")
    static let fsTotalTokens = SQLite.Expression<Int>("total_tokens")
    static let fsCostEstimate = SQLite.Expression<Double?>("cost_estimate")
    static let fsByModel = SQLite.Expression<String?>("by_model")
    static let fsDailyAvg = SQLite.Expression<Int?>("daily_avg")
    static let fsPeakTokens = SQLite.Expression<Int?>("peak_tokens")
    static let fsCacheEfficiency = SQLite.Expression<Double?>("cache_efficiency")
    static let fsSignature = SQLite.Expression<String>("signature")

    // config
    static let config = Table("config")
    static let cfgKey = SQLite.Expression<String>("key")
    static let cfgValue = SQLite.Expression<String>("value")

    // MARK: - Init

    /// Initialize with a file path. Pass nil or ":memory:" for in-memory database (testing).
    init(path: String? = nil) throws {
        if let path = path, path != ":memory:" {
            let dir = (path as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            db = try Connection(path)
        } else {
            db = try Connection(.inMemory)
        }
        db.busyTimeout = 5
        try createTables()
    }

    /// Default production database path
    static var defaultPath: String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("TokenBox/tokenbox.db").path
    }

    // MARK: - Schema

    private func createTables() throws {
        try db.run(Self.tokenEvents.create(ifNotExists: true) { t in
            t.column(Self.teId, primaryKey: .autoincrement)
            t.column(Self.teTimestamp)
            t.column(Self.teSource)
            t.column(Self.teSessionId)
            t.column(Self.teProject)
            t.column(Self.teModel)
            t.column(Self.teInputTokens, defaultValue: 0)
            t.column(Self.teOutputTokens, defaultValue: 0)
            t.column(Self.teCacheCreate, defaultValue: 0)
            t.column(Self.teCacheRead, defaultValue: 0)
            t.column(Self.teCostUsd)
            t.unique(Self.teTimestamp, Self.teSessionId, Self.teModel)
        })

        try db.run(Self.dailySummary.create(ifNotExists: true) { t in
            t.column(Self.dsDate)
            t.column(Self.dsSource)
            t.column(Self.dsModel)
            t.column(Self.dsTotalInput, defaultValue: 0)
            t.column(Self.dsTotalOutput, defaultValue: 0)
            t.column(Self.dsTotalCacheR, defaultValue: 0)
            t.column(Self.dsTotalCacheW, defaultValue: 0)
            t.column(Self.dsTotalCost)
            t.column(Self.dsSessionCount, defaultValue: 0)
            t.primaryKey(Self.dsDate, Self.dsSource, Self.dsModel)
        })

        try db.run(Self.friends.create(ifNotExists: true) { t in
            t.column(Self.fFriendId, primaryKey: true)
            t.column(Self.fDisplayName)
            t.column(Self.fPublicKey)
            t.column(Self.fFirstSeen)
            t.column(Self.fLastUpdated)
        })

        try db.run(Self.friendSnapshots.create(ifNotExists: true) { t in
            t.column(Self.fsId, primaryKey: .autoincrement)
            t.column(Self.fsFriendId)
            t.column(Self.fsSnapshotDate)
            t.column(Self.fsPeriodFrom)
            t.column(Self.fsPeriodTo)
            t.column(Self.fsTotalTokens)
            t.column(Self.fsCostEstimate)
            t.column(Self.fsByModel)
            t.column(Self.fsDailyAvg)
            t.column(Self.fsPeakTokens)
            t.column(Self.fsCacheEfficiency)
            t.column(Self.fsSignature)
            t.unique(Self.fsFriendId, Self.fsSnapshotDate)
        })

        try db.run(Self.config.create(ifNotExists: true) { t in
            t.column(Self.cfgKey, primaryKey: true)
            t.column(Self.cfgValue)
        })
    }

    // MARK: - Token Events

    /// Insert a token event. Returns the row ID, or nil if dedup conflict.
    @discardableResult
    func insertTokenEvent(_ event: TokenEvent) throws -> Int64? {
        let changesBefore = db.totalChanges
        let rowId = try db.run(Self.tokenEvents.insert(or: .ignore,
            Self.teTimestamp <- event.timestamp,
            Self.teSource <- event.source,
            Self.teSessionId <- event.sessionId,
            Self.teProject <- event.project,
            Self.teModel <- event.model,
            Self.teInputTokens <- event.inputTokens,
            Self.teOutputTokens <- event.outputTokens,
            Self.teCacheCreate <- event.cacheCreate,
            Self.teCacheRead <- event.cacheRead,
            Self.teCostUsd <- event.costUsd
        ))
        return db.totalChanges > changesBefore ? rowId : nil
    }

    /// Query token events within a date range.
    func queryTokenEvents(from startDate: String? = nil, to endDate: String? = nil, source: String? = nil) throws -> [TokenEvent] {
        var query = Self.tokenEvents.order(Self.teTimestamp.desc)
        if let start = startDate {
            query = query.filter(Self.teTimestamp >= start)
        }
        if let end = endDate {
            query = query.filter(Self.teTimestamp <= end)
        }
        if let src = source {
            query = query.filter(Self.teSource == src)
        }
        return try db.prepare(query).map { row in
            TokenEvent(
                id: row[Self.teId],
                timestamp: row[Self.teTimestamp],
                source: row[Self.teSource],
                sessionId: row[Self.teSessionId],
                project: row[Self.teProject],
                model: row[Self.teModel],
                inputTokens: row[Self.teInputTokens],
                outputTokens: row[Self.teOutputTokens],
                cacheCreate: row[Self.teCacheCreate],
                cacheRead: row[Self.teCacheRead],
                costUsd: row[Self.teCostUsd]
            )
        }
    }

    /// Count output tokens for a date range, optionally filtered by model substring.
    /// e.g. modelFilter "opus" matches "claude-3-opus-20240229", "claude-opus-4-6", etc.
    func totalTokens(from startDate: String? = nil, to endDate: String? = nil, modelFilter: String? = nil) throws -> Int {
        var query = Self.tokenEvents.select(Self.teOutputTokens.sum)
        if let start = startDate {
            query = query.filter(Self.teTimestamp >= start)
        }
        if let end = endDate {
            query = query.filter(Self.teTimestamp <= end)
        }
        if let model = modelFilter {
            // Escape LIKE-special characters so the filter matches literally
            let escaped = model
                .replacingOccurrences(of: "%", with: "\\%")
                .replacingOccurrences(of: "_", with: "\\_")
            query = query.filter(Self.teModel.like("%\(escaped)%", escape: "\\"))
        }
        if let row = try db.pluck(query) {
            return row[Self.teOutputTokens.sum] ?? 0
        }
        return 0
    }

    /// Get token breakdown by model for a date range.
    func tokensByModel(from startDate: String? = nil, to endDate: String? = nil) throws -> [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] {
        var query = Self.tokenEvents.select(
            Self.teModel,
            Self.teOutputTokens.sum,
            Self.teInputTokens.sum,
            Self.teCacheCreate.sum,
            Self.teCacheRead.sum
        ).group(Self.teModel)
        if let start = startDate {
            query = query.filter(Self.teTimestamp >= start)
        }
        if let end = endDate {
            query = query.filter(Self.teTimestamp <= end)
        }
        // Aggregate by model family (opus, sonnet, haiku) to merge variants
        // like "claude-opus-4-6" and "claude-opus-4-6[1m]" into a single "opus" row.
        var familyTotals: [String: (outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = [:]
        for row in try db.prepare(query) {
            let rawModel = row[Self.teModel]
            let family: String
            if rawModel.contains("opus") { family = "opus" }
            else if rawModel.contains("sonnet") { family = "sonnet" }
            else if rawModel.contains("haiku") { family = "haiku" }
            else { family = rawModel }

            let existing = familyTotals[family] ?? (0, 0, 0, 0)
            familyTotals[family] = (
                outputTokens: existing.outputTokens + (row[Self.teOutputTokens.sum] ?? 0),
                inputTokens: existing.inputTokens + (row[Self.teInputTokens.sum] ?? 0),
                cacheRead: existing.cacheRead + (row[Self.teCacheRead.sum] ?? 0),
                cacheCreate: existing.cacheCreate + (row[Self.teCacheCreate.sum] ?? 0)
            )
        }
        return familyTotals.map { (model: $0.key, outputTokens: $0.value.outputTokens, inputTokens: $0.value.inputTokens, cacheRead: $0.value.cacheRead, cacheCreate: $0.value.cacheCreate) }
            .sorted { $0.outputTokens > $1.outputTokens }
    }

    /// Get distinct session count for a date range.
    func sessionCount(from startDate: String, to endDate: String) throws -> Int {
        let sql = "SELECT COUNT(DISTINCT session_id) FROM token_events WHERE timestamp >= ? AND timestamp <= ?"
        let stmt = try db.prepare(sql)
        let result = stmt.bind(startDate, endDate)
        for row in result {
            if let count = row[0] as? Int64 {
                return Int(count)
            }
        }
        return 0
    }

    /// Get model breakdown (model → total tokens) for a date range.
    func modelBreakdown(from startDate: String? = nil, to endDate: String? = nil) throws -> [(model: String, tokens: Int)] {
        var query = Self.tokenEvents
            .select(
                Self.teModel,
                Self.teInputTokens.sum,
                Self.teOutputTokens.sum,
                Self.teCacheCreate.sum,
                Self.teCacheRead.sum
            )
            .group(Self.teModel)
        if let start = startDate {
            query = query.filter(Self.teTimestamp >= start)
        }
        if let end = endDate {
            query = query.filter(Self.teTimestamp <= end)
        }
        return try db.prepare(query).map { row in
            let tokens = (row[Self.teInputTokens.sum] ?? 0) +
                         (row[Self.teOutputTokens.sum] ?? 0) +
                         (row[Self.teCacheCreate.sum] ?? 0) +
                         (row[Self.teCacheRead.sum] ?? 0)
            return (model: row[Self.teModel], tokens: tokens)
        }.sorted { $0.tokens > $1.tokens }
    }

    /// Get top projects by token usage.
    func topProjects(from startDate: String? = nil, to endDate: String? = nil, limit: Int = 10) throws -> [(name: String, tokens: Int)] {
        var query = Self.tokenEvents
            .select(
                Self.teProject,
                Self.teInputTokens.sum,
                Self.teOutputTokens.sum,
                Self.teCacheCreate.sum,
                Self.teCacheRead.sum
            )
            .filter(Self.teProject != nil)
            .group(Self.teProject)
        if let start = startDate {
            query = query.filter(Self.teTimestamp >= start)
        }
        if let end = endDate {
            query = query.filter(Self.teTimestamp <= end)
        }
        return try db.prepare(query).compactMap { row -> (name: String, tokens: Int)? in
            guard let project = row[Self.teProject] else { return nil }
            let tokens = (row[Self.teInputTokens.sum] ?? 0) +
                         (row[Self.teOutputTokens.sum] ?? 0) +
                         (row[Self.teCacheCreate.sum] ?? 0) +
                         (row[Self.teCacheRead.sum] ?? 0)
            return (name: project, tokens: tokens)
        }.sorted { $0.tokens > $1.tokens }
        .prefix(limit).map { $0 }
    }

    // MARK: - Daily Summary

    /// Upsert a daily summary rollup. Uses INSERT OR REPLACE on the composite PK.
    func upsertDailyRollup(_ summary: DailySummary) throws {
        try db.run(Self.dailySummary.insert(or: .replace,
            Self.dsDate <- summary.date,
            Self.dsSource <- summary.source,
            Self.dsModel <- summary.model,
            Self.dsTotalInput <- summary.totalInput,
            Self.dsTotalOutput <- summary.totalOutput,
            Self.dsTotalCacheR <- summary.totalCacheRead,
            Self.dsTotalCacheW <- summary.totalCacheWrite,
            Self.dsTotalCost <- summary.totalCost,
            Self.dsSessionCount <- summary.sessionCount
        ))
    }

    /// Query daily summaries for a date range.
    func queryDailySummary(from startDate: String? = nil, to endDate: String? = nil) throws -> [DailySummary] {
        var query = Self.dailySummary.order(Self.dsDate.desc)
        if let start = startDate {
            query = query.filter(Self.dsDate >= start)
        }
        if let end = endDate {
            query = query.filter(Self.dsDate <= end)
        }
        return try db.prepare(query).map { row in
            DailySummary(
                date: row[Self.dsDate],
                source: row[Self.dsSource],
                model: row[Self.dsModel],
                totalInput: row[Self.dsTotalInput],
                totalOutput: row[Self.dsTotalOutput],
                totalCacheRead: row[Self.dsTotalCacheR],
                totalCacheWrite: row[Self.dsTotalCacheW],
                totalCost: row[Self.dsTotalCost],
                sessionCount: row[Self.dsSessionCount]
            )
        }
    }

    /// Get daily token totals for charting (aggregated across all sources/models).
    func dailyHistory(from startDate: String, to endDate: String) throws -> [(date: String, tokens: Int)] {
        let query = Self.dailySummary
            .select(
                Self.dsDate,
                Self.dsTotalInput.sum,
                Self.dsTotalOutput.sum,
                Self.dsTotalCacheR.sum,
                Self.dsTotalCacheW.sum
            )
            .filter(Self.dsDate >= startDate)
            .filter(Self.dsDate <= endDate)
            .group(Self.dsDate)
            .order(Self.dsDate.asc)
        return try db.prepare(query).map { row in
            let tokens = (row[Self.dsTotalInput.sum] ?? 0) +
                         (row[Self.dsTotalOutput.sum] ?? 0) +
                         (row[Self.dsTotalCacheR.sum] ?? 0) +
                         (row[Self.dsTotalCacheW.sum] ?? 0)
            return (date: row[Self.dsDate], tokens: tokens)
        }
    }

    // MARK: - Friends (legacy tables kept for schema compat, not used by cloud sharing)

    /// Delete a friend and their snapshots (legacy cleanup).
    func deleteFriend(id: String) throws {
        try db.run(Self.friendSnapshots.filter(Self.fsFriendId == id).delete())
        try db.run(Self.friends.filter(Self.fFriendId == id).delete())
    }

    // MARK: - Config

    /// Get a config value.
    func getConfig(key: String) throws -> String? {
        let query = Self.config.filter(Self.cfgKey == key)
        return try db.pluck(query)?[Self.cfgValue]
    }

    /// Set a config value.
    func setConfig(key: String, value: String) throws {
        try db.run(Self.config.insert(or: .replace,
            Self.cfgKey <- key,
            Self.cfgValue <- value
        ))
    }

    /// Delete a config value.
    func deleteConfig(key: String) throws {
        try db.run(Self.config.filter(Self.cfgKey == key).delete())
    }

    // MARK: - Cache Efficiency

    /// Calculate cache efficiency (cache_read / total_input) for a date range.
    func cacheEfficiency(from startDate: String? = nil, to endDate: String? = nil) throws -> Double {
        var query = Self.tokenEvents.select(
            Self.teInputTokens.sum,
            Self.teCacheRead.sum
        )
        if let start = startDate {
            query = query.filter(Self.teTimestamp >= start)
        }
        if let end = endDate {
            query = query.filter(Self.teTimestamp <= end)
        }
        guard let row = try db.pluck(query) else { return 0 }
        let totalInput = row[Self.teInputTokens.sum] ?? 0
        let cacheRead = row[Self.teCacheRead.sum] ?? 0
        guard totalInput + cacheRead > 0 else { return 0 }
        return Double(cacheRead) / Double(totalInput + cacheRead)
    }
}
