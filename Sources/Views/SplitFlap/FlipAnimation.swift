import SwiftUI

/// Shared animation constants and utilities for the split-flap display.
enum FlipAnimation {
    /// Default flip duration per character (seconds).
    static let defaultFlipDuration: TimeInterval = 0.08

    /// Stagger delay range for neighboring modules (seconds).
    static let staggerMin: TimeInterval = 0.05
    static let staggerMax: TimeInterval = 0.15

    /// Generate a stagger delay for a module at the given index.
    /// Combines a small base offset with random jitter for the cascading "waterfall" effect.
    static func staggerDelay(for index: Int) -> TimeInterval {
        let base = Double(index) * 0.03
        let jitter = Double.random(in: staggerMin...staggerMax)
        return base + jitter
    }

    /// The ease-in animation for the top half folding down.
    static func foldDown(duration: TimeInterval) -> Animation {
        .easeIn(duration: duration / 2)
    }

    /// The ease-out animation for the bottom half swinging into place.
    static func foldUp(duration: TimeInterval) -> Animation {
        .easeOut(duration: duration / 2)
    }
}
