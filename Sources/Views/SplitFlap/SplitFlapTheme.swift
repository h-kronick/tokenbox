import SwiftUI

/// Color theme for the split-flap display.
enum SplitFlapTheme: String, CaseIterable, Identifiable, Codable {
    case classicAmber
    case greenPhosphor
    case whiteMinimal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classicAmber: return "Classic Amber"
        case .greenPhosphor: return "Green Phosphor"
        case .whiteMinimal: return "White / Minimal"
        }
    }

    var backgroundColor: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x141310)   // outer frame — darkest layer
        case .greenPhosphor: return Color(hex: 0x0a0f0a)
        case .whiteMinimal: return Color(hex: 0xf5f5f0)
        }
    }

    var characterColor: Color {
        switch self {
        case .classicAmber: return Color(hex: 0xd4b830)   // matched to e-ink yellow pigment
        case .greenPhosphor: return Color(hex: 0x33ff66)
        case .whiteMinimal: return Color(hex: 0x1a1a1a)
        }
    }

    var housingColor: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x282520)   // warm charcoal housing — slightly lighter than panels
        case .greenPhosphor: return Color(hex: 0x1a1f1a)
        case .whiteMinimal: return Color(hex: 0xe8e8e3)
        }
    }

    var hingeColor: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x0e0d0b)
        case .greenPhosphor: return Color(hex: 0x050805)
        case .whiteMinimal: return Color(hex: 0xd0d0cb)
        }
    }

    var flapBackground: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x1a1815)   // matches e-ink black pigment exactly
        case .greenPhosphor: return Color(hex: 0x0f140f)
        case .whiteMinimal: return Color(hex: 0xededE8)
        }
    }

    var labelColor: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x8a8070)
        case .greenPhosphor: return Color(hex: 0x558855)
        case .whiteMinimal: return Color(hex: 0x999990)
        }
    }

    var windowChrome: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x1e1e1e)
        case .greenPhosphor: return Color(hex: 0x0d120d)
        case .whiteMinimal: return Color(hex: 0xf0f0eb)
        }
    }

    var sectionLabel: Color {
        switch self {
        case .classicAmber: return Color(hex: 0xa09080)
        case .greenPhosphor: return Color(hex: 0x669966)
        case .whiteMinimal: return Color(hex: 0x888880)
        }
    }

    var subtleDivider: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x333333)
        case .greenPhosphor: return Color(hex: 0x1a2a1a)
        case .whiteMinimal: return Color(hex: 0xd8d8d3)
        }
    }

    var cardBackground: Color {
        switch self {
        case .classicAmber: return Color(hex: 0x252525)
        case .greenPhosphor: return Color(hex: 0x121a12)
        case .whiteMinimal: return Color(hex: 0xe5e5e0)
        }
    }

    var isDark: Bool {
        switch self {
        case .classicAmber, .greenPhosphor: return true
        case .whiteMinimal: return false
        }
    }
}

extension Color {
    init(hex: UInt, opacity: Double = 1.0) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
