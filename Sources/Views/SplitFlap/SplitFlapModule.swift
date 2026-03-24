import SwiftUI

/// A single split-flap character module. Animates through its character set
/// sequentially to reach the target — never jumps directly.
///
/// The animation replicates a physical split-flap mechanism:
/// 1. Top half of current character folds down (easeIn)
/// 2. Bottom half of next character swings into place (easeOut)
/// 3. Repeat until target character is reached
struct SplitFlapModule: View {
    let targetCharacter: Character
    let characterSet: [Character]
    var flipDuration: TimeInterval = 0.08
    var startDelay: TimeInterval = 0
    var theme: SplitFlapTheme = .classicAmber
    var animationSpeed: Double = 1.0
    var soundEnabled: Bool = true

    @State private var currentCharacter: Character = " "
    @State private var nextCharacter: Character = " "
    @State private var topAngle: Double = 0
    @State private var bottomAngle: Double = 90
    @State private var flipQueue: [Character] = []
    @State private var generation: Int = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var effectiveDuration: TimeInterval {
        flipDuration / max(animationSpeed, 0.1)
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let halfH = h / 2
            let fontSize = h * 0.65
            let inset: CGFloat = 3

            ZStack {
                // Module housing
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.flapBackground)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

                VStack(spacing: 0) {
                    // === TOP HALF ===
                    ZStack {
                        // Static: top of next char (revealed as current top folds away)
                        characterHalf(nextCharacter, fontSize: fontSize,
                                      width: w - inset * 2, height: h - inset * 2, isTop: true)

                        // Animated: top of current char (folds down around hinge)
                        characterHalf(currentCharacter, fontSize: fontSize,
                                      width: w - inset * 2, height: h - inset * 2, isTop: true)
                            .rotation3DEffect(
                                .degrees(topAngle),
                                axis: (1, 0, 0),
                                anchor: .bottom,
                                perspective: 0.3
                            )
                            .opacity(topAngle < -89 ? 0 : 1)
                    }
                    .frame(height: halfH - 0.75)
                    .clipped()

                    // === HINGE ===
                    Rectangle()
                        .fill(theme.hingeColor)
                        .frame(height: 1.5)
                        .shadow(color: .black.opacity(0.4), radius: 0.5, y: 0.5)

                    // === BOTTOM HALF ===
                    ZStack {
                        // Static: bottom of current char (visible until covered)
                        characterHalf(currentCharacter, fontSize: fontSize,
                                      width: w - inset * 2, height: h - inset * 2, isTop: false)

                        // Animated: bottom of next char (swings from behind into place)
                        characterHalf(nextCharacter, fontSize: fontSize,
                                      width: w - inset * 2, height: h - inset * 2, isTop: false)
                            .rotation3DEffect(
                                .degrees(bottomAngle),
                                axis: (1, 0, 0),
                                anchor: .top,
                                perspective: 0.3
                            )
                            .opacity(bottomAngle > 89 ? 0 : 1)
                    }
                    .frame(height: halfH - 0.75)
                    .clipped()
                }
                .padding(inset)

                // Inner border for depth
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(theme.hingeColor.opacity(0.3), lineWidth: 0.5)
            }
        }
        .aspectRatio(0.65, contentMode: .fit)
        .accessibilityLabel(Text(String(currentCharacter)))
        .onAppear {
            if reduceMotion {
                currentCharacter = targetCharacter
                nextCharacter = targetCharacter
            } else {
                scheduleFlipSequence()
            }
        }
        .onChange(of: targetCharacter) { _, _ in
            scheduleFlipSequence()
        }
    }

    // MARK: - Character Half Rendering

    /// Renders the top or bottom half of a character on a flap background.
    /// Uses frame alignment + clipping to split the character at the midpoint.
    private func characterHalf(_ char: Character, fontSize: CGFloat,
                               width: CGFloat, height: CGFloat, isTop: Bool) -> some View {
        Text(String(char))
            .font(.system(size: fontSize, weight: .bold, design: .monospaced))
            .foregroundColor(theme.characterColor)
            .frame(width: width, height: height)
            .background(theme.flapBackground)
            .frame(height: height / 2, alignment: isTop ? .top : .bottom)
            .clipped()
    }

    // MARK: - Animation Logic

    private func scheduleFlipSequence() {
        generation += 1
        let gen = generation

        if reduceMotion {
            currentCharacter = targetCharacter
            nextCharacter = targetCharacter
            return
        }

        // Snap to clean state before starting new sequence
        topAngle = 0
        bottomAngle = 90

        let queue = buildFlipQueue(from: currentCharacter, to: targetCharacter)
        guard !queue.isEmpty else { return }

        flipQueue = queue

        let delay = startDelay / max(animationSpeed, 0.1)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard generation == gen else { return }
            processNextFlip(generation: gen)
        }
    }

    private func processNextFlip(generation gen: Int) {
        guard generation == gen, !flipQueue.isEmpty else { return }

        let next = flipQueue.removeFirst()
        nextCharacter = next
        topAngle = 0
        bottomAngle = 90

        let halfDuration = effectiveDuration * 0.5

        // Phase 1: Top half folds down
        withAnimation(.easeIn(duration: halfDuration)) {
            topAngle = -90
        } completion: {
            guard generation == gen else { return }

            // Phase 2: Bottom half swings into place
            withAnimation(.easeOut(duration: halfDuration)) {
                bottomAngle = 0
            } completion: {
                guard generation == gen else { return }

                // Play flap click when the flap lands
                if soundEnabled {
                    FlapSoundEngine.shared.playFlap()
                }

                // Advance to completed state
                currentCharacter = next
                nextCharacter = next
                topAngle = 0
                bottomAngle = 90

                // Continue with next character in queue
                processNextFlip(generation: gen)
            }
        }
    }

    /// Build the sequential queue of characters from current to target.
    /// Characters cycle forward only through the character set (like a real drum).
    func buildFlipQueue(from: Character, to: Character) -> [Character] {
        guard from != to else { return [] }
        guard let fromIdx = characterSet.firstIndex(of: from) else {
            return [to]
        }
        guard characterSet.contains(to) else {
            return [to]
        }

        var queue: [Character] = []
        var idx = fromIdx
        for _ in 0..<characterSet.count {
            idx = (idx + 1) % characterSet.count
            queue.append(characterSet[idx])
            if characterSet[idx] == to { break }
        }
        return queue
    }
}

// MARK: - Character Sets

extension SplitFlapModule {
    /// Digits 0-9, decimal point, and space (blank). Space first for drum wrap.
    static let digitCharacterSet: [Character] = {
        var chars: [Character] = [" "]
        chars.append(contentsOf: (0...9).map { Character(String($0)) })
        chars.append(".")
        return chars
    }()

    /// Uppercase A-Z and space. Space first for drum wrap.
    static let alphaCharacterSet: [Character] = {
        var chars: [Character] = [" "]
        chars.append(contentsOf: (65...90).map { Character(UnicodeScalar($0)) })
        return chars
    }()

    /// Full alphanumeric: space, 0-9, A-Z, decimal point.
    static let alphanumericCharacterSet: [Character] = {
        var chars: [Character] = [" "]
        chars.append(contentsOf: (0...9).map { Character(String($0)) })
        chars.append(contentsOf: (65...90).map { Character(UnicodeScalar($0)) })
        chars.append(".")
        return chars
    }()

    /// Suffix magnitudes: space, K, M, B, T.
    static let suffixCharacterSet: [Character] = [" ", "K", "M", "B", "T"]
}
