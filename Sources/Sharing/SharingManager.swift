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
    @Published var leaderboardOptIn: Bool = false
    @Published var leaderboardUsername: String = ""
    @Published var leaderboardEntries: [LeaderboardEntry] = []
    @Published var linkedDevices: [LinkedDevice] = []
    @Published var activeLinkCode: String? = nil
    @Published var isGeneratingLink: Bool = false
    /// Server aggregate token data (combined across all linked devices).
    /// Only populated when devices are linked and server returns aggregate data.
    @Published var serverAggregate: CloudSharingClient.ServerAggregate?
    /// Local token total (from SQLite) at the moment serverAggregate was last updated.
    /// Used to compute smooth display: aggregate + (currentLocal - localAtSnapshot)
    /// so that DB refreshes don't cause the display to jump backward.
    var localTokensAtAggregateSnapshot: Int = 0
    /// The model the leaderboard panel is currently showing. Set by LeaderboardSidePanel
    /// so the periodic fetch uses the correct model tab.
    var leaderboardModel: String = "opus"

    private var friendsJSON: String {
        get { UserDefaults.standard.string(forKey: "friendsJSON") ?? "[]" }
        set { UserDefaults.standard.set(newValue, forKey: "friendsJSON") }
    }

    private let client = CloudSharingClient()
    private var pushTimer: AnyCancellable?
    private var fetchTimer: AnyCancellable?
    private var linkCodeTimer: AnyCancellable?
    private var persistCancellables: Set<AnyCancellable> = []
    private var lastPushedTokens: Int = 0
    private var lastPushTime: Date = .distantPast
    private var lastPushedPSTDate: String = ""
    /// Set when a PST day change is detected in pushMyTokens before the data store
    /// has refreshed. While true, pushes send 0 tokens to prevent stale cached
    /// yesterday data from being written into the new day's daily_tokens doc.
    private var awaitingDayBoundaryRefresh: Bool = false
    private var isSyncing: Bool = false
    private let secretTokenKey = "sharingSecretToken"
    private let leaderboardEmailKey = "leaderboardEmail"
    private let deviceIdKey = "deviceId"
    let deviceId: String

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return f
    }()

    init() {
        let defaults = UserDefaults.standard
        sharingEnabled = defaults.bool(forKey: "sharingEnabled")
        myDisplayName = defaults.string(forKey: "myDisplayName") ?? ""
        myShareCode = defaults.string(forKey: "myShareCode") ?? ""
        leaderboardOptIn = defaults.bool(forKey: "leaderboardOptIn")
        leaderboardUsername = defaults.string(forKey: "leaderboardUsername") ?? ""

        if let existing = defaults.string(forKey: deviceIdKey), !existing.isEmpty {
            deviceId = existing
        } else {
            let newId = UUID().uuidString
            defaults.set(newId, forKey: deviceIdKey)
            deviceId = newId
        }

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
        $leaderboardOptIn
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "leaderboardOptIn") }
            .store(in: &persistCancellables)
        $leaderboardUsername
            .dropFirst()
            .sink { UserDefaults.standard.set($0, forKey: "leaderboardUsername") }
            .store(in: &persistCancellables)

        // Clear the stale-data suppression flag when the data store refreshes
        // after a PST day boundary, so the next push sends correct today values.
        NotificationCenter.default.publisher(for: .dayBoundaryDidChange)
            .sink { [weak self] _ in
                self?.awaitingDayBoundaryRefresh = false
            }
            .store(in: &persistCancellables)
    }

    // MARK: - Registration

    /// Reset sharing state so the user can re-register with a fresh share code + token.
    func resetRegistration() async {
        // Unlink this device from the shared identity before clearing local state
        if isRegistered, let token = getSecretToken() {
            try? await client.unlinkDevice(shareCode: myShareCode, secretToken: token, deviceId: deviceId)
        }
        myShareCode = ""
        myShareURL = ""
        isRegistered = false
        sharingEnabled = false
        linkedDevices = []
        activeLinkCode = nil
        linkCodeTimer?.cancel()
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

        // Combined push + fetch every 30 seconds.
        // Push first (so the server has our latest data), then fetch friends
        // and leaderboard concurrently, then sync friends from leaderboard.
        pushTimer = Timer.publish(every: 30, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.isSyncing else { return }
                Task {
                    self.isSyncing = true
                    defer { self.isSyncing = false }
                    await self.periodicPushHandler?()
                    async let friendsFetch: () = self.fetchAllFriends()
                    async let leaderboardFetch: () = self.fetchLeaderboard(model: self.leaderboardModel)
                    _ = await (friendsFetch, leaderboardFetch)
                    self.syncFriendsFromLeaderboard()
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

        // Detect PST day change: if push fires before checkDayBoundary refreshes the
        // data store, todayTokens still holds yesterday's value. Send 0 for the new day
        // so the server doesn't write stale data into the new daily_tokens doc.
        // The awaitingDayBoundaryRefresh flag keeps sending 0 until the data store
        // actually refreshes (posts dayBoundaryDidChange), preventing the second push
        // from sending stale cached values with the new date.
        let dayChanged = !lastPushedPSTDate.isEmpty && todayDate != lastPushedPSTDate
        if dayChanged {
            awaitingDayBoundaryRefresh = true
        }
        let suppressStaleData = dayChanged || awaitingDayBoundaryRefresh
        let effectiveTokens = suppressStaleData ? 0 : todayTokens
        let effectiveTokensByModel = suppressStaleData ? [:] : Self.buildModelMap(todayByModel)

        do {
            let pushResponse = try await client.push(
                shareCode: myShareCode,
                secretToken: token,
                todayTokens: effectiveTokens,
                todayDate: todayDate,
                tokensByModel: effectiveTokensByModel,
                weekByModel: Self.buildModelMap(weekByModel),
                monthByModel: Self.buildModelMap(monthByModel),
                allTimeByModel: Self.buildModelMap(allTimeByModel),
                displayName: displayName ?? myDisplayName,
                deviceId: deviceId
            )
            lastPushedTokens = effectiveTokens
            lastPushedPSTDate = todayDate
            lastPushTime = now
            lastError = nil

            // Sync display name from server if it differs
            if let serverName = pushResponse.displayName,
               !serverName.isEmpty,
               Self.sanitizeDisplayName(serverName).uppercased() != myDisplayName {
                myDisplayName = Self.sanitizeDisplayName(serverName).uppercased()
            }

            // Parse linked devices from response (only present when deviceId was sent)
            if let devices = pushResponse.devices {
                linkedDevices = devices
            }

            // Store server aggregate for multi-device display.
            // Snapshot local todayTokens so display can smoothly interpolate:
            // displayValue = aggregate + (currentLocal - localAtSnapshot)
            if let agg = pushResponse.serverAggregate {
                serverAggregate = agg
                localTokensAtAggregateSnapshot = todayTokens
                NotificationCenter.default.post(name: .serverAggregateDidChange, object: nil)
            }
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

    // MARK: - Device Linking

    /// Generate a link code for multi-device linking. Auto-clears after 15 minutes.
    func createLinkCode() async {
        guard isRegistered else {
            lastError = "Enable sharing first to link devices"
            return
        }
        guard let token = getSecretToken() else {
            lastError = "Secret token missing — please re-register"
            return
        }

        isGeneratingLink = true
        defer { isGeneratingLink = false }

        do {
            let response = try await client.createLinkToken(shareCode: myShareCode, secretToken: token)
            activeLinkCode = response.linkCode
            lastError = nil

            // Auto-clear after 15 minutes
            linkCodeTimer?.cancel()
            linkCodeTimer = Timer.publish(every: 15 * 60, on: .main, in: .common)
                .autoconnect()
                .first()
                .sink { [weak self] _ in
                    self?.activeLinkCode = nil
                }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Redeem a link code to join an existing share identity from another device.
    /// If this device is already registered, the caller must confirm before invoking
    /// with `confirmed: true` — this will auto-leave the leaderboard for the old code.
    func redeemLinkCode(_ linkCode: String, deviceLabel: String? = nil, confirmed: Bool = false) async {
        if isRegistered && !confirmed {
            // Caller should show confirmation dialog and retry with confirmed: true
            return
        }

        // If already registered, leave leaderboard for old identity first
        if isRegistered && confirmed {
            if leaderboardOptIn {
                await leaveLeaderboard()
            }
        }

        do {
            let response = try await client.redeemLinkToken(linkCode: linkCode, deviceLabel: deviceLabel)
            myShareCode = response.shareCode
            myShareURL = "\(CloudSharingClient.baseURL)/share/\(response.shareCode)"
            myDisplayName = Self.sanitizeDisplayName(response.displayName).uppercased()
            saveSecretToken(response.secretToken)
            isRegistered = true
            sharingEnabled = true
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Unlink a remote device from the shared identity. Cannot unlink self.
    func unlinkDevice(_ targetDeviceId: String) async {
        guard targetDeviceId != deviceId else { return }
        guard let token = getSecretToken() else {
            lastError = "Secret token missing"
            return
        }

        do {
            try await client.unlinkDevice(shareCode: myShareCode, secretToken: token, deviceId: targetDeviceId)
            linkedDevices.removeAll { $0.deviceId == targetDeviceId }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Leaderboard

    /// Validate a leaderboard username: 3-15 chars, alphanumeric + underscore.
    private static func isValidUsername(_ name: String) -> Bool {
        let pattern = "^[a-zA-Z0-9_]+$"
        return name.count >= 3 && name.count <= 15 && name.range(of: pattern, options: .regularExpression) != nil
    }

    /// Join the public daily leaderboard. Requires active sharing registration.
    func joinLeaderboard(username: String, email: String) async {
        guard isRegistered, sharingEnabled else {
            lastError = "Enable sharing first to join the leaderboard"
            return
        }

        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard Self.isValidUsername(trimmedUsername) else {
            lastError = "Username must be 3-15 characters (letters, numbers, underscore)"
            return
        }

        let trimmedEmail = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmedEmail.contains("@"), trimmedEmail.contains(".") else {
            lastError = "Please enter a valid email address"
            return
        }

        guard let token = getSecretToken() else {
            lastError = "Secret token missing — please re-register by toggling sharing off and on"
            return
        }

        do {
            let response = try await client.joinLeaderboard(
                shareCode: myShareCode,
                secretToken: token,
                username: trimmedUsername,
                email: trimmedEmail
            )
            leaderboardOptIn = true
            leaderboardUsername = response.username
            UserDefaults.standard.set(trimmedEmail, forKey: leaderboardEmailKey)
            lastError = nil
            await fetchLeaderboard()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Leave the public leaderboard. Clears local state and frees the username.
    func leaveLeaderboard() async {
        guard let token = getSecretToken() else {
            lastError = "Secret token missing"
            return
        }

        do {
            try await client.leaveLeaderboard(shareCode: myShareCode, secretToken: token)
            leaderboardOptIn = false
            leaderboardUsername = ""
            UserDefaults.standard.removeObject(forKey: leaderboardEmailKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Update the leaderboard username. Must already be opted in.
    func updateLeaderboardUsername(_ newUsername: String) async {
        let trimmed = newUsername.trimmingCharacters(in: .whitespaces)
        guard Self.isValidUsername(trimmed) else {
            lastError = "Username must be 3-15 characters (letters, numbers, underscore)"
            return
        }

        guard let token = getSecretToken() else {
            lastError = "Secret token missing"
            return
        }

        do {
            try await client.updateLeaderboardUsername(
                shareCode: myShareCode,
                secretToken: token,
                newUsername: trimmed
            )
            leaderboardUsername = trimmed
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Fetch the public daily leaderboard. Marks own entry with isMe if opted in.
    func fetchLeaderboard(model: String = "opus") async {
        do {
            let response = try await client.getLeaderboard(model: model)
            var entries = response.entries
            if leaderboardOptIn, !leaderboardUsername.isEmpty {
                for i in entries.indices {
                    if entries[i].username.lowercased() == leaderboardUsername.lowercased() {
                        entries[i].isMe = true
                    }
                }
            }
            leaderboardEntries = entries
        } catch {
            // Silently keep stale entries on fetch failure
        }
    }

    /// Cross-reference leaderboard entries with friends to keep token values in sync.
    /// If a friend's display name matches a leaderboard username, update the friend's
    /// per-model token breakdown to match the leaderboard value. This ensures the
    /// context row and leaderboard panel always show the same number for the same user.
    func syncFriendsFromLeaderboard() {
        guard !leaderboardEntries.isEmpty, !friends.isEmpty else { return }

        // Build lookup: lowercase username → leaderboard tokens
        var lbLookup: [String: Int] = [:]
        for entry in leaderboardEntries {
            lbLookup[entry.username.lowercased()] = entry.tokens
        }

        let model = leaderboardModel.lowercased()
        var changed = false
        for i in friends.indices {
            let friendName = friends[i].displayName.lowercased()
            if let lbTokens = lbLookup[friendName] {
                // Find the matching key in tokensByModel (e.g. "claude-opus-4-6" contains "opus")
                // and update it to match the leaderboard value.
                let matchingKey = friends[i].tokensByModel.keys.first {
                    $0.lowercased().contains(model)
                }
                if let key = matchingKey {
                    if friends[i].tokensByModel[key] != lbTokens {
                        friends[i].tokensByModel[key] = lbTokens
                        friends[i].todayTokens = lbTokens
                        changed = true
                    }
                } else if !friends[i].tokensByModel.isEmpty {
                    // No matching key yet — add one using the model name directly
                    friends[i].tokensByModel[model] = lbTokens
                    friends[i].todayTokens = lbTokens
                    changed = true
                } else {
                    // Legacy friend with no tokensByModel — update todayTokens
                    if friends[i].todayTokens != lbTokens {
                        friends[i].todayTokens = lbTokens
                        changed = true
                    }
                }
            }
        }
        if changed {
            saveFriends()
        }
    }

    // MARK: - Server Aggregate Helpers

    /// Clear stale server aggregate on PST day boundary so the display falls back
    /// to local (reset) data until the next push response arrives with fresh values.
    func clearServerAggregate() {
        guard serverAggregate != nil else { return }
        serverAggregate = nil
        localTokensAtAggregateSnapshot = 0
        lastPushedTokens = 0 // Ensure next push fires even if local todayTokens is 0
        NotificationCenter.default.post(name: .serverAggregateDidChange, object: nil)
    }

    /// Whether this device has linked peers and server aggregate data is available.
    var hasServerAggregate: Bool {
        !linkedDevices.isEmpty && serverAggregate != nil
    }

    /// Get filtered aggregate tokens for a period, applying the given model filter.
    func aggregateTokens(for modelFilter: String?, period: String) -> Int? {
        guard let agg = serverAggregate, !linkedDevices.isEmpty else { return nil }

        let map: [String: Int]?
        switch period {
        case "today": map = agg.tokensByModel
        case "week": map = agg.weekByModel
        case "month": map = agg.monthByModel
        case "allTime": map = agg.allTimeByModel
        default: map = agg.tokensByModel
        }

        // If no per-model map, fall back to todayTokens for "today" period
        guard let modelMap = map, !modelMap.isEmpty else {
            return period == "today" ? agg.todayTokens : nil
        }

        guard let filter = modelFilter else {
            return modelMap.values.reduce(0, +)
        }
        let lf = filter.lowercased()
        return modelMap.filter { $0.key.lowercased().contains(lf) }.values.reduce(0, +)
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
    static let serverAggregateDidChange = Notification.Name("TokenBoxServerAggregateDidChange")
    static let dayBoundaryDidChange = Notification.Name("TokenBoxDayBoundaryDidChange")
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
