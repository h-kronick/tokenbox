import SwiftUI

/// An e-ink style label display that replaces split-flap modules for text rows.
/// Simulates a B/W e-ink panel in inverted mode (white-on-black) viewed through
/// a tinted acrylic overlay that matches the theme's accent color.
///
/// Used for Rows 1 & 3 (pinned label, context label). Supports optional subtitle
/// text at the bottom corners (e.g. model name, reset countdown) — these render
/// on the e-ink panel itself, matching the physical device.
///
/// Physical: 2.9" B/W e-ink (296×128, 67×29mm active) behind amber acrylic.
/// The panel is narrower than the 7-module flap row below it (~57% width).
struct EInkLabelView: View {
    let text: String
    var subtitleLeft: String? = nil
    var subtitleRight: String? = nil
    var theme: SplitFlapTheme = .classicAmber

    @State private var displayText: String = ""
    @State private var isRefreshing = false
    @State private var hasAppeared = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Realistic e-ink panel colors: Waveshare 4-color (G) panel with black background
    /// and yellow pigment text. E-ink black is a warm dark charcoal (not pure black).
    /// Yellow appears more vivid on the dark background than on white paper.
    private var panelBackground: Color {
        switch theme {
        case .classicAmber: return Color(hex: 0x1a1815)   // e-ink black pigment (near-black, slight warmth)
        case .greenPhosphor: return Color(hex: 0x1a201a)
        case .whiteMinimal: return Color(hex: 0xe8e8e3)
        }
    }

    private var panelText: Color {
        switch theme {
        case .classicAmber: return Color(hex: 0xd4b830)   // e-ink yellow pigment — vibrant golden
        case .greenPhosphor: return Color(hex: 0x2ae858)
        case .whiteMinimal: return Color(hex: 0x1a1a1a)
        }
    }

    /// Subtitle text is dimmer — smaller secondary info rendered on the e-ink
    private var subtitleColor: Color {
        panelText.opacity(0.5)
    }

    private var panelBorder: Color {
        theme.hingeColor.opacity(0.6)
    }

    var body: some View {
        ZStack {
            // Panel housing — recessed e-ink screen
            RoundedRectangle(cornerRadius: 5)
                .fill(panelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(panelBorder, lineWidth: 0.75)
                )
                .shadow(color: .black.opacity(0.5), radius: 2, y: 1.5)

            VStack(spacing: 0) {
                Spacer(minLength: 3)

                // Main label text
                Text(displayText.uppercased())
                    .font(.system(size: 33, weight: .bold, design: .monospaced))
                    .tracking(9)
                    .foregroundColor(panelText)
                    .opacity(isRefreshing ? 0 : 1)

                Spacer(minLength: 2)

                // Subtitle bar (model name + resets countdown)
                if subtitleLeft != nil || subtitleRight != nil {
                    HStack {
                        if let left = subtitleLeft {
                            Text(left)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(subtitleColor)
                        }
                        Spacer()
                        if let right = subtitleRight {
                            Text(right)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundColor(subtitleColor)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.bottom, 5)
                    .opacity(isRefreshing ? 0 : 1)
                }
            }
        }
        .onAppear {
            displayText = text.trimmingCharacters(in: .whitespaces)
            hasAppeared = true
        }
        .onChange(of: text) { _, newValue in
            let trimmed = newValue.trimmingCharacters(in: .whitespaces)
            guard trimmed != displayText, hasAppeared else {
                displayText = trimmed
                return
            }
            if reduceMotion {
                displayText = trimmed
                return
            }
            // E-ink refresh: brief flash then reveal new text
            withAnimation(.easeIn(duration: 0.08)) {
                isRefreshing = true
            } completion: {
                displayText = trimmed
                withAnimation(.easeOut(duration: 0.15)) {
                    isRefreshing = false
                }
            }
        }
    }
}
