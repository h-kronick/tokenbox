import Foundation

/// Raw token event from JSONL logs or hooks
struct TokenEvent: Codable, Equatable, Sendable {
    var id: Int64?
    let timestamp: String          // ISO 8601
    let source: String             // "claude_code" | "api" | "claude_chat"
    let sessionId: String?
    let project: String?           // basename only, no path
    let model: String              // e.g. "claude-sonnet-4-6"
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreate: Int
    let cacheRead: Int
    let costUsd: Double?

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreate + cacheRead
    }
}

/// Pre-aggregated daily rollup for fast dashboard queries
struct DailySummary: Codable, Equatable, Sendable {
    let date: String               // YYYY-MM-DD
    let source: String
    let model: String
    let totalInput: Int
    let totalOutput: Int
    let totalCacheRead: Int
    let totalCacheWrite: Int
    let totalCost: Double?
    let sessionCount: Int

    var totalTokens: Int {
        totalInput + totalOutput + totalCacheRead + totalCacheWrite
    }
}

/// A friend tracked via cloud sharing (share code + display name)
struct CloudFriend: Codable, Equatable, Sendable, Identifiable {
    let shareCode: String        // 6-char code, doubles as ID
    let displayName: String      // max 7 chars
    var todayTokens: Int = 0     // legacy total (fallback)
    var todayDate: String = ""   // which day the tokens refer to
    var tokensByModel: [String: Int] = [:]  // e.g. {"opus": 1234, "sonnet": 5678}
    var weekByModel: [String: Int] = [:]
    var monthByModel: [String: Int] = [:]
    var allTimeByModel: [String: Int] = [:]
    var lastTokenChange: String?           // ISO 8601 datetime of last token change

    var id: String { shareCode }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Whether the stored todayDate matches the viewer's local today.
    var isTodayCurrent: Bool {
        return todayDate == Self.dayFormatter.string(from: Date())
    }

    /// Get output tokens for a specific period and model filter.
    func tokens(for modelFilter: String?, period: String = "today") -> Int {
        // For "today" period, return 0 if the friend's data is from a different day
        if period == "today" && !isTodayCurrent {
            return 0
        }

        let map: [String: Int]
        switch period {
        case "week": map = weekByModel
        case "month": map = monthByModel
        case "allTime": map = allTimeByModel
        default: map = tokensByModel
        }

        // If no per-model breakdown available, fall back to legacy todayTokens total
        if map.isEmpty {
            return period == "today" ? todayTokens : 0
        }

        guard let filter = modelFilter else {
            return map.values.reduce(0, +)
        }
        let lf = filter.lowercased()
        return map.filter { $0.key.lowercased().contains(lf) }
            .values.reduce(0, +)
    }
}

/// live.json event from status-relay hook
struct LiveEvent: Codable, Equatable, Sendable {
    let ts: String
    let sid: String?
    let model: String
    let cost: Double
    let `in`: Int
    let out: Int
    let cw: Int
    let cr: Int

    enum CodingKeys: String, CodingKey {
        case ts, sid, model, cost
        case `in`, out, cw, cr
    }
}
