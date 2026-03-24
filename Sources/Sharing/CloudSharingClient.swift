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
    func push(shareCode: String, secretToken: String, todayTokens: Int, todayDate: String, tokensByModel: [String: Int] = [:], weekByModel: [String: Int] = [:], monthByModel: [String: Int] = [:], allTimeByModel: [String: Int] = [:], displayName: String? = nil) async throws {
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
        }
        request.httpBody = try encoder.encode(PushBody(
            shareCode: shareCode,
            todayTokens: todayTokens,
            todayDate: todayDate,
            tokensByModel: tokensByModel,
            weekByModel: weekByModel,
            monthByModel: monthByModel,
            allTimeByModel: allTimeByModel,
            displayName: displayName
        ))

        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
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
