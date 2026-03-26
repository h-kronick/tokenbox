import SwiftUI

/// Standard macOS Preferences window with tabs.
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dataStore: TokenDataStore
    @EnvironmentObject var sharingManager: SharingManager

    var body: some View {
        TabView {
            GeneralTab()
                .environmentObject(appState)
                .environmentObject(dataStore)
                .tabItem { Label("General", systemImage: "gear") }

            DataSourcesTab()
                .environmentObject(dataStore)
                .tabItem { Label("Data Sources", systemImage: "externaldrive") }

            SharingTab()
                .environmentObject(sharingManager)
                .environmentObject(dataStore)
                .tabItem { Label("Sharing", systemImage: "person.2") }

            SoundTab()
                .tabItem { Label("Sound", systemImage: "speaker.wave.2") }

            DisplayTab()
                .tabItem { Label("Display", systemImage: "paintpalette") }

            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 380)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dataStore: TokenDataStore
    @AppStorage("defaultPeriod") private var defaultPeriod = "today"
    @AppStorage("launchAtLogin") private var launchAtLogin = false
    @AppStorage("menuBarShowTokens") private var menuBarShowTokens = true
    @AppStorage("realtimeFlipDisplay") private var realtimeFlipDisplay = true

    var body: some View {
        Form {
            Section("Display") {
                Picker("Period", selection: $appState.pinnedDisplay) {
                    Text("Today").tag("today")
                    Text("Week").tag("week")
                    Text("Month").tag("month")
                    Text("All Time").tag("allTime")
                }
                .pickerStyle(.segmented)

                Picker("Model", selection: Binding(
                    get: { dataStore.modelFilter ?? "__all__" },
                    set: { dataStore.modelFilter = $0 == "__all__" ? nil : $0 }
                )) {
                    Text("All Models").tag("__all__")
                    Text("Opus").tag("opus")
                    Text("Sonnet").tag("sonnet")
                    Text("Haiku").tag("haiku")
                }
                .pickerStyle(.segmented)

                HStack {
                    Text("Default on launch")
                        .foregroundColor(.secondary)
                    Spacer()
                    Picker("", selection: $defaultPeriod) {
                        Text("Today").tag("today")
                        Text("Week").tag("week")
                        Text("Month").tag("month")
                        Text("All Time").tag("allTime")
                    }
                    .labelsHidden()
                    .frame(width: 110)
                }
                .font(.caption)

                Text("Output tokens for the selected model and period. Other periods rotate below.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                if dataStore.todayByModel.isEmpty {
                    Text("No token data yet")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(dataStore.todayByModel, id: \.model) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(formatModelName(entry.model))
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                            HStack(spacing: 16) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Output")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(formatCompactTokens(entry.outputTokens))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Input (uncached)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(formatCompactTokens(entry.inputTokens))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Cache Read")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(formatCompactTokens(entry.cacheRead))
                                        .font(.system(.caption, design: .monospaced))
                                }
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Cache Write")
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                    Text(formatCompactTokens(entry.cacheCreate))
                                        .font(.system(.caption, design: .monospaced))
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Text("Output = tokens Claude generated. Input = your prompt (uncached portion). Cache Read = input served from cache. Cache Write = input written to cache for future turns.\n\nOnly output tokens are shown on the display and in sharing. Week/Month/Total reflect data since TokenBox began tracking. Claude.ai web chat and direct API usage are not included.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            } header: {
                Text("Today's Breakdown")
            }

            Section {
                Toggle("Real-time streaming display", isOn: $realtimeFlipDisplay)
                Toggle("Show token count in menu bar", isOn: $menuBarShowTokens)
                Toggle("Launch at login", isOn: $launchAtLogin)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func formatModelName(_ model: String) -> String {
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model.components(separatedBy: "-").last ?? model
    }
}

// MARK: - Data Sources Tab

struct DataSourcesTab: View {
    @EnvironmentObject var dataStore: TokenDataStore
    @AppStorage("jsonlScanEnabled") private var jsonlScanEnabled = true

    var body: some View {
        Form {
            Section("JSONL Session Logs") {
                Toggle("Scan ~/.claude/projects/ for session data", isOn: $jsonlScanEnabled)
                Button("Rescan Now") {
                    dataStore.refresh()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Sharing Tab

struct SharingTab: View {
    @EnvironmentObject var sharingManager: SharingManager
    @EnvironmentObject var dataStore: TokenDataStore
    @State private var friendInput = ""
    @State private var addError = ""
    @State private var isAdding = false
    @State private var isEditingName = false
    @State private var editedName = ""
    @State private var nameUpdateError = ""
    @State private var showLinkSheet = false
    @State private var linkCodeInput = ""
    @State private var showAlreadyRegisteredAlert = false
    @State private var pendingLinkCode = ""

    var body: some View {
        Form {
            if !sharingManager.isRegistered {
                // Not registered state
                Section("Set Up Sharing") {
                    HStack {
                        Text("Display Name:")
                        TextField("MAX 7", text: $sharingManager.myDisplayName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 120)
                            .onChange(of: sharingManager.myDisplayName) { _, newValue in
                                if newValue.count > 7 {
                                    sharingManager.myDisplayName = String(newValue.prefix(7))
                                }
                            }
                        Text("(shown uppercase)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Button("Start Sharing") {
                        Task {
                            await sharingManager.register()
                            if sharingManager.isRegistered {
                                sharingManager.sharingEnabled = true
                                await sharingManager.pushMyTokens(
                                    todayTokens: dataStore.todayTokens,
                                    todayByModel: dataStore.todayByModel,
                                    weekByModel: dataStore.weekByModel,
                                    monthByModel: dataStore.monthByModel,
                                    allTimeByModel: dataStore.allTimeByModel,
                                    force: true
                                )
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sharingManager.myDisplayName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                // Registered state
                Section("Your Share Link") {
                    Toggle("Sharing Enabled", isOn: $sharingManager.sharingEnabled)
                        .onChange(of: sharingManager.sharingEnabled) { _, enabled in
                            if enabled {
                                Task {
                                    await sharingManager.pushMyTokens(
                                        todayTokens: dataStore.todayTokens,
                                        todayByModel: dataStore.todayByModel,
                                        weekByModel: dataStore.weekByModel,
                                        monthByModel: dataStore.monthByModel,
                                        allTimeByModel: dataStore.allTimeByModel,
                                        force: true
                                    )
                                }
                            }
                        }

                    HStack {
                        Text(sharingManager.myShareURL)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(6)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .cornerRadius(4)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(sharingManager.myShareURL, forType: .string)
                        }
                    }

                    HStack {
                        Text("Share Code:")
                            .foregroundColor(.secondary)
                        Text(sharingManager.myShareCode)
                            .font(.system(.body, design: .monospaced))
                            .fontWeight(.semibold)
                    }

                    if isEditingName {
                        HStack {
                            Text("Display Name:")
                                .foregroundColor(.secondary)
                            TextField("MAX 7", text: $editedName)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)
                                .onChange(of: editedName) { _, newValue in
                                    if newValue.count > 7 {
                                        editedName = String(newValue.prefix(7))
                                    }
                                }
                            Button("Save") {
                                saveDisplayName()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(editedName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button("Cancel") {
                                isEditingName = false
                                nameUpdateError = ""
                            }
                            .controlSize(.small)
                        }
                        if !nameUpdateError.isEmpty {
                            Text(nameUpdateError)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    } else if sharingManager.myDisplayName.isEmpty {
                        HStack {
                            Text("Display Name:")
                                .foregroundColor(.secondary)
                            Text("Not set")
                                .foregroundColor(.secondary)
                                .italic()
                            Button("Set Name") {
                                editedName = ""
                                nameUpdateError = ""
                                isEditingName = true
                            }
                            .controlSize(.small)
                        }
                    } else {
                        HStack {
                            Text("Display Name:")
                                .foregroundColor(.secondary)
                            Text(sharingManager.myDisplayName)
                                .fontWeight(.medium)
                            Button {
                                editedName = sharingManager.myDisplayName
                                nameUpdateError = ""
                                isEditingName = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Linked Devices") {
                    Text("Use Claude Code on multiple machines? Link them to combine your stats.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if sharingManager.linkedDevices.isEmpty {
                        Text("This device only")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sharingManager.linkedDevices) { device in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 8) {
                                    Image(systemName: device.deviceId == sharingManager.deviceId ? "desktopcomputer" : "display")
                                        .foregroundColor(.secondary)
                                    VStack(alignment: .leading, spacing: 1) {
                                        HStack(spacing: 4) {
                                            Text(device.label ?? String(device.deviceId.prefix(8)))
                                                .fontWeight(device.deviceId == sharingManager.deviceId ? .semibold : .regular)
                                            if device.deviceId == sharingManager.deviceId {
                                                Text("(this device)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        if let lastPush = device.lastPush {
                                            Text("Last active \(Self.relativeTime(from: lastPush))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if device.deviceId != sharingManager.deviceId {
                                        Button("Unlink") {
                                            Task { await sharingManager.unlinkDevice(device.deviceId) }
                                        }
                                        .foregroundColor(.red)
                                        .controlSize(.small)
                                    }
                                }
                                // Per-model token breakdown
                                if let tbm = device.tokensByModel, !tbm.isEmpty {
                                    HStack(spacing: 12) {
                                        ForEach(["opus", "sonnet", "haiku"], id: \.self) { model in
                                            if let count = tbm[model], count > 0 {
                                                HStack(spacing: 2) {
                                                    Text(model.capitalized)
                                                        .font(.caption2)
                                                        .foregroundColor(.secondary)
                                                    Text(Self.formatCompact(count))
                                                        .font(.system(.caption2, design: .monospaced))
                                                        .fontWeight(.medium)
                                                }
                                            }
                                        }
                                    }
                                    .padding(.leading, 28) // align with text after icon
                                }
                            }
                        }
                    }

                    if let code = sharingManager.activeLinkCode {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(code)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(6)
                                .background(Color(nsColor: .controlBackgroundColor))
                                .cornerRadius(4)
                            HStack {
                                Button("Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code, forType: .string)
                                }
                                .controlSize(.small)
                                Text("Expires in 15 minutes")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        Button("Link Another Device") {
                            Task { await sharingManager.createLinkCode() }
                        }
                        .disabled(sharingManager.isGeneratingLink)
                    }

                    Button("Link to Existing Device") {
                        linkCodeInput = ""
                        showLinkSheet = true
                    }
                }

                Section("Friends") {
                    HStack {
                        TextField("Paste a share code or link...", text: $friendInput)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            addFriend()
                        }
                        .disabled(friendInput.trimmingCharacters(in: .whitespaces).isEmpty || isAdding)
                    }

                    if !addError.isEmpty {
                        Text(addError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    if sharingManager.friends.isEmpty {
                        Text("No friends added yet")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(sharingManager.friends) { friend in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(friend.displayName)
                                        .fontWeight(.medium)
                                    Spacer()
                                    Text("(\(friend.shareCode))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Button("Remove") {
                                        sharingManager.removeFriend(friend.shareCode)
                                    }
                                    .foregroundColor(.red)
                                }
                                if let changed = friend.lastTokenChange {
                                    Text("Last active \(Self.relativeTime(from: changed))")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                LeaderboardSettingsSection()
                    .environmentObject(sharingManager)
            }

            if let error = sharingManager.lastError {
                Section {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                    if error.contains("re-register") || error.contains("token") {
                        Button("Reset & Re-register") {
                            Task { await sharingManager.resetRegistration() }
                        }
                        .foregroundColor(.red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .sheet(isPresented: $showLinkSheet) {
            VStack(spacing: 16) {
                Text("Link to Existing Device")
                    .font(.headline)
                Text("Enter the link code from your other device:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("TB-XXX-XXXXXXXXXXXX", text: $linkCodeInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 280)
                HStack {
                    Button("Cancel") {
                        showLinkSheet = false
                    }
                    Button("Link") {
                        let code = linkCodeInput.trimmingCharacters(in: .whitespaces)
                        guard !code.isEmpty else { return }
                        if sharingManager.isRegistered {
                            pendingLinkCode = code
                            showLinkSheet = false
                            showAlreadyRegisteredAlert = true
                        } else {
                            Task {
                                await sharingManager.redeemLinkCode(code)
                                showLinkSheet = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(linkCodeInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 360)
        }
        .alert("Already Registered", isPresented: $showAlreadyRegisteredAlert) {
            Button("Cancel", role: .cancel) {
                pendingLinkCode = ""
            }
            Button("Link Anyway", role: .destructive) {
                let code = pendingLinkCode
                pendingLinkCode = ""
                Task {
                    await sharingManager.redeemLinkCode(code, confirmed: true)
                }
            }
        } message: {
            Text("This device is already registered with a share code. Linking will switch to the new identity and leave the leaderboard for your current code.")
        }
    }

    private func saveDisplayName() {
        let name = editedName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 7 else {
            nameUpdateError = "Display name must be 1-7 characters"
            return
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " "))
        guard name.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            nameUpdateError = "Display name can only contain letters, numbers, and spaces"
            return
        }
        sharingManager.updateDisplayName(name)
        isEditingName = false
        nameUpdateError = ""
    }

    private func addFriend() {
        isAdding = true
        addError = ""
        Task {
            do {
                try await sharingManager.addFriend(input: friendInput)
                friendInput = ""
            } catch {
                addError = error.localizedDescription
            }
            isAdding = false
        }
    }

    private static func relativeTime(from iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else {
            return iso
        }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .abbreviated
        return rel.localizedString(for: date, relativeTo: Date())
    }

    private static func formatCompact(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Leaderboard Settings Section

struct LeaderboardSettingsSection: View {
    @EnvironmentObject var sharingManager: SharingManager
    @State private var leaderboardUsernameInput = ""
    @State private var leaderboardEmailInput = ""
    @State private var isEditingLeaderboardUsername = false
    @State private var editedLeaderboardUsername = ""
    @State private var leaderboardError = ""
    @State private var justJoinedLeaderboard = false

    private var isUsernameValid: Bool {
        let t = leaderboardUsernameInput.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.count <= 15 && t.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil
    }

    private var isEmailValid: Bool {
        let t = leaderboardEmailInput.trimmingCharacters(in: .whitespaces)
        return t.contains("@") && t.contains(".")
    }

    var body: some View {
        if sharingManager.isRegistered {
            Section("Leaderboard") {
                if !sharingManager.sharingEnabled {
                    Text("Enable sharing first to join the leaderboard")
                        .foregroundColor(.secondary)
                } else if justJoinedLeaderboard {
                    // Brief success state
                    VStack(alignment: .leading, spacing: 4) {
                        Text("✓ You're on the board!")
                            .fontWeight(.medium)
                        Text("@\(sharingManager.leaderboardUsername)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            justJoinedLeaderboard = false
                        }
                    }
                } else if sharingManager.leaderboardOptIn {
                    // After joining — show status + edit/leave
                    if isEditingLeaderboardUsername {
                        HStack {
                            Text("Username:")
                                .foregroundColor(.secondary)
                            TextField("3-15 chars", text: $editedLeaderboardUsername)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                            Button("Save") {
                                saveLeaderboardUsername()
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(editedLeaderboardUsername.trimmingCharacters(in: .whitespaces).count < 3)
                            Button("Cancel") {
                                isEditingLeaderboardUsername = false
                                leaderboardError = ""
                            }
                            .controlSize(.small)
                        }
                    } else {
                        HStack {
                            Text("Username:")
                                .foregroundColor(.secondary)
                            Text(sharingManager.leaderboardUsername)
                                .font(.system(.body, design: .monospaced))
                                .fontWeight(.medium)
                            Button {
                                editedLeaderboardUsername = sharingManager.leaderboardUsername
                                leaderboardError = ""
                                isEditingLeaderboardUsername = true
                            } label: {
                                Image(systemName: "pencil")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack {
                        Text("Status:")
                            .foregroundColor(.secondary)
                        Text("Opted In ✓")
                            .foregroundColor(.green)
                    }

                    if !leaderboardError.isEmpty {
                        Text(leaderboardError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Button("Leave Leaderboard") {
                        Task {
                            await sharingManager.leaveLeaderboard()
                        }
                    }
                    .foregroundColor(.red)
                    .buttonStyle(.plain)
                } else {
                    // Before joining — show form
                    Text("Join the public daily leaderboard. Only your username and daily output token count are visible. All other Claude data stays private.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 4)

                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Username")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("pick_a_username", text: $leaderboardUsernameInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                            if !leaderboardUsernameInput.isEmpty && !isUsernameValid {
                                Text("3-15 characters: letters, numbers, underscore")
                                    .font(.caption2)
                                    .foregroundColor(.red)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Email")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextField("you@example.com", text: $leaderboardEmailInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 220)
                            Text("Private — never displayed publicly")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !leaderboardError.isEmpty {
                        Text(leaderboardError)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    Button("Join Leaderboard") {
                        leaderboardError = ""
                        Task {
                            await sharingManager.joinLeaderboard(
                                username: leaderboardUsernameInput,
                                email: leaderboardEmailInput
                            )
                            if sharingManager.leaderboardOptIn {
                                justJoinedLeaderboard = true
                                leaderboardUsernameInput = ""
                                leaderboardEmailInput = ""
                            } else if let error = sharingManager.lastError {
                                leaderboardError = error
                                sharingManager.lastError = nil
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isUsernameValid || !isEmailValid)
                }
            }
        }
    }

    private func saveLeaderboardUsername() {
        let name = editedLeaderboardUsername.trimmingCharacters(in: .whitespaces)
        guard name.count >= 3, name.count <= 15,
              name.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil else {
            leaderboardError = "Username must be 3-15 characters (letters, numbers, underscore)"
            return
        }
        leaderboardError = ""
        Task {
            await sharingManager.updateLeaderboardUsername(name)
            if sharingManager.lastError == nil {
                isEditingLeaderboardUsername = false
            } else {
                leaderboardError = sharingManager.lastError ?? ""
                sharingManager.lastError = nil
            }
        }
    }
}

// MARK: - Sound Tab

struct SoundTab: View {
    @AppStorage("soundEnabled") private var soundEnabled = false
    @AppStorage("soundVolume") private var soundVolume = 0.5

    var body: some View {
        Form {
            Toggle("Flap Click Sound", isOn: $soundEnabled)
            if soundEnabled {
                HStack {
                    Text("Volume")
                    Slider(value: $soundVolume, in: 0...1)
                }

                Button("Preview Sound") {
                    FlapSoundEngine.shared.playFlap()
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onChange(of: soundEnabled) { _, newValue in
            FlapSoundEngine.shared.enabled = newValue
        }
        .onChange(of: soundVolume) { _, newValue in
            FlapSoundEngine.shared.volume = newValue
        }
    }
}

// MARK: - Display Tab

struct DisplayTab: View {
    @AppStorage("animationSpeed") private var animationSpeed = 1.0
    @AppStorage("theme") private var theme = "classicAmber"

    var body: some View {
        Form {
            Section("Animation") {
                HStack {
                    Text("Speed")
                    Slider(value: $animationSpeed, in: 0.5...3.0, step: 0.25)
                    Text(String(format: "%.1fx", animationSpeed))
                        .monospacedDigit()
                        .frame(width: 40)
                }
            }

            Section("Color Theme") {
                Picker("Theme", selection: $theme) {
                    ForEach(SplitFlapTheme.allCases) { t in
                        HStack {
                            Circle()
                                .fill(t.characterColor)
                                .frame(width: 12, height: 12)
                            Text(t.displayName)
                        }
                        .tag(t.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - About Tab

struct AboutTab: View {
    @StateObject private var appVersion = AppVersion()
    @State private var isUpdating = false
    @State private var updateResult: String?

    var body: some View {
        Form {
            Section("Version") {
                HStack {
                    Text("Build")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(appVersion.localHash)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Date")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(appVersion.localDate)
                        .font(.system(.body, design: .monospaced))
                }

                if appVersion.updateAvailable, let remote = appVersion.remoteHash {
                    HStack {
                        Circle()
                            .fill(Color(hex: 0xc0a030))
                            .frame(width: 6, height: 6)
                        Text("Update available")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(remote)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }

                    Button {
                        isUpdating = true
                        updateResult = nil
                        Task {
                            let success = await appVersion.performUpdate()
                            updateResult = success ? "Updated — restart to apply" : "Update failed — try `tokenbox update` in terminal"
                            isUpdating = false
                        }
                    } label: {
                        if isUpdating {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Update Now")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(isUpdating)

                    if let result = updateResult {
                        Text(result)
                            .font(.caption)
                            .foregroundColor(result.contains("restart") ? .green : .red)
                    }
                } else if !appVersion.updateAvailable {
                    HStack {
                        Image(systemName: "checkmark.circle")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("Up to date")
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Text("GitHub")
                        .foregroundColor(.secondary)
                    Spacer()
                    Link("h-kronick/tokenbox", destination: URL(string: "https://github.com/h-kronick/tokenbox")!)
                        .font(.system(.body, design: .monospaced))
                }
                HStack {
                    Text("Site")
                        .foregroundColor(.secondary)
                    Spacer()
                    Link("tokenbox.club", destination: URL(string: "https://tokenbox.club")!)
                        .font(.system(.body, design: .monospaced))
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task {
            appVersion.load()
            await appVersion.checkForUpdate()
        }
    }
}
