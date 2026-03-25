import SwiftUI
import Charts

/// Dashboard drawer that slides out from the right edge of the main window.
struct DashboardDrawer: View {
    @EnvironmentObject var dataStore: TokenDataStore
    @EnvironmentObject var sharingManager: SharingManager
    @AppStorage("theme") private var themeRawValue: String = SplitFlapTheme.classicAmber.rawValue

    private var theme: SplitFlapTheme {
        SplitFlapTheme(rawValue: themeRawValue) ?? .classicAmber
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Timeline chart — last 30 days
                Text("DAILY TOKENS")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1)
                    .foregroundColor(theme.sectionLabel)

                TimelineChartView(data: dataStore.dailyHistory, accentColor: theme.characterColor)
                    .frame(height: 120)

                themedDivider

                // Model breakdown
                Text("MODEL BREAKDOWN")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1)
                    .foregroundColor(theme.sectionLabel)

                ModelBreakdownBar(data: dataStore.modelBreakdown)
                    .frame(height: 24)

                themedDivider

                // Cache efficiency
                Text("CACHE EFFICIENCY")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1)
                    .foregroundColor(theme.sectionLabel)

                CacheEfficiencyRing(efficiency: dataStore.cacheEfficiency, accentColor: theme.characterColor)
                    .frame(height: 80)

                themedDivider

                // Top projects
                Text("TOP PROJECTS")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1)
                    .foregroundColor(theme.sectionLabel)

                TopProjectsList(projects: dataStore.topProjects, accentColor: theme.characterColor)

                // Friends section
                if !sharingManager.friends.isEmpty {
                    themedDivider

                    Text("FRIENDS")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .tracking(1)
                        .foregroundColor(theme.sectionLabel)

                    FriendsSection(friends: sharingManager.friends, theme: theme)
                }

                // Leaderboard section
                LeaderboardDrawerSection(theme: theme)
                    .environmentObject(sharingManager)
            }
            .padding(16)
        }
        .background(theme.windowChrome)
    }

    private var themedDivider: some View {
        Rectangle()
            .fill(theme.subtleDivider)
            .frame(height: 1)
    }
}

// MARK: - Friends Section

struct FriendsSection: View {
    let friends: [CloudFriend]
    let theme: SplitFlapTheme

    var body: some View {
        VStack(spacing: 8) {
            ForEach(friends) { friend in
                DashboardFriendRow(friend: friend, theme: theme)
            }
        }
    }
}

struct DashboardFriendRow: View {
    let friend: CloudFriend
    let theme: SplitFlapTheme

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(theme.isDark ? .white : .primary)
                Text("\(formatCompactTokens(friend.todayTokens)) today")
                    .font(.caption2)
                    .foregroundColor(theme.sectionLabel)
            }
            Spacer()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardBackground))
    }
}

// MARK: - Leaderboard Section

struct LeaderboardDrawerSection: View {
    @EnvironmentObject var sharingManager: SharingManager
    let theme: SplitFlapTheme
    @State private var leaderboardModel: String = "opus"

    private static let utcDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    var body: some View {
        if !sharingManager.leaderboardEntries.isEmpty || sharingManager.leaderboardOptIn {
            Rectangle()
                .fill(theme.subtleDivider)
                .frame(height: 1)

            HStack {
                Text("LEADERBOARD")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .tracking(1)
                    .foregroundColor(theme.sectionLabel)
                Spacer()
                Text(Self.utcDateFormatter.string(from: Date()))
                    .font(.caption2)
                    .foregroundColor(theme.sectionLabel)
            }

            if sharingManager.leaderboardEntries.isEmpty {
                if sharingManager.leaderboardOptIn {
                    Text("No leaderboard data")
                        .font(.caption)
                        .foregroundColor(theme.sectionLabel)
                } else {
                    Text("Join in Settings →")
                        .font(.caption)
                        .foregroundColor(theme.sectionLabel)
                }
            } else {
                VStack(spacing: 4) {
                    ForEach(sharingManager.leaderboardEntries) { entry in
                        HStack(spacing: 4) {
                            Text(String(format: "%2d.", entry.rank))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(entry.isMe ? theme.characterColor : (theme.isDark ? .white : .primary))
                                .frame(width: 28, alignment: .trailing)
                            Text(entry.username)
                                .font(.system(.caption, design: .monospaced))
                                .fontWeight(entry.isMe ? .bold : .regular)
                                .foregroundColor(entry.isMe ? theme.characterColor : (theme.isDark ? .white : .primary))
                                .lineLimit(1)
                            Spacer()
                            Text(formatCompactTokens(entry.tokens))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(entry.isMe ? theme.characterColor : (theme.isDark ? .white : .primary))
                            if entry.optedIn {
                                Text("✓")
                                    .font(.caption2)
                                    .foregroundColor(.green)
                            }
                            if entry.isMe {
                                Text("← you")
                                    .font(.caption2)
                                    .foregroundColor(theme.characterColor)
                            }
                        }
                        .padding(.vertical, 2)
                        .padding(.horizontal, 8)
                        .background(
                            entry.isMe
                                ? RoundedRectangle(cornerRadius: 4).fill(theme.characterColor.opacity(0.1))
                                : nil
                        )
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(theme.cardBackground))
            }

            // Model tabs
            HStack(spacing: 12) {
                ForEach(["opus", "sonnet", "haiku"], id: \.self) { model in
                    Button {
                        leaderboardModel = model
                        Task {
                            await sharingManager.fetchLeaderboard(model: model)
                        }
                    } label: {
                        Text(model.capitalized)
                            .font(.caption)
                            .fontWeight(leaderboardModel == model ? .bold : .regular)
                            .foregroundColor(leaderboardModel == model ? theme.characterColor : theme.sectionLabel)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
