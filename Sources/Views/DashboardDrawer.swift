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
