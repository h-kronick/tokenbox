import SwiftUI

/// A horizontal row of SplitFlapModules with staggered animation timing.
struct SplitFlapRow: View {
    let text: String
    let characterSet: [Character]
    let moduleCount: Int
    /// Optional per-position character sets. When provided, overrides `characterSet`
    /// for each module position, enabling minimal cycling per flap.
    var perPositionSets: [[Character]]? = nil
    var theme: SplitFlapTheme = .classicAmber
    var animationSpeed: Double = 1.0
    var soundEnabled: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<moduleCount, id: \.self) { index in
                SplitFlapModule(
                    targetCharacter: characterAt(index),
                    characterSet: characterSetFor(index),
                    flipDuration: FlipAnimation.defaultFlipDuration,
                    startDelay: FlipAnimation.staggerDelay(for: index),
                    theme: theme,
                    animationSpeed: animationSpeed,
                    soundEnabled: soundEnabled
                )
            }
        }
    }

    private func characterSetFor(_ index: Int) -> [Character] {
        if let sets = perPositionSets, index < sets.count {
            return sets[index]
        }
        return characterSet
    }

    private func characterAt(_ index: Int) -> Character {
        let chars = Array(text)
        if index < chars.count {
            return chars[index]
        }
        return " "
    }
}
