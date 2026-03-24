import SwiftUI

/// Simple friends list view. Used in the dashboard drawer if present.
struct FriendsView: View {
    @EnvironmentObject var sharingManager: SharingManager

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Friends")
                .font(.title2)
                .fontWeight(.semibold)

            if sharingManager.friends.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "person.2.slash")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No friends yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Add a friend's share code in Settings > Sharing.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(sharingManager.friends) { friend in
                            CloudFriendCard(friend: friend)
                                .contextMenu {
                                    Button("Remove Friend", role: .destructive) {
                                        sharingManager.removeFriend(friend.shareCode)
                                    }
                                }
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 320, minHeight: 400)
    }
}

// MARK: - Friend Card

struct CloudFriendCard: View {
    let friend: CloudFriend

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "person.circle.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text(friend.displayName)
                    .font(.headline)
                Spacer()
                Text(formatCompactTokens(friend.todayTokens))
                    .font(.system(.body, design: .monospaced))
                    .fontWeight(.semibold)
            }
            HStack(spacing: 16) {
                Label(friend.shareCode, systemImage: "number")
                if !friend.todayDate.isEmpty {
                    Label(friend.todayDate, systemImage: "calendar")
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(10)
    }
}
