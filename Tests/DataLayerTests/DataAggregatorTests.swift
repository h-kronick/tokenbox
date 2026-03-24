import XCTest
@testable import TokenBox

final class DataAggregatorTests: XCTestCase {

    var db: Database!
    var aggregator: DataAggregator!

    override func setUp() async throws {
        db = try Database()
        aggregator = DataAggregator(db: db)
    }

    func testRollupDate() throws {
        // Insert events for a single day with two models
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 500, cacheCreate: 200, cacheRead: 300, costUsd: 0.05))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T11:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 2000, outputTokens: 1000, cacheCreate: 0, cacheRead: 0, costUsd: 0.10))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T12:00:00Z", source: "claude_code", sessionId: "s2", project: nil, model: "claude-opus-4-6", inputTokens: 5000, outputTokens: 2000, cacheCreate: 1000, cacheRead: 500, costUsd: 0.50))

        try aggregator.rollupDate("2026-03-19")

        let summaries = try db.queryDailySummary(from: "2026-03-19", to: "2026-03-19")
        XCTAssertEqual(summaries.count, 2)

        // Find sonnet summary
        let sonnet = summaries.first { $0.model == "claude-sonnet-4-6" }
        XCTAssertNotNil(sonnet)
        XCTAssertEqual(sonnet?.totalInput, 3000)
        XCTAssertEqual(sonnet?.totalOutput, 1500)
        XCTAssertEqual(sonnet?.totalCacheRead, 300)
        XCTAssertEqual(sonnet?.totalCacheWrite, 200)
        XCTAssertEqual(sonnet?.totalCost ?? 0, 0.15, accuracy: 0.001)
        XCTAssertEqual(sonnet?.sessionCount, 1) // both events from s1

        // Find opus summary
        let opus = summaries.first { $0.model == "claude-opus-4-6" }
        XCTAssertNotNil(opus)
        XCTAssertEqual(opus?.totalInput, 5000)
        XCTAssertEqual(opus?.sessionCount, 1) // s2
    }

    func testRollupEmptyDate() throws {
        // No events for this date — should not crash
        try aggregator.rollupDate("2026-01-01")
        let summaries = try db.queryDailySummary(from: "2026-01-01", to: "2026-01-01")
        XCTAssertEqual(summaries.count, 0)
    }

    func testRollupUpdatesExisting() throws {
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 500, cacheCreate: 0, cacheRead: 0, costUsd: nil))

        try aggregator.rollupDate("2026-03-19")

        var summaries = try db.queryDailySummary(from: "2026-03-19", to: "2026-03-19")
        XCTAssertEqual(summaries[0].totalInput, 1000)

        // Add more events and re-rollup
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T15:00:00Z", source: "claude_code", sessionId: "s2", project: nil, model: "claude-sonnet-4-6", inputTokens: 3000, outputTokens: 1500, cacheCreate: 0, cacheRead: 0, costUsd: nil))

        try aggregator.rollupDate("2026-03-19")

        summaries = try db.queryDailySummary(from: "2026-03-19", to: "2026-03-19")
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].totalInput, 4000)
        XCTAssertEqual(summaries[0].sessionCount, 2)
    }
}
