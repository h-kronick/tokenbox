import SwiftUI

/// Content view shown when clicking the menu bar icon.
struct MenuBarView: View {
    @ObservedObject var state: MenuBarState
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme") private var themeRawValue: String = SplitFlapTheme.classicAmber.rawValue

    private var theme: SplitFlapTheme {
        SplitFlapTheme(rawValue: themeRawValue) ?? .classicAmber
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Token count header
            VStack(alignment: .leading, spacing: 4) {
                Text(formatCompactTokens(state.displayTokens))
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundColor(theme.characterColor)
                Text("output tokens \(periodLabel(state.displayLabel))")
                    .font(.caption)
                    .foregroundColor(theme.sectionLabel)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)

            themedDivider

            // Status indicator
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isLive ? Color(hex: 0x33ff66) : Color(hex: 0x555555))
                    .frame(width: 8, height: 8)
                Text(state.isLive ? "Live" : "Idle")
                    .font(.caption)
                    .foregroundColor(theme.sectionLabel)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            themedDivider

            // Menu items
            MenuBarMenuItem(title: "Open TokenBox", icon: "rectangle.split.2x1", shortcut: "O", theme: theme) {
                dismiss()
                NSApp.activate(ignoringOtherApps: true)
                if let delegate = NSApp.delegate as? AppDelegate {
                    delegate.mainWindow?.makeKeyAndOrderFront(nil)
                }
            }

            MenuBarMenuItem(title: "Preferences…", icon: "gear", shortcut: "⌘,", theme: theme) {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        for window in NSApp.windows where window.title.contains("Settings") || window.title.contains("Preferences") {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }
            }

            themedDivider

            MenuBarMenuItem(title: "Quit TokenBox", icon: "power", shortcut: "⌘Q", theme: theme) {
                NSApplication.shared.terminate(nil)
            }

            Spacer().frame(height: 4)
        }
        .frame(width: 220)
        .background(theme.windowChrome)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            // Bring the main window forward alongside the dropdown
            if let delegate = NSApp.delegate as? AppDelegate,
               let window = delegate.mainWindow {
                window.orderFront(nil)
            }
        }
    }

    private func periodLabel(_ key: String) -> String {
        switch key {
        case "week": return "this week"
        case "month": return "this month"
        case "allTime": return "all time"
        default: return "today"
        }
    }

    private var themedDivider: some View {
        Rectangle()
            .fill(theme.subtleDivider)
            .frame(height: 1)
            .padding(.horizontal, 8)
    }
}

/// A single menu bar menu item with hover effect.
struct MenuBarMenuItem: View {
    let title: String
    let icon: String
    let shortcut: String
    let theme: SplitFlapTheme
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 16)
                    .foregroundColor(theme.sectionLabel)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundColor(theme.isDark ? .white : .primary)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 11))
                    .foregroundColor(theme.sectionLabel.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovered ? theme.cardBackground : Color.clear)
                    .padding(.horizontal, 4)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in isHovered = hovering }
    }
}
