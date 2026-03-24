import XCTest
@testable import TokenBox

final class JSONLParserTests: XCTestCase {

    // MARK: - Single Line Parsing

    func testParseLineWithDirectUsage() {
        let line = """
        {"timestamp":"2026-03-19T10:00:00Z","model":"claude-sonnet-4-6","session_id":"s1","input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":200,"cache_read_input_tokens":300}
        """
        let event = JSONLParser.parseLine(line, project: "testproj")
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.model, "claude-sonnet-4-6")
        XCTAssertEqual(event?.inputTokens, 1000)
        XCTAssertEqual(event?.outputTokens, 500)
        XCTAssertEqual(event?.cacheCreate, 200)
        XCTAssertEqual(event?.cacheRead, 300)
        XCTAssertEqual(event?.project, "testproj")
        XCTAssertEqual(event?.sessionId, "s1")
    }

    func testParseLineWithNestedUsage() {
        let line = """
        {"timestamp":"2026-03-19T10:00:00Z","model":"claude-sonnet-4-6","usage":{"input_tokens":500,"output_tokens":250,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}
        """
        let event = JSONLParser.parseLine(line)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.inputTokens, 500)
        XCTAssertEqual(event?.outputTokens, 250)
    }

    func testParseLineWithMessageUsage() {
        let line = """
        {"timestamp":"2026-03-19T10:00:00Z","message":{"model":"claude-opus-4-6","usage":{"input_tokens":2000,"output_tokens":1000,"cache_creation_input_tokens":500,"cache_read_input_tokens":100}}}
        """
        let event = JSONLParser.parseLine(line)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.model, "claude-opus-4-6")
        XCTAssertEqual(event?.inputTokens, 2000)
        XCTAssertEqual(event?.cacheCreate, 500)
    }

    func testParseLineWithContextWindowFormat() {
        let line = """
        {"timestamp":"2026-03-19T10:00:00Z","model":{"id":"claude-opus-4-6","display_name":"Opus"},"context_window":{"current_usage":{"input_tokens":8500,"output_tokens":1200,"cache_creation_input_tokens":5000,"cache_read_input_tokens":2000}}}
        """
        let event = JSONLParser.parseLine(line)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.model, "claude-opus-4-6")
        XCTAssertEqual(event?.inputTokens, 8500)
        XCTAssertEqual(event?.outputTokens, 1200)
        XCTAssertEqual(event?.cacheCreate, 5000)
        XCTAssertEqual(event?.cacheRead, 2000)
    }

    func testParseLineWithCostObject() {
        let line = """
        {"timestamp":"2026-03-19T10:00:00Z","model":"claude-sonnet-4-6","input_tokens":100,"output_tokens":50,"cost":{"total_cost_usd":0.31}}
        """
        let event = JSONLParser.parseLine(line)
        XCTAssertNotNil(event)
        XCTAssertEqual(event?.costUsd, 0.31)
    }

    func testParseLineSkipsNoTokenLines() {
        let line = """
        {"timestamp":"2026-03-19T10:00:00Z","type":"text","content":"hello"}
        """
        let event = JSONLParser.parseLine(line)
        XCTAssertNil(event)
    }

    func testParseLineSkipsEmptyString() {
        XCTAssertNil(JSONLParser.parseLine(""))
    }

    func testParseLineSkipsCorruptedJSON() {
        XCTAssertNil(JSONLParser.parseLine("{invalid json"))
        XCTAssertNil(JSONLParser.parseLine("not json at all"))
    }

    func testParseLineUsesDefaultTimestamp() {
        let line = """
        {"model":"claude-sonnet-4-6","input_tokens":100,"output_tokens":50}
        """
        let event = JSONLParser.parseLine(line)
        XCTAssertNotNil(event)
        // Should have a generated timestamp (ISO 8601)
        XCTAssertFalse(event!.timestamp.isEmpty)
    }

    func testParseLinePassesThroughSessionId() {
        let line = """
        {"timestamp":"2026-03-19T10:00:00Z","model":"claude-sonnet-4-6","input_tokens":100,"output_tokens":50}
        """
        let event = JSONLParser.parseLine(line, sessionId: "provided-session")
        XCTAssertEqual(event?.sessionId, "provided-session")
    }

    // MARK: - Path Helpers

    func testSessionIdFromPath() {
        let path = "/Users/test/.claude/projects/myproject/abc123.jsonl"
        XCTAssertEqual(JSONLParser.sessionIdFromPath(path), "abc123")
    }

    func testProjectNameFromPath() {
        let path = "/Users/test/.claude/projects/Users-test-Documents-myproject/abc123.jsonl"
        let project = JSONLParser.projectNameFromPath(path)
        XCTAssertEqual(project, "myproject")
    }

    // MARK: - Model Types

    func testTokenEventTotalTokens() {
        let event = TokenEvent(
            timestamp: "2026-03-19T10:00:00Z",
            source: "claude_code",
            sessionId: nil,
            project: nil,
            model: "claude-sonnet-4-6",
            inputTokens: 1000,
            outputTokens: 500,
            cacheCreate: 200,
            cacheRead: 300,
            costUsd: nil
        )
        XCTAssertEqual(event.totalTokens, 2000)
    }

    func testDailySummaryTotalTokens() {
        let summary = DailySummary(
            date: "2026-03-19",
            source: "claude_code",
            model: "claude-sonnet-4-6",
            totalInput: 10000,
            totalOutput: 5000,
            totalCacheRead: 2000,
            totalCacheWrite: 1000,
            totalCost: nil,
            sessionCount: 1
        )
        XCTAssertEqual(summary.totalTokens, 18000)
    }
}
