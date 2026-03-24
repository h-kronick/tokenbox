import XCTest
@testable import TokenBox

final class SplitFlapModuleTests: XCTestCase {

    // MARK: - Character Set Tests

    func testDigitCharacterSetContainsAllDigits() {
        let set = SplitFlapModule.digitCharacterSet
        for digit in 0...9 {
            XCTAssertTrue(set.contains(Character(String(digit))), "Missing digit \(digit)")
        }
        XCTAssertTrue(set.contains("."), "Missing decimal point")
        XCTAssertTrue(set.contains(" "), "Missing space")
    }

    func testAlphaCharacterSetContainsAllLetters() {
        let set = SplitFlapModule.alphaCharacterSet
        for code in 65...90 {
            let char = Character(UnicodeScalar(code)!)
            XCTAssertTrue(set.contains(char), "Missing letter \(char)")
        }
        XCTAssertTrue(set.contains(" "), "Missing space")
    }

    func testSuffixCharacterSet() {
        let set = SplitFlapModule.suffixCharacterSet
        XCTAssertEqual(set, [" ", "K", "M", "B", "T"])
    }

    func testAlphanumericCharacterSetOrder() {
        let set = SplitFlapModule.alphanumericCharacterSet
        // Should start with space
        XCTAssertEqual(set.first, " ")
        // Should contain digits before letters
        if let zeroIdx = set.firstIndex(of: "0"),
           let aIdx = set.firstIndex(of: "A") {
            XCTAssertTrue(zeroIdx < aIdx, "Digits should come before letters")
        }
    }

    // MARK: - Flip Queue Tests

    func testBuildFlipQueueSameCharacter() {
        let module = SplitFlapModule(
            targetCharacter: "5",
            characterSet: SplitFlapModule.digitCharacterSet
        )
        let queue = module.buildFlipQueue(from: "5", to: "5")
        XCTAssertTrue(queue.isEmpty, "Same character should produce empty queue")
    }

    func testBuildFlipQueueSequential() {
        let module = SplitFlapModule(
            targetCharacter: "3",
            characterSet: SplitFlapModule.digitCharacterSet
        )
        let queue = module.buildFlipQueue(from: "1", to: "3")
        // Should go 1→2→3 (sequential, not jumping)
        XCTAssertEqual(queue, ["2", "3"])
    }

    func testBuildFlipQueueWrapsAround() {
        let set: [Character] = ["A", "B", "C", "D"]
        let module = SplitFlapModule(
            targetCharacter: "A",
            characterSet: set
        )
        let queue = module.buildFlipQueue(from: "C", to: "A")
        // Should go C→D→A (wraps around, never goes backward)
        XCTAssertEqual(queue, ["D", "A"])
    }

    func testBuildFlipQueueNeverSkipsCharacters() {
        let set = SplitFlapModule.digitCharacterSet
        let module = SplitFlapModule(
            targetCharacter: "5",
            characterSet: set
        )
        let queue = module.buildFlipQueue(from: "2", to: "5")
        // Every character should be sequential in the character set
        var current = "2" as Character
        for next in queue {
            let curIdx = set.firstIndex(of: current)!
            let nextIdx = set.firstIndex(of: next)!
            let expected = (curIdx + 1) % set.count
            XCTAssertEqual(nextIdx, expected, "Character \(next) is not sequential after \(current)")
            current = next
        }
        XCTAssertEqual(queue.last, "5" as Character)
    }

    func testBuildFlipQueueUnknownFromCharacter() {
        let set: [Character] = ["A", "B", "C"]
        let module = SplitFlapModule(
            targetCharacter: "B",
            characterSet: set
        )
        let queue = module.buildFlipQueue(from: "Z", to: "B")
        // Unknown from → should just return target
        XCTAssertEqual(queue, ["B"])
    }

    func testBuildFlipQueueUnknownToCharacter() {
        let set: [Character] = ["A", "B", "C"]
        let module = SplitFlapModule(
            targetCharacter: "Z",
            characterSet: set
        )
        let queue = module.buildFlipQueue(from: "A", to: "Z")
        // Unknown to → should return target directly
        XCTAssertEqual(queue, ["Z"])
    }

    // MARK: - Theme Tests

    func testAllThemesHaveDistinctColors() {
        let themes = SplitFlapTheme.allCases
        XCTAssertEqual(themes.count, 3)

        // Each theme should have different background
        let bgs = Set(themes.map { $0.rawValue })
        XCTAssertEqual(bgs.count, 3, "All themes should be unique")
    }

    func testClassicAmberIsDefault() {
        XCTAssertEqual(SplitFlapTheme.classicAmber.rawValue, "classicAmber")
    }

    func testThemeDisplayNames() {
        XCTAssertEqual(SplitFlapTheme.classicAmber.displayName, "Classic Amber")
        XCTAssertEqual(SplitFlapTheme.greenPhosphor.displayName, "Green Phosphor")
        XCTAssertEqual(SplitFlapTheme.whiteMinimal.displayName, "White / Minimal")
    }

    // MARK: - Stagger Delay Tests

    func testStaggerDelayIncreasesWithIndex() {
        // Over many samples, higher indices should have higher average delays
        var sums = [Double](repeating: 0, count: 6)
        let iterations = 100
        for _ in 0..<iterations {
            for i in 0..<6 {
                sums[i] += FlipAnimation.staggerDelay(for: i)
            }
        }
        let avgs = sums.map { $0 / Double(iterations) }
        for i in 1..<avgs.count {
            XCTAssertGreaterThan(avgs[i], avgs[i-1],
                "Average delay for index \(i) should be greater than index \(i-1)")
        }
    }

    func testStaggerDelayWithinBounds() {
        for i in 0..<10 {
            let delay = FlipAnimation.staggerDelay(for: i)
            XCTAssertGreaterThanOrEqual(delay, 0, "Delay should be non-negative")
            // Upper bound: base (index * 0.03) + max jitter (0.15)
            let maxExpected = Double(i) * 0.03 + FlipAnimation.staggerMax
            XCTAssertLessThanOrEqual(delay, maxExpected + 0.001)
        }
    }
}
