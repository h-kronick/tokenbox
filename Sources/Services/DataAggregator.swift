import Foundation

/// Computes daily rollups from token_events into the daily_summary table.
struct DataAggregator {

    let db: Database

    /// Recompute daily summaries for a specific date from raw token_events.
    func rollupDate(_ date: String) throws {
        // Query all events for this date
        let startOfDay = date + "T00:00:00Z"
        let endOfDay = date + "T23:59:59Z"
        let events = try db.queryTokenEvents(from: startOfDay, to: endOfDay)

        // Group by (source, model)
        var groups: [String: (input: Int, output: Int, cacheR: Int, cacheW: Int, cost: Double?, sessions: Set<String>)] = [:]
        for event in events {
            let key = "\(event.source)|\(event.model)"
            var group = groups[key] ?? (0, 0, 0, 0, nil, [])
            group.input += event.inputTokens
            group.output += event.outputTokens
            group.cacheR += event.cacheRead
            group.cacheW += event.cacheCreate
            if let c = event.costUsd {
                group.cost = (group.cost ?? 0) + c
            }
            if let sid = event.sessionId {
                group.sessions.insert(sid)
            }
            groups[key] = group
        }

        // Upsert each group
        for (key, group) in groups {
            let parts = key.split(separator: "|", maxSplits: 1)
            let source = String(parts[0])
            let model = String(parts[1])
            let summary = DailySummary(
                date: date,
                source: source,
                model: model,
                totalInput: group.input,
                totalOutput: group.output,
                totalCacheRead: group.cacheR,
                totalCacheWrite: group.cacheW,
                totalCost: group.cost,
                sessionCount: group.sessions.count
            )
            try db.upsertDailyRollup(summary)
        }
    }

    /// Recompute daily summaries for the last N days.
    func rollupRecentDays(_ days: Int = 30) throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar.current
        let today = Date()

        for dayOffset in 0..<days {
            guard let date = calendar.date(byAdding: .day, value: -dayOffset, to: today) else { continue }
            let dateStr = formatter.string(from: date)
            try rollupDate(dateStr)
        }
    }
}
