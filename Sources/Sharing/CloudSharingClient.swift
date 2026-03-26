import Foundation

/// Minimal HTTP client for the TokenBox cloud sharing API.
actor CloudSharingClient {
    // This will be updated with the real deployed URL
    static let baseURL = "https://tokenbox.club"

    struct RegisterResponse: Codable {
        let shareCode: String
        let secretToken: String
        let shareURL: String
    }

    struct ServerAggregate: Codable {
        let todayTokens: Int?
        let tokensByModel: [String: Int]?
        let weekByModel: [String: Int]?
        let monthByModel: [String: Int]?
        let allTimeByModel: [String: Int]?
    }

    struct PushResponse: Codable {
        let displayName: String?
        let devices: [LinkedDevice]?
        let serverAggregate: ServerAggregate?
    }

    struct PeekResponse: Codable {
        let displayName: String
        let todayTokens: Int
        let todayDate: String
        let tokensByModel: [String: Int]?
        let weekByModel: [String: Int]?
        let monthByModel: [String: Int]?
        let allTimeByModel: [String: Int]?
        let lastUpdated: String?  // legacy, ignored
        let lastTokenChange: String?
    }

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        self.session = URLSession(configuration: config)
    }

    // MARK: - Endpoints

    /// Register a new share identity. Returns a share code, secret token, and share URL.
    func register(displayName: String) async throws -> RegisterResponse {
        guard let url = URL(string: "\(Self.baseURL)/register") else {
            throw CloudSharingError.invalidURL(endpoint: "register")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(["displayName": displayName])

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(RegisterResponse.self, from: data)
    }

    /// Push token counts to the cloud, with per-model breakdowns for all periods.
    @discardableResult
    func push(shareCode: String, secretToken: String, todayTokens: Int, todayDate: String, tokensByModel: [String: Int] = [:], weekByModel: [String: Int] = [:], monthByModel: [String: Int] = [:], allTimeByModel: [String: Int] = [:], displayName: String? = nil, deviceId: String? = nil) async throws -> PushResponse {
        guard let url = URL(string: "\(Self.baseURL)/push") else {
            throw CloudSharingError.invalidURL(endpoint: "push")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretToken)", forHTTPHeaderField: "Authorization")

        struct PushBody: Encodable {
            let shareCode: String
            let todayTokens: Int
            let todayDate: String
            let tokensByModel: [String: Int]
            let weekByModel: [String: Int]
            let monthByModel: [String: Int]
            let allTimeByModel: [String: Int]
            let displayName: String?
            let deviceId: String?
        }
        request.httpBody = try encoder.encode(PushBody(
            shareCode: shareCode,
            todayTokens: todayTokens,
            todayDate: todayDate,
            tokensByModel: tokensByModel,
            weekByModel: weekByModel,
            monthByModel: monthByModel,
            allTimeByModel: allTimeByModel,
            displayName: displayName,
            deviceId: deviceId
        ))

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return (try? decoder.decode(PushResponse.self, from: data)) ?? PushResponse(displayName: nil, devices: nil, serverAggregate: nil)
    }

    /// Peek at a friend's current token count by share code.
    func peek(shareCode: String) async throws -> PeekResponse {
        guard let url = URL(string: "\(Self.baseURL)/share/\(shareCode)") else {
            throw CloudSharingError.invalidURL(endpoint: "share/\(shareCode)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(PeekResponse.self, from: data)
    }

    // MARK: - Device Linking Endpoints

    struct CreateLinkResponse: Codable {
        let linkCode: String
    }

    struct RedeemLinkResponse: Codable {
        let shareCode: String
        let secretToken: String
        let displayName: String
        let deviceId: String
    }

    /// Create a link code for multi-device linking. Requires active sharing.
    func createLinkToken(shareCode: String, secretToken: String) async throws -> CreateLinkResponse {
        guard let url = URL(string: "\(Self.baseURL)/link/create") else {
            throw CloudSharingError.invalidURL(endpoint: "link/create")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretToken)", forHTTPHeaderField: "Authorization")

        request.httpBody = try encoder.encode(["shareCode": shareCode])

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(CreateLinkResponse.self, from: data)
    }

    /// Redeem a link code to join an existing share identity from another device.
    func redeemLinkToken(linkCode: String, deviceLabel: String? = nil) async throws -> RedeemLinkResponse {
        guard let url = URL(string: "\(Self.baseURL)/link/redeem") else {
            throw CloudSharingError.invalidURL(endpoint: "link/redeem")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct RedeemBody: Encodable {
            let linkCode: String
            let deviceLabel: String?
        }
        request.httpBody = try encoder.encode(RedeemBody(linkCode: linkCode, deviceLabel: deviceLabel))

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(RedeemLinkResponse.self, from: data)
    }

    /// Unlink a device from the shared identity.
    func unlinkDevice(shareCode: String, secretToken: String, deviceId: String) async throws {
        guard let url = URL(string: "\(Self.baseURL)/unlink") else {
            throw CloudSharingError.invalidURL(endpoint: "unlink")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretToken)", forHTTPHeaderField: "Authorization")

        struct UnlinkBody: Encodable {
            let shareCode: String
            let deviceId: String
        }
        request.httpBody = try encoder.encode(UnlinkBody(shareCode: shareCode, deviceId: deviceId))

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Leaderboard Endpoints

    struct LeaderboardJoinResponse: Codable {
        let ok: Bool
        let username: String
    }

    struct LeaderboardResponse: Codable {
        let date: String
        let model: String
        let entries: [LeaderboardEntry]
    }

    struct LeaderboardHistoryDay: Codable {
        let date: String
        let tokens: Int
        let opusTokens: Int
        let sonnetTokens: Int
        let haikuTokens: Int
    }

    struct LeaderboardHistoryResponse: Codable {
        let username: String
        let history: [LeaderboardHistoryDay]
    }

    /// Join the public leaderboard. Requires active sharing (at least one push).
    func joinLeaderboard(shareCode: String, secretToken: String, username: String, email: String) async throws -> LeaderboardJoinResponse {
        guard let url = URL(string: "\(Self.baseURL)/leaderboard/join") else {
            throw CloudSharingError.invalidURL(endpoint: "leaderboard/join")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretToken)", forHTTPHeaderField: "Authorization")

        struct JoinBody: Encodable {
            let shareCode: String
            let username: String
            let email: String
        }
        request.httpBody = try encoder.encode(JoinBody(shareCode: shareCode, username: username, email: email))

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(LeaderboardJoinResponse.self, from: data)
    }

    /// Leave the public leaderboard. Frees the username for reuse.
    func leaveLeaderboard(shareCode: String, secretToken: String) async throws {
        guard let url = URL(string: "\(Self.baseURL)/leaderboard/leave") else {
            throw CloudSharingError.invalidURL(endpoint: "leaderboard/leave")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretToken)", forHTTPHeaderField: "Authorization")

        request.httpBody = try encoder.encode(["shareCode": shareCode])

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    /// Update leaderboard username. Must already be opted in.
    func updateLeaderboardUsername(shareCode: String, secretToken: String, newUsername: String) async throws {
        guard let url = URL(string: "\(Self.baseURL)/leaderboard/update-username") else {
            throw CloudSharingError.invalidURL(endpoint: "leaderboard/update-username")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(secretToken)", forHTTPHeaderField: "Authorization")

        struct UpdateBody: Encodable {
            let shareCode: String
            let username: String
        }
        request.httpBody = try encoder.encode(UpdateBody(shareCode: shareCode, username: newUsername))

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    /// Fetch the public daily leaderboard. No auth required.
    func getLeaderboard(date: String? = nil, model: String = "opus", limit: Int = 50) async throws -> LeaderboardResponse {
        var components = URLComponents(string: "\(Self.baseURL)/leaderboard")!
        var queryItems: [URLQueryItem] = []
        if let date { queryItems.append(URLQueryItem(name: "date", value: date)) }
        queryItems.append(URLQueryItem(name: "model", value: model))
        queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        components.queryItems = queryItems

        guard let url = components.url else {
            throw CloudSharingError.invalidURL(endpoint: "leaderboard")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(LeaderboardResponse.self, from: data)
    }

    /// Fetch daily token history for a leaderboard user. No auth required.
    func getLeaderboardHistory(username: String, days: Int = 30) async throws -> LeaderboardHistoryResponse {
        var components = URLComponents(string: "\(Self.baseURL)/leaderboard/history/\(username)")!
        components.queryItems = [URLQueryItem(name: "days", value: String(days))]

        guard let url = components.url else {
            throw CloudSharingError.invalidURL(endpoint: "leaderboard/history")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try validateResponse(response)
        return try decoder.decode(LeaderboardHistoryResponse.self, from: data)
    }

    // MARK: - Helpers

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudSharingError.invalidResponse
        }
        if http.statusCode == 429 {
            throw CloudSharingError.rateLimited
        }
        guard (200...299).contains(http.statusCode) else {
            throw CloudSharingError.httpError(statusCode: http.statusCode)
        }
    }
}

// MARK: - Errors

enum CloudSharingError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case rateLimited
    case invalidShareCode
    case friendAlreadyExists
    case invalidURL(endpoint: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from sharing server"
        case .httpError(let code):
            return "Sharing server returned HTTP \(code)"
        case .rateLimited:
            return "Rate limited — will retry shortly"
        case .invalidShareCode:
            return "Invalid share code format"
        case .friendAlreadyExists:
            return "This friend has already been added"
        case .invalidURL(let endpoint):
            return "Invalid URL for endpoint: \(endpoint)"
        }
    }
}
