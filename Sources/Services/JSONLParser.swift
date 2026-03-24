import Foundation

/// Parses Claude Code JSONL session log files into TokenEvent records.
/// Location: ~/.claude/projects/<project>/<session>.jsonl
/// Each line is a JSON event. Corrupted lines are skipped gracefully.
struct JSONLParser {

    /// Parse a single JSONL line into a TokenEvent, if it contains token usage data.
    static func parseLine(_ line: String, project: String? = nil, sessionId: String? = nil) -> TokenEvent? {
        guard !line.isEmpty else { return nil }
        guard let data = line.data(using: .utf8) else { return nil }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        // Look for token usage in the message structure
        // JSONL events can have different shapes — we extract what we can
        let usage = extractUsage(from: json)
        guard usage.hasTokens else { return nil }

        let timestamp = extractTimestamp(from: json)
        let model = extractModel(from: json)
        let sid = extractSessionId(from: json) ?? sessionId
        let cost = extractCost(from: json)

        return TokenEvent(
            timestamp: timestamp,
            source: "claude_code",
            sessionId: sid,
            project: project,
            model: model,
            inputTokens: usage.input,
            outputTokens: usage.output,
            cacheCreate: usage.cacheCreate,
            cacheRead: usage.cacheRead,
            costUsd: cost
        )
    }

    /// Parse an entire JSONL file, returning all extractable token events.
    static func parseFile(at path: String, project: String? = nil) -> [TokenEvent] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        let sessionId = sessionIdFromPath(path)
        let projectName = project ?? projectNameFromPath(path)

        return content.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            parseLine(String(line), project: projectName, sessionId: sessionId)
        }
    }

    /// Parse only new lines from a file, starting at the given byte offset.
    /// Returns all parsed events (with completeness flag) and the new offset.
    static func parseNewLines(at path: String, fromOffset offset: UInt64, project: String? = nil) -> (events: [(event: TokenEvent, isComplete: Bool)], newOffset: UInt64) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return ([], offset)
        }
        defer { try? handle.close() }

        handle.seek(toFileOffset: offset)
        let data = handle.readDataToEndOfFile()
        let newOffset = offset + UInt64(data.count)

        guard let content = String(data: data, encoding: .utf8) else {
            return ([], newOffset)
        }

        let sessionId = sessionIdFromPath(path)
        let projectName = project ?? projectNameFromPath(path)

        let events: [(event: TokenEvent, isComplete: Bool)] = content.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let lineStr = String(line)
            guard let event = parseLine(lineStr, project: projectName, sessionId: sessionId) else { return nil }
            return (event: event, isComplete: isCompleteEvent(lineStr))
        }

        return (events, newOffset)
    }

    // MARK: - Extraction helpers

    private struct Usage {
        var input: Int = 0
        var output: Int = 0
        var cacheCreate: Int = 0
        var cacheRead: Int = 0
        var hasTokens: Bool { input > 0 || output > 0 || cacheCreate > 0 || cacheRead > 0 }
    }

    private static func extractUsage(from json: [String: Any]) -> Usage {
        var usage = Usage()

        // Direct fields
        if let input = json["input_tokens"] as? Int { usage.input = input }
        if let output = json["output_tokens"] as? Int { usage.output = output }
        if let cc = json["cache_creation_input_tokens"] as? Int { usage.cacheCreate = cc }
        if let cr = json["cache_read_input_tokens"] as? Int { usage.cacheRead = cr }
        if usage.hasTokens { return usage }

        // Nested under "usage"
        if let u = json["usage"] as? [String: Any] {
            usage.input = u["input_tokens"] as? Int ?? 0
            usage.output = u["output_tokens"] as? Int ?? 0
            usage.cacheCreate = u["cache_creation_input_tokens"] as? Int ?? 0
            usage.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
            if usage.hasTokens { return usage }
        }

        // Nested under "message" → "usage"
        if let msg = json["message"] as? [String: Any],
           let u = msg["usage"] as? [String: Any] {
            usage.input = u["input_tokens"] as? Int ?? 0
            usage.output = u["output_tokens"] as? Int ?? 0
            usage.cacheCreate = u["cache_creation_input_tokens"] as? Int ?? 0
            usage.cacheRead = u["cache_read_input_tokens"] as? Int ?? 0
        }

        // Context window format (from Status hook)
        if let cw = json["context_window"] as? [String: Any],
           let cu = cw["current_usage"] as? [String: Any] {
            usage.input = cu["input_tokens"] as? Int ?? 0
            usage.output = cu["output_tokens"] as? Int ?? 0
            usage.cacheCreate = cu["cache_creation_input_tokens"] as? Int ?? 0
            usage.cacheRead = cu["cache_read_input_tokens"] as? Int ?? 0
        }

        return usage
    }

    private static func extractTimestamp(from json: [String: Any]) -> String {
        if let ts = json["timestamp"] as? String { return ts }
        if let ts = json["ts"] as? String { return ts }
        // Fallback: use current time
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date())
    }

    private static func extractModel(from json: [String: Any]) -> String {
        if let model = json["model"] as? String { return model }
        if let model = json["model"] as? [String: Any] {
            return model["id"] as? String ?? model["api_model_id"] as? String ?? "unknown"
        }
        if let msg = json["message"] as? [String: Any],
           let model = msg["model"] as? String { return model }
        return "unknown"
    }

    private static func extractSessionId(from json: [String: Any]) -> String? {
        json["session_id"] as? String ?? json["sid"] as? String
    }

    private static func extractCost(from json: [String: Any]) -> Double? {
        if let cost = json["costUSD"] as? Double { return cost }
        if let cost = json["cost"] as? Double { return cost }
        if let costObj = json["cost"] as? [String: Any],
           let total = costObj["total_cost_usd"] as? Double { return total }
        return nil
    }

    // MARK: - Event Completeness

    /// Check if a JSONL line represents a completed message (has stop_reason).
    /// Intermediate streaming events have stop_reason=null and should not be
    /// stored in the DB to avoid double-counting, but can be used for real-time display.
    static func isCompleteEvent(_ line: String) -> Bool {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return true // Non-message events (e.g. user, progress) are "complete"
        }
        // If it has a message with stop_reason=null, it's an intermediate streaming event
        if let msg = json["message"] as? [String: Any] {
            let stopReason = msg["stop_reason"]
            if stopReason == nil || stopReason is NSNull {
                return false
            }
        }
        return true
    }

    // MARK: - Path helpers

    /// Extract session ID from JSONL filename (filename without extension).
    static func sessionIdFromPath(_ path: String) -> String {
        (path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
    }

    /// Extract project name from JSONL path.
    /// Path format: ~/.claude/projects/<encoded-project-path>/<session>.jsonl
    static func projectNameFromPath(_ path: String) -> String? {
        let components = (path as NSString).pathComponents
        // Find "projects" in path and take the next component
        if let idx = components.firstIndex(of: "projects"), idx + 1 < components.count {
            let encoded = components[idx + 1]
            // The directory name is the project path with slashes replaced by hyphens
            // Return just the last meaningful segment
            let parts = encoded.split(separator: "-")
            if let last = parts.last { return String(last) }
            return encoded
        }
        return nil
    }
}
