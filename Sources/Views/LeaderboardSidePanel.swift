import SwiftUI

/// Slide-out leaderboard panel that appears to the right of the main split-flap display.
/// Shows either an opt-in form (State A) or the live leaderboard (State B).
struct LeaderboardSidePanel: View {
    @EnvironmentObject var sharingManager: SharingManager
    let theme: SplitFlapTheme

    @State private var usernameInput = ""
    @State private var emailInput = ""
    @State private var isJoining = false
    @State private var joinError = ""
    @State private var selectedModel = "opus"
    @State private var isLoading = false

    private let panelWidth: CGFloat = 210

    private static let pstDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "America/Los_Angeles")
        return f
    }()

    private var primaryText: Color {
        theme.isDark ? .white : .primary
    }

    private var isUsernameValid: Bool {
        let t = usernameInput.trimmingCharacters(in: .whitespaces)
        return t.count >= 3 && t.count <= 15 && t.range(of: "^[a-zA-Z0-9_]+$", options: .regularExpression) != nil
    }

    private var isEmailValid: Bool {
        let t = emailInput.trimmingCharacters(in: .whitespaces)
        return t.contains("@") && t.contains(".")
    }

    var body: some View {
        VStack(spacing: 0) {
            if sharingManager.leaderboardOptIn {
                leaderboardView
            } else {
                optInView
            }
        }
        .frame(width: panelWidth)
        .background(theme.windowChrome)
    }

    // MARK: - State A: Opt-in form

    private var optInView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "trophy")
                    .font(.system(size: 11))
                    .foregroundColor(theme.characterColor)
                Text("DAILY LEADERBOARD")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1)
                    .foregroundColor(theme.sectionLabel)
            }

            Text("Compete on the public daily output token leaderboard. Only your username and token count are visible.")
                .font(.system(size: 10))
                .foregroundColor(theme.sectionLabel)
                .fixedSize(horizontal: false, vertical: true)

            if !sharingManager.isRegistered || !sharingManager.sharingEnabled {
                // Need sharing enabled first
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 9))
                    Text("Enable sharing first")
                        .font(.system(size: 10))
                }
                .foregroundColor(theme.characterColor.opacity(0.7))
                .padding(.vertical, 4)
            } else {
                // Username field
                VStack(alignment: .leading, spacing: 3) {
                    Text("Username")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.sectionLabel)
                    TextField("pick_a_name", text: $usernameInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .controlSize(.small)
                    if !usernameInput.isEmpty && !isUsernameValid {
                        Text("3-15 chars: a-z, 0-9, _")
                            .font(.system(size: 8))
                            .foregroundColor(.red)
                    }
                }

                // Email field
                VStack(alignment: .leading, spacing: 3) {
                    Text("Email")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.sectionLabel)
                    TextField("you@example.com", text: $emailInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                        .controlSize(.small)
                    Text("Private -- never shown")
                        .font(.system(size: 8))
                        .foregroundColor(theme.sectionLabel.opacity(0.7))
                }

                if !joinError.isEmpty {
                    Text(joinError)
                        .font(.system(size: 9))
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Join button
                Button {
                    joinLeaderboard()
                } label: {
                    if isJoining {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Join")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isUsernameValid || !isEmailValid || isJoining)
            }

            Spacer()
        }
        .padding(12)
    }

    // MARK: - State B: Live leaderboard

    private var leaderboardView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header with date
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 11))
                        .foregroundColor(theme.characterColor)
                    Text("LEADERBOARD")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(1)
                        .foregroundColor(theme.sectionLabel)
                    Spacer()
                    Button {
                        Task {
                            isLoading = true
                            await sharingManager.fetchLeaderboard(model: selectedModel)
                            isLoading = false
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(theme.sectionLabel.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh leaderboard")
                }

                Text(Self.pstDateFormatter.string(from: Date()) + " PST")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.sectionLabel.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Model tabs
            HStack(spacing: 0) {
                ForEach(["opus", "sonnet", "haiku"], id: \.self) { model in
                    Button {
                        selectedModel = model
                        sharingManager.leaderboardModel = model
                        Task {
                            isLoading = true
                            await sharingManager.fetchLeaderboard(model: model)
                            isLoading = false
                        }
                    } label: {
                        Text(model.capitalized)
                            .font(.system(size: 9, weight: selectedModel == model ? .bold : .regular))
                            .foregroundColor(selectedModel == model ? theme.characterColor : theme.sectionLabel)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)

            Rectangle()
                .fill(theme.subtleDivider)
                .frame(height: 1)
                .padding(.horizontal, 12)

            // Entries list
            if isLoading {
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                Spacer()
            } else if sharingManager.leaderboardEntries.isEmpty {
                Spacer()
                VStack(spacing: 6) {
                    Text("No entries yet")
                        .font(.system(size: 11))
                        .foregroundColor(theme.sectionLabel)
                    Text("Be the first!")
                        .font(.system(size: 10))
                        .foregroundColor(theme.sectionLabel.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 1) {
                        ForEach(sharingManager.leaderboardEntries) { entry in
                            leaderboardRow(entry)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
            }

            // Footer: own username
            if !sharingManager.leaderboardUsername.isEmpty {
                Rectangle()
                    .fill(theme.subtleDivider)
                    .frame(height: 1)
                    .padding(.horizontal, 12)

                HStack(spacing: 4) {
                    Text("@\(sharingManager.leaderboardUsername)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(theme.characterColor)
                    Spacer()
                    Text("Opted In")
                        .font(.system(size: 8))
                        .foregroundColor(.green.opacity(0.8))
                    Circle()
                        .fill(.green)
                        .frame(width: 4, height: 4)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
        }
        .task {
            sharingManager.leaderboardModel = selectedModel
            isLoading = true
            await sharingManager.fetchLeaderboard(model: selectedModel)
            isLoading = false
        }
    }

    // MARK: - Row

    private func leaderboardRow(_ entry: LeaderboardEntry) -> some View {
        let textColor = entry.isMe ? theme.characterColor : primaryText

        return HStack(spacing: 4) {
            Text("\(entry.rank).")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(textColor)
                .frame(width: 22, alignment: .trailing)

            Text("@\(entry.username)")
                .font(.system(size: 10, weight: entry.isMe ? .bold : .regular, design: .monospaced))
                .foregroundColor(textColor)
                .lineLimit(1)

            Spacer(minLength: 4)

            Text(formatCompactTokens(entry.tokens))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(textColor)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            entry.isMe
                ? RoundedRectangle(cornerRadius: 4).fill(theme.characterColor.opacity(0.1))
                : nil
        )
    }

    // MARK: - Actions

    private func joinLeaderboard() {
        joinError = ""
        isJoining = true
        Task {
            await sharingManager.joinLeaderboard(
                username: usernameInput,
                email: emailInput
            )
            if sharingManager.leaderboardOptIn {
                usernameInput = ""
                emailInput = ""
                joinError = ""
            } else if let error = sharingManager.lastError {
                joinError = error
                sharingManager.lastError = nil
            }
            isJoining = false
        }
    }
}
