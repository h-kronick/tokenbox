import SwiftUI

/// The dark container that houses the split-flap display rows.
/// Provides the 3D-ish container appearance with inset shadow, border, and depth.
struct SplitFlapHousing<Content: View>: View {
    var theme: SplitFlapTheme = .classicAmber
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(theme.housingColor)
                .shadow(color: .black.opacity(0.5), radius: 12, x: 0, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(theme.hingeColor.opacity(0.4), lineWidth: 1)
        )
        .padding(12)
        .background(theme.backgroundColor)
    }
}
