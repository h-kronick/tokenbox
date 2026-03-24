import XCTest
@testable import TokenBox

final class DatabaseTests: XCTestCase {

    var db: Database!

    override func setUp() async throws {
        db = try Database()  // in-memory
    }

    // MARK: - Token Events

    func testInsertAndQueryTokenEvent() throws {
        let event = TokenEvent(
            timestamp: "2026-03-19T10:00:00Z",
            source: "claude_code",
            sessionId: "session1",
            project: "myproject",
            model: "claude-sonnet-4-6",
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreate: 200,
            cacheRead: 300,
            costUsd: 0.05
        )

        let rowId = try db.insertTokenEvent(event)
        XCTAssertNotNil(rowId)

        let results = try db.queryTokenEvents()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].source, "claude_code")
        XCTAssertEqual(results[0].sessionId, "session1")
        XCTAssertEqual(results[0].model, "claude-sonnet-4-6")
        XCTAssertEqual(results[0].inputTokens, 1000)
        XCTAssertEqual(results[0].outputTokens, 500)
        XCTAssertEqual(results[0].cacheCreate, 200)
        XCTAssertEqual(results[0].cacheRead, 300)
        XCTAssertEqual(results[0].costUsd, 0.05)
    }

    func testDedupOnInsert() throws {
        let event = TokenEvent(
            timestamp: "2026-03-19T10:00:00Z",
            source: "claude_code",
            sessionId: "session1",
            project: "myproject",
            model: "claude-sonnet-4-6",
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreate: 0,
            cacheRead: 0,
            costUsd: nil
        )

        let id1 = try db.insertTokenEvent(event)
        XCTAssertNotNil(id1)

        // Same timestamp + session + model = dedup
        let id2 = try db.insertTokenEvent(event)
        XCTAssertNil(id2)

        let results = try db.queryTokenEvents()
        XCTAssertEqual(results.count, 1)
    }

    func testQueryWithDateRange() throws {
        let events = [
            TokenEvent(timestamp: "2026-03-18T10:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 100, outputTokens: 50, cacheCreate: 0, cacheRead: 0, costUsd: nil),
            TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s2", project: nil, model: "claude-sonnet-4-6", inputTokens: 200, outputTokens: 100, cacheCreate: 0, cacheRead: 0, costUsd: nil),
            TokenEvent(timestamp: "2026-03-20T10:00:00Z", source: "claude_code", sessionId: "s3", project: nil, model: "claude-sonnet-4-6", inputTokens: 300, outputTokens: 150, cacheCreate: 0, cacheRead: 0, costUsd: nil),
        ]
        for e in events { try db.insertTokenEvent(e) }

        let filtered = try db.queryTokenEvents(from: "2026-03-19T00:00:00Z", to: "2026-03-19T23:59:59Z")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered[0].inputTokens, 200)
    }

    func testTotalTokens() throws {
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 500, cacheCreate: 200, cacheRead: 300, costUsd: nil))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T11:00:00Z", source: "claude_code", sessionId: "s2", project: nil, model: "claude-sonnet-4-6", inputTokens: 2000, outputTokens: 1000, cacheCreate: 0, cacheRead: 0, costUsd: nil))

        let total = try db.totalTokens()
        XCTAssertEqual(total, 1000 + 500 + 200 + 300 + 2000 + 1000)
    }

    func testModelBreakdown() throws {
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 500, cacheCreate: 0, cacheRead: 0, costUsd: nil))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T11:00:00Z", source: "claude_code", sessionId: "s2", project: nil, model: "claude-opus-4-6", inputTokens: 2000, outputTokens: 1000, cacheCreate: 0, cacheRead: 0, costUsd: nil))

        let breakdown = try db.modelBreakdown()
        XCTAssertEqual(breakdown.count, 2)
        // Sorted by tokens desc — opus first (3000 > 1500)
        XCTAssertEqual(breakdown[0].model, "claude-opus-4-6")
        XCTAssertEqual(breakdown[0].tokens, 3000)
        XCTAssertEqual(breakdown[1].model, "claude-sonnet-4-6")
        XCTAssertEqual(breakdown[1].tokens, 1500)
    }

    func testTopProjects() throws {
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s1", project: "projectA", model: "claude-sonnet-4-6", inputTokens: 1000, outputTokens: 0, cacheCreate: 0, cacheRead: 0, costUsd: nil))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T11:00:00Z", source: "claude_code", sessionId: "s2", project: "projectB", model: "claude-sonnet-4-6", inputTokens: 5000, outputTokens: 0, cacheCreate: 0, cacheRead: 0, costUsd: nil))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T12:00:00Z", source: "claude_code", sessionId: "s3", project: nil, model: "claude-sonnet-4-6", inputTokens: 100, outputTokens: 0, cacheCreate: 0, cacheRead: 0, costUsd: nil))

        let projects = try db.topProjects()
        XCTAssertEqual(projects.count, 2) // nil project excluded
        XCTAssertEqual(projects[0].name, "projectB")
        XCTAssertEqual(projects[0].tokens, 5000)
    }

    func testCacheEfficiency() throws {
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 800, outputTokens: 0, cacheCreate: 0, cacheRead: 200, costUsd: nil))

        let efficiency = try db.cacheEfficiency()
        // cacheRead / (input + cacheRead) = 200 / 1000 = 0.2
        XCTAssertEqual(efficiency, 0.2, accuracy: 0.001)
    }

    func testSessionCount() throws {
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T10:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-sonnet-4-6", inputTokens: 100, outputTokens: 0, cacheCreate: 0, cacheRead: 0, costUsd: nil))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T11:00:00Z", source: "claude_code", sessionId: "s1", project: nil, model: "claude-opus-4-6", inputTokens: 100, outputTokens: 0, cacheCreate: 0, cacheRead: 0, costUsd: nil))
        try db.insertTokenEvent(TokenEvent(timestamp: "2026-03-19T12:00:00Z", source: "claude_code", sessionId: "s2", project: nil, model: "claude-sonnet-4-6", inputTokens: 100, outputTokens: 0, cacheCreate: 0, cacheRead: 0, costUsd: nil))

        let count = try db.sessionCount(from: "2026-03-19T00:00:00Z", to: "2026-03-19T23:59:59Z")
        XCTAssertEqual(count, 2) // s1 and s2
    }

    // MARK: - Daily Summary

    func testUpsertAndQueryDailySummary() throws {
        let summary = DailySummary(
            date: "2026-03-19",
            source: "claude_code",
            model: "claude-sonnet-4-6",
            totalInput: 10000,
            totalOutput: 5000,
            totalCacheRead: 2000,
            totalCacheWrite: 1000,
            totalCost: 0.50,
            sessionCount: 5
        )

        try db.upsertDailyRollup(summary)

        let results = try db.queryDailySummary()
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].totalInput, 10000)
        XCTAssertEqual(results[0].sessionCount, 5)

        // Upsert should replace
        let updated = DailySummary(
            date: "2026-03-19",
            source: "claude_code",
            model: "claude-sonnet-4-6",
            totalInput: 20000,
            totalOutput: 10000,
            totalCacheRead: 3000,
            totalCacheWrite: 2000,
            totalCost: 1.00,
            sessionCount: 8
        )
        try db.upsertDailyRollup(updated)

        let afterUpdate = try db.queryDailySummary()
        XCTAssertEqual(afterUpdate.count, 1)
        XCTAssertEqual(afterUpdate[0].totalInput, 20000)
        XCTAssertEqual(afterUpdate[0].sessionCount, 8)
    }

    func testDailyHistory() throws {
        try db.upsertDailyRollup(DailySummary(date: "2026-03-17", source: "claude_code", model: "claude-sonnet-4-6", totalInput: 1000, totalOutput: 500, totalCacheRead: 0, totalCacheWrite: 0, totalCost: nil, sessionCount: 1))
        try db.upsertDailyRollup(DailySummary(date: "2026-03-18", source: "claude_code", model: "claude-sonnet-4-6", totalInput: 2000, totalOutput: 1000, totalCacheRead: 0, totalCacheWrite: 0, totalCost: nil, sessionCount: 2))
        try db.upsertDailyRollup(DailySummary(date: "2026-03-19", source: "claude_code", model: "claude-sonnet-4-6", totalInput: 3000, totalOutput: 1500, totalCacheRead: 0, totalCacheWrite: 0, totalCost: nil, sessionCount: 3))

        let history = try db.dailyHistory(from: "2026-03-17", to: "2026-03-19")
        XCTAssertEqual(history.count, 3)
        // Should be sorted ascending
        XCTAssertEqual(history[0].date, "2026-03-17")
        XCTAssertEqual(history[0].tokens, 1500) // 1000 + 500
        XCTAssertEqual(history[2].date, "2026-03-19")
        XCTAssertEqual(history[2].tokens, 4500) // 3000 + 1500
    }

    // MARK: - Friends

    func testFriendCRUD() throws {
        let friend = Friend(
            friendId: "abc123",
            displayName: "Alice",
            publicKey: "base64key",
            firstSeen: "2026-03-19T10:00:00Z",
            lastUpdated: "2026-03-19T10:00:00Z"
        )

        try db.upsertFriend(friend)

        var friends = try db.allFriends()
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends[0].displayName, "Alice")

        // Update
        let updated = Friend(
            friendId: "abc123",
            displayName: "Alice B.",
            publicKey: "base64key",
            firstSeen: "2026-03-19T10:00:00Z",
            lastUpdated: "2026-03-19T12:00:00Z"
        )
        try db.upsertFriend(updated)

        friends = try db.allFriends()
        XCTAssertEqual(friends.count, 1)
        XCTAssertEqual(friends[0].displayName, "Alice B.")

        // Delete
        try db.deleteFriend(id: "abc123")
        friends = try db.allFriends()
        XCTAssertEqual(friends.count, 0)
    }

    func testFriendSnapshots() throws {
        let friend = Friend(friendId: "abc123", displayName: "Alice", publicKey: "key", firstSeen: "2026-03-19T10:00:00Z", lastUpdated: "2026-03-19T10:00:00Z")
        try db.upsertFriend(friend)

        let snapshot = FriendSnapshot(
            friendId: "abc123",
            snapshotDate: "2026-03-19",
            periodFrom: "2026-03-01",
            periodTo: "2026-03-19",
            totalTokens: 1000000,
            costEstimate: 15.50,
            byModel: "{\"claude-sonnet-4-6\": 800000}",
            dailyAvg: 52631,
            peakTokens: 100000,
            cacheEfficiency: 0.35,
            signature: "sig123"
        )

        let rowId = try db.insertFriendSnapshot(snapshot)
        XCTAssertNotNil(rowId)

        let snapshots = try db.snapshotsForFriend(id: "abc123")
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots[0].totalTokens, 1000000)

        // Dedup on same date
        let dup = try db.insertFriendSnapshot(snapshot)
        XCTAssertNil(dup)
    }

    func testDeleteFriendCascadesSnapshots() throws {
        let friend = Friend(friendId: "abc123", displayName: "Alice", publicKey: "key", firstSeen: "2026-03-19T10:00:00Z", lastUpdated: "2026-03-19T10:00:00Z")
        try db.upsertFriend(friend)

        try db.insertFriendSnapshot(FriendSnapshot(friendId: "abc123", snapshotDate: "2026-03-19", periodFrom: "2026-03-01", periodTo: "2026-03-19", totalTokens: 100, costEstimate: nil, byModel: nil, dailyAvg: nil, peakTokens: nil, cacheEfficiency: nil, signature: "sig"))

        try db.deleteFriend(id: "abc123")

        let snapshots = try db.snapshotsForFriend(id: "abc123")
        XCTAssertEqual(snapshots.count, 0)
    }

    // MARK: - Config

    func testConfig() throws {
        // Get non-existent key
        XCTAssertNil(try db.getConfig(key: "theme"))

        // Set
        try db.setConfig(key: "theme", value: "amber")
        XCTAssertEqual(try db.getConfig(key: "theme"), "amber")

        // Update
        try db.setConfig(key: "theme", value: "green")
        XCTAssertEqual(try db.getConfig(key: "theme"), "green")

        // Delete
        try db.deleteConfig(key: "theme")
        XCTAssertNil(try db.getConfig(key: "theme"))
    }
}
