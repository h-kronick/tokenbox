import Foundation
import SwiftUI
import Combine

/// Central manager for cloud-based friend sharing.
/// Consumed by the App Shell via @EnvironmentObject.
@MainActor
final class SharingManager: ObservableObject {
    static let shared = SharingManager()
    @Published var sharingEnabled: Bool = false
    @Published var myDisplayName: String = ""
    @Published var myShareCode: String = ""
    @Published var friends: [CloudFriend] = []
    @Published var myShareURL: String = ""
    @Published var isRegistered: Bool = false
    @Published var lastError: String? = nil

    private var friendsJSON: String {
        get { UserDefaults.standard.string(forKey: "friendsJSON") ?? "[]" }
        set { UserDefaults.standard.set(newValue, forKey: "friendsJSON") }
    }

    private let client = CloudSharingClient()
    private var pushTimer: AnyCancellable?
    private var fetchTimer: AnyCancellable?
    private var persistCancellables: Set<AnyCancellable> = []
    private var lastPushedTokens: Int = 0
    private var lastPushTime: Date = .distantPast
    private let secretTokenKey = "sharingSecretToken"

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    init() {
        let defaults = UserDefaults.standard
        sharingEnabled = defaults.bool(forKey: "sharingEnabled")
        myDisplayName = defaults.string(forKey: "myDisplayName") ?? ""
        myShareCode = defaults.string(forKey: "myShareCode") ?? ""
        loadFriends()

        // Persist @Published changes to UserDefaults via Combine
        $sharingEnabled
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "sharingEnabled") }
            .store(in: &persistCancellables)
        $myDisplayName
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "myDisplayName") }
            .store(in: &persistCancellables)
        $myShareCode
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "myShareCode") }
            .store(in: &persistCancellables)
    }

    // MARK: - Registration

    /// Reset sharing state so the user can re-register with a fresh share code + token.
    func resetRegistration() {
        myShareCode = ""
        myShareURL = ""
        isRegistered = false
        sharingEnabled = false
        UserDefaults.standard.removeObject(forKey: secretTokenKey)
        lastError = nil
    }

    /// Check if a display name contains only allowed characters (alphanumeric + spaces).
    private static func isValidDisplayName(_ name: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        return name.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Strip non-allowed characters from a received display name (defense-in-depth).
    private static func sanitizeDisplayName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        return String(name.unicodeScalars.filter { allowed.contains($0) })
    }

    /// Share code for the TokenBox creator, auto-added as a default friend on first registration.
    private static let defaultFriendCode = "XNBGBU"

    func register() async {
        let name = myDisplayName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 7 else {
            lastError = "Display name must be 1-7 characters"
            return
        }
        guard Self.isValidDisplayName(name) else {
            lastError = "Display name can only contain letters, numbers, and spaces"
            return
        }

        do {
            let response = try await client.register(displayName: name.uppercased())
            myShareCode = response.shareCode
            myShareURL = response.shareURL
            saveSecretToken(response.secretToken)
            isRegistered = true
            lastError = nil

            // Auto-add default friend (silently — never block registration)
            await addDefaultFriend(ownCode: response.shareCode)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Silently adds the default friend if not already present and not the user's own code.
    private func addDefaultFriend(ownCode: String) async {
        let code = Self.defaultFriendCode
        guard code != ownCode else { return }
        guard !friends.contains(where: { $0.shareCode == code }) else { return }

        do {
            let response = try await client.peek(shareCode: code)
            let friend = CloudFriend(
                shareCode: code,
                displayName: Self.sanitizeDisplayName(response.displayName),
                todayTokens: response.todayTokens,
                todayDate: response.todayDate,
                tokensByModel: response.tokensByModel ?? [:],
                weekByModel: response.weekByModel ?? [:],
                monthByModel: response.monthByModel ?? [:],
                allTimeByModel: response.allTimeByModel ?? [:],
                lastTokenChange: response.lastTokenChange ?? response.lastUpdated
            )
            friends.append(friend)
            saveFriends()
            NotificationCenter.default.post(name: .friendsDidChange, object: nil)
        } catch {
            // Silent — don't surface errors for the default friend add
        }
    }

    /// Update display name after registration. Validates, saves locally, and posts a notification
    /// so the app shell can trigger an immediate push with current token data.
    func updateDisplayName(_ newName: String) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 7 else {
            lastError = "Display name must be 1-7 characters"
            return
        }
        guard Self.isValidDisplayName(name) else {
            lastError = "Display name can only contain letters, numbers, and spaces"
            return
        }
        myDisplayName = name.uppercased()
        lastError = nil
        NotificationCenter.default.post(name: .displayNameDidChange, object: nil)
    }

    // MARK: - Friends

    func addFriend(input: String) async throws {
        let code = extractShareCode(from: input)
        guard code.count == 6 else {
            throw CloudSharingError.invalidShareCode
        }

        // Check for duplicates
        if friends.contains(where: { $0.shareCode == code }) {
            throw CloudSharingError.friendAlreadyExists
        }

        let response = try await client.peek(shareCode: code)
        let friend = CloudFriend(
            shareCode: code,
            displayName: Self.sanitizeDisplayName(response.displayName),
            todayTokens: response.todayTokens,
            todayDate: response.todayDate,
            tokensByModel: response.tokensByModel ?? [:],
            weekByModel: response.weekByModel ?? [:],
            monthByModel: response.monthByModel ?? [:],
            allTimeByModel: response.allTimeByModel ?? [:],
            lastTokenChange: response.lastTokenChange ?? response.lastUpdated
        )
        friends.append(friend)
        saveFriends()

        // Fetch latest data immediately so the display updates right away
        await fetchAllFriends()

        // Notify the main window to rebuild display immediately
        NotificationCenter.default.post(name: .friendsDidChange, object: nil)
    }

    func removeFriend(_ shareCode: String) {
        friends.removeAll { $0.shareCode == shareCode }
        saveFriends()
        NotificationCenter.default.post(name: .friendsDidChange, object: nil)
    }

    // MARK: - Push/Fetch Timers

    /// Callback for periodic push — set by the app shell since it owns the data store.
    var periodicPushHandler: (() async -> Void)?

    func startTimers() {
        pushTimer?.cancel()
        fetchTimer?.cancel()

        // Combined push + fetch every 60 seconds
        pushTimer = Timer.publish(every: 60, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                Task {
                    await self.periodicPushHandler?()
                    await self.fetchAllFriends()
                }
            }
    }

    func stopTimers() {
        pushTimer?.cancel()
        fetchTimer?.cancel()
    }

    func pushMyTokens(
        todayTokens: Int,
        todayByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = [],
        weekByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = [],
        monthByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = [],
        allTimeByModel: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)] = [],
        displayName: String? = nil,
        force: Bool = false
    ) async {
        guard isRegistered, sharingEnabled else { return }
        guard force || todayTokens != lastPushedTokens else { return }

        // Client-side throttle: don't hit the server more than once per 10s
        let now = Date()
        if !force && now.timeIntervalSince(lastPushTime) < 10 { return }

        guard let token = getSecretToken() else {
            lastError = "Secret token missing — please re-register by toggling sharing off and on"
            return
        }

        let todayDate = Self.dayFormatter.string(from: now)

        do {
            try await client.push(
                shareCode: myShareCode,
                secretToken: token,
                todayTokens: todayTokens,
                todayDate: todayDate,
                tokensByModel: Self.buildModelMap(todayByModel),
                weekByModel: Self.buildModelMap(weekByModel),
                monthByModel: Self.buildModelMap(monthByModel),
                allTimeByModel: Self.buildModelMap(allTimeByModel),
                displayName: displayName ?? myDisplayName
            )
            lastPushedTokens = todayTokens
            lastPushTime = now
            lastError = nil
        } catch CloudSharingError.rateLimited {
            // Silently absorb — client-side throttle will prevent repeats
            lastPushTime = now
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Build per-model output token map using short model names as keys.
    private static func buildModelMap(_ entries: [(model: String, outputTokens: Int, inputTokens: Int, cacheRead: Int, cacheCreate: Int)]) -> [String: Int] {
        var result: [String: Int] = [:]
        for entry in entries {
            let key: String
            if entry.model.contains("opus") { key = "opus" }
            else if entry.model.contains("sonnet") { key = "sonnet" }
            else if entry.model.contains("haiku") { key = "haiku" }
            else { key = entry.model }
            result[key, default: 0] += entry.outputTokens
        }
        return result
    }

    func fetchAllFriends() async {
        guard !friends.isEmpty else { return }

        await withTaskGroup(of: (String, CloudSharingClient.PeekResponse?).self) { group in
            for friend in friends {
                group.addTask { [client] in
                    let response = try? await client.peek(shareCode: friend.shareCode)
                    return (friend.shareCode, response)
                }
            }

            for await (code, response) in group {
                if let response,
                   let idx = friends.firstIndex(where: { $0.shareCode == code }) {
                    friends[idx] = CloudFriend(
                        shareCode: code,
                        displayName: Self.sanitizeDisplayName(response.displayName),
                        todayTokens: response.todayTokens,
                        todayDate: response.todayDate,
                        tokensByModel: response.tokensByModel ?? [:],
                        weekByModel: response.weekByModel ?? [:],
                        monthByModel: response.monthByModel ?? [:],
                        allTimeByModel: response.allTimeByModel ?? [:],
                        lastTokenChange: response.lastTokenChange ?? response.lastUpdated
                    )
                }
            }
        }
        saveFriends()
    }

    // MARK: - Persistence

    private func loadFriends() {
        if let data = friendsJSON.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([CloudFriend].self, from: data) {
            friends = decoded
        }
        isRegistered = !myShareCode.isEmpty
        if isRegistered {
            myShareURL = "\(CloudSharingClient.baseURL)/share/\(myShareCode)"
        }
    }

    private func saveFriends() {
        if let data = try? JSONEncoder().encode(friends),
           let json = String(data: data, encoding: .utf8) {
            friendsJSON = json
        }
    }

    // MARK: - Share Code Parsing

    private func extractShareCode(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespaces)

        // If it looks like a 6-char code already
        if trimmed.count == 6, trimmed.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return trimmed.uppercased()
        }

        // Try to extract from URL path like /share/XXXXXX
        if let url = URL(string: trimmed),
           let lastComponent = url.pathComponents.last,
           lastComponent.count == 6 {
            return lastComponent.uppercased()
        }

        // Try tokenbox://add/XXXXXX
        if let url = URL(string: trimmed),
           url.scheme == "tokenbox",
           url.host == "add",
           let code = url.pathComponents.last,
           code.count == 6 {
            return code.uppercased()
        }

        return trimmed.uppercased()
    }

    // MARK: - Secret Token Storage

    private func saveSecretToken(_ token: String) {
        UserDefaults.standard.set(token, forKey: secretTokenKey)
    }

    func getSecretToken() -> String? {
        UserDefaults.standard.string(forKey: secretTokenKey)
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let friendsDidChange = Notification.Name("TokenBoxFriendsDidChange")
    static let displayNameDidChange = Notification.Name("TokenBoxDisplayNameDidChange")
    static let displaySettingsDidChange = Notification.Name("TokenBoxDisplaySettingsDidChange")
}

// MARK: - Errors

enum SharingError: Error, LocalizedError {
    case registrationFailed
    case invalidInput

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            return "Failed to register for sharing"
        case .invalidInput:
            return "Invalid share code or URL"
        }
    }
}
