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

                    Spacer()

                    // Leaderboard toggle (right-aligned)
                    Button {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            showLeaderboard.toggle()
                        }
                        if showLeaderboard {
                            Task { await sharingManager.fetchLeaderboard() }
                        }
                    } label: {
                        Image(systemName: showLeaderboard ? "trophy.fill" : "trophy")
                            .font(.system(size: 12))
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
            // Give AppState direct access to data sources for rotation rebuilds
            appState.dataStore = dataStore
            appState.sharingManager = sharingManager
            appState.buildFriendsList = { [weak sharingManager, weak dataStore, weak appState] in
                guard let sm = sharingManager, let ds = dataStore, let state = appState else { return [] }
                let period = state.pinnedDisplay
                return sm.friends.map { friend in
                    let tokens: Int
                    if friend.shareCode == sm.myShareCode {
                        // Use local data for self
                        switch period {
                        case "week": tokens = ds.weekTokens
                        case "month": tokens = ds.monthTokens
                        case "allTime": tokens = ds.allTimeTokens
                        default: tokens = ds.realtimeDisplayTokens
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
            // Push latest tokens and fetch friends on launch
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
                    await sharingManager.fetchAllFriends()
                    refreshContext()
                }
            }
        }
        .onDisappear {
            dataStore.stopWatching()
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
                switch period {
                case "week": tokens = dataStore.weekTokens
                case "month": tokens = dataStore.monthTokens
                case "allTime": tokens = dataStore.allTimeTokens
                default: tokens = dataStore.realtimeDisplayTokens
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
