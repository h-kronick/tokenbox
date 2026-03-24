import Foundation

/// Calculates estimated costs using embedded model pricing data.
/// Prices are per million tokens, loaded from Resources/pricing.json.
struct PricingService: Sendable {

    struct ModelPricing: Codable, Sendable {
        let input: Double
        let output: Double
        let cacheRead: Double
        let cacheWrite: Double

        enum CodingKeys: String, CodingKey {
            case input, output
            case cacheRead = "cache_read"
            case cacheWrite = "cache_write"
        }
    }

    let pricing: [String: ModelPricing]

    /// Load pricing from the bundled pricing.json resource.
    init() {
        if let url = Bundle.main.url(forResource: "pricing", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: ModelPricing].self, from: data) {
            self.pricing = decoded
        } else {
            // Fallback hardcoded pricing
            self.pricing = Self.defaultPricing
        }
    }

    /// Initialize with explicit pricing data (for testing).
    init(pricing: [String: ModelPricing]) {
        self.pricing = pricing
    }

    /// Estimate cost in USD for a token event.
    func estimateCost(for event: TokenEvent) -> Double? {
        guard let model = pricing[event.model] else { return nil }
        let perMillion = 1_000_000.0
        return (Double(event.inputTokens) * model.input / perMillion) +
               (Double(event.outputTokens) * model.output / perMillion) +
               (Double(event.cacheRead) * model.cacheRead / perMillion) +
               (Double(event.cacheCreate) * model.cacheWrite / perMillion)
    }

    /// Estimate cost for raw token counts and a model.
    func estimateCost(model: String, inputTokens: Int, outputTokens: Int, cacheRead: Int = 0, cacheCreate: Int = 0) -> Double? {
        guard let p = pricing[model] else { return nil }
        let perMillion = 1_000_000.0
        return (Double(inputTokens) * p.input / perMillion) +
               (Double(outputTokens) * p.output / perMillion) +
               (Double(cacheRead) * p.cacheRead / perMillion) +
               (Double(cacheCreate) * p.cacheWrite / perMillion)
    }

    static let defaultPricing: [String: ModelPricing] = [
        "claude-opus-4-6": ModelPricing(input: 5.00, output: 25.00, cacheRead: 0.50, cacheWrite: 6.25),
        "claude-sonnet-4-6": ModelPricing(input: 3.00, output: 15.00, cacheRead: 0.30, cacheWrite: 3.75),
        "claude-haiku-4-5": ModelPricing(input: 1.00, output: 5.00, cacheRead: 0.10, cacheWrite: 1.25)
    ]
}
