import SwiftUI

/// The main window containing the split-flap display and period toolbar.
struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var dataStore: TokenDataStore
    @EnvironmentObject var sharingManager: SharingManager

    @AppStorage("theme") private var themeRawValue: String = SplitFlapTheme.classicAmber.rawValue
    @AppStorage("soundEnabled") private var soundEnabled: Bool = false
    @AppStorage("animationSpeed") private var animationSpeed: Double = 1.0

    @State private var showCopied = false
    @State private var showSharePopover = false
    @State private var isRegistering = false
    @State private var justRegistered = false
    @State private var showLeaderboard = false
    @State private var showUpdatePopover = false
    @State private var showAddFriend = false
    @State private var addFriendInput = ""
    @State private var addFriendError = ""
    @State private var isAddingFriend = false
    @State private var addFriendSuccess = false
    @StateObject private var updateChecker = UpdateChecker()

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                SplitFlapDisplayView(
                    pinnedLabel: $appState.pinnedLabel,
                    pinnedValue: $appState.pinnedValue,
                    contextLabel: $appState.displayLabel,
                    contextValue: $appState.displayValue,
                    contextSubtitle: appState.displaySubtitle,
                    modelName: modelDisplayName,
                    theme: currentTheme,
                    soundEnabled: soundEnabled,
                    animationSpeed: animationSpeed
                )

                // Bottom bar: share action + leaderboard toggle
                HStack(spacing: 0) {
                    // Share button (left-aligned)
                    Button {
                        if sharingManager.isRegistered {
                            copyShareLink()
                        } else {
                            showSharePopover = true
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if sharingManager.isRegistered {
                                Image(systemName: showCopied ? "checkmark.circle.fill" : "link")
                                    .font(.system(size: 13))
                                Text(showCopied ? "Copied!" : sharingManager.myShareCode)
                                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                            } else {
                                Image(systemName: "person.2")
                                    .font(.system(size: 13))
                                Text("Start sharing")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .foregroundColor(showCopied ? currentTheme.characterColor : currentTheme.labelColor.opacity(0.6))
                        .animation(.easeInOut(duration: 0.2), value: showCopied)
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: $showSharePopover, arrowEdge: .bottom) {
                        sharePopoverContent
                    }

                    // Add friend button — only when registered
                    if sharingManager.isRegistered {
                        Button {
                            addFriendInput = ""
                            addFriendError = ""
                            addFriendSuccess = false
                            showAddFriend = true
                        } label: {
                            Image(systemName: "person.badge.plus")
                                .font(.system(size: 12))
                                .foregroundColor(currentTheme.labelColor.opacity(0.4))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 8)
                        .help("Add a friend")
                        .popover(isPresented: $showAddFriend, arrowEdge: .bottom) {
                            addFriendPopoverContent
                        }
                    }

                    // Linked devices indicator — subtle icon when multi-device
                    if !sharingManager.linkedDevices.isEmpty {
                        Button {
                            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "link")
                                    .font(.system(size: 10))
                                Text("\(sharingManager.linkedDevices.count)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundColor(currentTheme.characterColor.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                        .help("\(sharingManager.linkedDevices.count) linked devices")
                    }

                    Spacer()

                    // Update indicator — subtle pulsing dot + label
                    if updateChecker.updateAvailable {
                        Button {
                            showUpdatePopover = true
                        } label: {
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                Text("Update available")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.green.opacity(0.8))
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showUpdatePopover, arrowEdge: .bottom) {
                            VStack(spacing: 10) {
                                Text("New version available")
                                    .font(.system(size: 12, weight: .semibold))

                                HStack {
                                    Text("tokenbox update")
                                        .font(.system(size: 12, design: .monospaced))
                                        .padding(8)
                                        .background(Color.black.opacity(0.3))
                                        .cornerRadius(6)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString("tokenbox update", forType: .string)
                                    } label: {
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 11))
                                    }
                                    .buttonStyle(.plain)
                                }

                                Button("Dismiss") {
                                    updateChecker.dismiss()
                                    showUpdatePopover = false
                                }
                                .font(.caption)
                                .foregroundColor(.secondary)
                            }
                            .padding(16)
                            .frame(width: 220)
                        }
                    }

                    // Leaderboard toggle (right-aligned)
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showLeaderboard.toggle()
                        }
                        if showLeaderboard {
                            Task { await sharingManager.fetchLeaderboard() }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showLeaderboard ? "trophy.fill" : "trophy")
                                .font(.system(size: 12))
                            Text("Leaderboard")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundColor(showLeaderboard ? currentTheme.characterColor : currentTheme.labelColor.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
            .fixedSize()

            if showLeaderboard {
                Rectangle()
                    .fill(currentTheme.subtleDivider)
                    .frame(width: 1)

                LeaderboardSidePanel(theme: currentTheme)
                    .environmentObject(sharingManager)
                    .frame(height: nil)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .fixedSize(horizontal: true, vertical: true)
        .background(currentTheme.backgroundColor)
        .ignoresSafeArea()
        .onAppear {
            dataStore.startWatching()
            updateChecker.startChecking()
            // Give AppState direct access to data sources for rotation rebuilds
            appState.dataStore = dataStore
            appState.sharingManager = sharingManager
            appState.buildFriendsList = { [weak sharingManager, weak dataStore, weak appState] in
                guard let sm = sharingManager, let ds = dataStore, let state = appState else { return [] }
                let period = state.pinnedDisplay
                return sm.friends.map { friend in
                    let tokens: Int
                    if friend.shareCode == sm.myShareCode {
                        // Use server aggregate for self when devices linked, local data otherwise
                        if let agg = sm.aggregateTokens(for: ds.modelFilter, period: period) {
                            let delta = period == "today" ? ds.realtimeDelta : 0
                            tokens = agg + delta
                        } else {
                            switch period {
                            case "week": tokens = ds.weekTokens
                            case "month": tokens = ds.monthTokens
                            case "allTime": tokens = ds.allTimeTokens
                            default: tokens = ds.realtimeDisplayTokens
                            }
                        }
                    } else {
                        tokens = friend.tokens(for: ds.modelFilter, period: period)
                    }
                    return (name: String(friend.displayName.prefix(7)), tokens: formatTokens(tokens), lastTokenChange: friend.lastTokenChange)
                }
            }
            appState.startContextRotation()
            // Wire up periodic push with access to data store
            sharingManager.periodicPushHandler = { [weak dataStore] in
                guard let store = dataStore else { return }
                await sharingManager.pushMyTokens(
                    todayTokens: store.todayTokens,
                    todayByModel: store.todayByModel,
                    weekByModel: store.weekByModel,
                    monthByModel: store.monthByModel,
                    allTimeByModel: store.allTimeByModel,
                    force: true
                )
            }
            sharingManager.startTimers()
            refreshContext()
            // Immediate push + fetch on launch so aggregate, friends, and leaderboard
            // are available within seconds rather than waiting for the 30s timer.
            if sharingManager.sharingEnabled {
                Task {
                    await sharingManager.pushMyTokens(
                        todayTokens: dataStore.todayTokens,
                        todayByModel: dataStore.todayByModel,
                        weekByModel: dataStore.weekByModel,
                        monthByModel: dataStore.monthByModel,
                        allTimeByModel: dataStore.allTimeByModel,
                        force: true
                    )
                    async let friendsFetch: () = sharingManager.fetchAllFriends()
                    async let leaderboardFetch: () = sharingManager.fetchLeaderboard(model: sharingManager.leaderboardModel)
                    _ = await (friendsFetch, leaderboardFetch)
                    sharingManager.syncFriendsFromLeaderboard()
                    refreshContext()
                }
            }
        }
        .onDisappear {
            dataStore.stopWatching()
            updateChecker.stopChecking()
            appState.stopContextRotation()
            sharingManager.stopTimers()
        }
        .onChange(of: dataStore.todayTokens) { _, newValue in
            refreshValues()
            if sharingManager.sharingEnabled {
                Task {
                    await sharingManager.pushMyTokens(
                        todayTokens: newValue,
                        todayByModel: dataStore.todayByModel,
                        weekByModel: dataStore.weekByModel,
                        monthByModel: dataStore.monthByModel,
                        allTimeByModel: dataStore.allTimeByModel
                    )
                }
            }
        }
        .onChange(of: dataStore.realtimeDelta) { _, _ in refreshValues() }
        .onChange(of: dataStore.weekTokens) { _, _ in refreshContext() }
        .onChange(of: dataStore.monthTokens) { _, _ in refreshContext() }
        .onChange(of: dataStore.allTimeTokens) { _, _ in refreshContext() }
        .onReceive(NotificationCenter.default.publisher(for: .displaySettingsDidChange)) { _ in
            syncDisplaySettings()
            refreshContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .friendsDidChange)) { _ in
            refreshContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .serverAggregateDidChange)) { _ in
            refreshValues()
            refreshContext()
        }
        .onReceive(NotificationCenter.default.publisher(for: .displayNameDidChange)) { _ in
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

    private var currentTheme: SplitFlapTheme {
        SplitFlapTheme(rawValue: themeRawValue) ?? .classicAmber
    }

    private var modelDisplayName: String {
        guard let filter = dataStore.modelFilter else { return "All Models" }
        if filter == "opus" { return "Opus" }
        if filter == "sonnet" { return "Sonnet" }
        if filter == "haiku" { return "Haiku" }
        return filter.capitalized
    }

    @ViewBuilder
    private var sharePopoverContent: some View {
        if justRegistered {
            // Success state — show the share code with copy
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)

                Text("You're sharing as")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(sharingManager.myDisplayName.uppercased())
                    .font(.system(size: 14, weight: .bold, design: .monospaced))

                Divider()

                Text("Your share code")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(sharingManager.myShareCode)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .textSelection(.enabled)

                Button {
                    copyShareLink()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        showSharePopover = false
                        justRegistered = false
                    }
                } label: {
                    Label("Copy Share Link", systemImage: "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
            }
            .padding(16)
            .frame(width: 200)
        } else {
            // Registration state — enter name
            VStack(spacing: 10) {
                Text("Share your token count")
                    .font(.system(size: 12, weight: .medium))
                Text("Friends will see your daily total")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextField("Display name", text: $sharingManager.myDisplayName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 160)
                    .onChange(of: sharingManager.myDisplayName) { _, newValue in
                        if newValue.count > 7 {
                            sharingManager.myDisplayName = String(newValue.prefix(7))
                        }
                    }

                Button {
                    isRegistering = true
                    Task {
                        await sharingManager.register()
                        isRegistering = false
                        if sharingManager.isRegistered {
                            sharingManager.sharingEnabled = true
                            withAnimation { justRegistered = true }
                        }
                    }
                } label: {
                    if isRegistering {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Start Sharing")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(sharingManager.myDisplayName.trimmingCharacters(in: .whitespaces).isEmpty || isRegistering)

                if let error = sharingManager.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(16)
            .frame(width: 220)
        }
    }

    @ViewBuilder
    private var addFriendPopoverContent: some View {
        if addFriendSuccess {
            // Success state — auto-dismiss after a moment
            VStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.green)
                Text("Friend added!")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(16)
            .frame(width: 200)
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    showAddFriend = false
                    addFriendSuccess = false
                }
            }
        } else {
            VStack(spacing: 10) {
                Text("Add a friend")
                    .font(.system(size: 12, weight: .medium))
                Text("Paste their share code or link")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    TextField("e.g. XNBGBU", text: $addFriendInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 130)
                        .onSubmit { addFriend() }

                    Button {
                        addFriend()
                    } label: {
                        if isAddingFriend {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Add")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(addFriendInput.trimmingCharacters(in: .whitespaces).isEmpty || isAddingFriend)
                }

                if !addFriendError.isEmpty {
                    Text(addFriendError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            .frame(width: 220)
        }
    }

    private func addFriend() {
        let input = addFriendInput.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        addFriendError = ""
        isAddingFriend = true
        Task {
            do {
                try await sharingManager.addFriend(input: input)
                addFriendInput = ""
                withAnimation { addFriendSuccess = true }
            } catch {
                addFriendError = error.localizedDescription
            }
            isAddingFriend = false
        }
    }

    private func copyShareLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sharingManager.myShareURL, forType: .string)
        showCopied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showCopied = false }
    }

    /// Build the friends list with model filter, period, and self-detection applied.
    private func buildFriends() -> [(name: String, tokens: String, lastTokenChange: String?)] {
        let period = appState.pinnedDisplay
        return sharingManager.friends.map { friend in
            let tokens: Int
            if friend.shareCode == sharingManager.myShareCode {
                // Use server aggregate for self when devices linked, local data otherwise
                if let agg = sharingManager.aggregateTokens(for: dataStore.modelFilter, period: period) {
                    let delta = period == "today" ? dataStore.realtimeDelta : 0
                    tokens = agg + delta
                } else {
                    switch period {
                    case "week": tokens = dataStore.weekTokens
                    case "month": tokens = dataStore.monthTokens
                    case "allTime": tokens = dataStore.allTimeTokens
                    default: tokens = dataStore.realtimeDisplayTokens
                    }
                }
            } else {
                tokens = friend.tokens(for: dataStore.modelFilter, period: period)
            }
            return (name: String(friend.displayName.prefix(7)), tokens: formatTokens(tokens), lastTokenChange: friend.lastTokenChange)
        }
    }

    /// Sync display settings from UserDefaults into the local AppState/DataStore instances.
    /// Needed because the NSHostingView-based main window and the Settings scene may hold
    /// separate object instances — UserDefaults is the cross-window source of truth.
    private func syncDisplaySettings() {
        let storedPinned = UserDefaults.standard.string(forKey: "pinnedDisplay") ?? "today"
        if appState.pinnedDisplay != storedPinned {
            appState.pinnedDisplay = storedPinned
        }
        let storedModel = UserDefaults.standard.string(forKey: "modelFilter")
        if dataStore.modelFilter != storedModel {
            dataStore.modelFilter = storedModel
        }
    }

    /// Full rebuild of context items.
    private func refreshContext() {
        appState.updateContextItems(friends: buildFriends(), dataStore: dataStore)
    }

    /// Lightweight value refresh — only updates pinned row without rebuilding context items.
    private func refreshValues() {
        appState.refreshPinnedDisplay(dataStore: dataStore)
    }
}

/// Segmented period selector toolbar.
struct PeriodToolbar: View {
    @Binding var selectedPeriod: TimePeriod

    var body: some View {
        Picker("Period", selection: $selectedPeriod) {
            ForEach(TimePeriod.allCases) { period in
                Text(period.rawValue).tag(period)
            }
        }
        .pickerStyle(.segmented)
    }
}
