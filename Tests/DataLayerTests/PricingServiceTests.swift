import XCTest
@testable import TokenBox

final class PricingServiceTests: XCTestCase {

    var pricing: PricingService!

    override func setUp() {
        pricing = PricingService(pricing: PricingService.defaultPricing)
    }

    func testSonnetCostEstimation() {
        // Sonnet: input=3.00, output=15.00, cache_read=0.30, cache_write=3.75 per million
        let event = TokenEvent(
            timestamp: "2026-03-19T10:00:00Z",
            source: "claude_code",
            sessionId: nil,
            project: nil,
            model: "claude-sonnet-4-6",
            inputTokens: 1_000_000,  // 1M tokens
            outputTokens: 1_000_000,
            cacheCreate: 0,
            cacheRead: 0,
            costUsd: nil
        )
        let cost = pricing.estimateCost(for: event)
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost!, 18.0, accuracy: 0.01)  // 3.00 + 15.00
    }

    func testOpusCostEstimation() {
        // Opus: input=5.00, output=25.00 per million
        let cost = pricing.estimateCost(
            model: "claude-opus-4-6",
            inputTokens: 500_000,
            outputTokens: 200_000
        )
        XCTAssertNotNil(cost)
        // (500_000 * 5.00 / 1_000_000) + (200_000 * 25.00 / 1_000_000) = 2.50 + 5.00 = 7.50
        XCTAssertEqual(cost!, 7.50, accuracy: 0.01)
    }

    func testHaikuCostEstimation() {
        let cost = pricing.estimateCost(
            model: "claude-haiku-4-5",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheRead: 1_000_000,
            cacheCreate: 1_000_000
        )
        XCTAssertNotNil(cost)
        // 1.00 + 5.00 + 0.10 + 1.25 = 7.35
        XCTAssertEqual(cost!, 7.35, accuracy: 0.01)
    }

    func testCacheTokensCost() {
        // Sonnet with cache operations
        let cost = pricing.estimateCost(
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            outputTokens: 0,
            cacheRead: 1_000_000,
            cacheCreate: 1_000_000
        )
        XCTAssertNotNil(cost)
        // cache_read: 0.30 + cache_write: 3.75 = 4.05
        XCTAssertEqual(cost!, 4.05, accuracy: 0.01)
    }

    func testUnknownModelReturnsNil() {
        let cost = pricing.estimateCost(
            model: "unknown-model",
            inputTokens: 1000,
            outputTokens: 500
        )
        XCTAssertNil(cost)
    }

    func testZeroTokensCostIsZero() {
        let cost = pricing.estimateCost(
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            outputTokens: 0
        )
        XCTAssertNotNil(cost)
        XCTAssertEqual(cost!, 0.0, accuracy: 0.001)
    }
}
