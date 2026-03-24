// Model pricing lookup — prices per million tokens in USD
// Source: Anthropic pricing as of 2026-03

const PRICING = {
  'claude-opus-4-6': {
    input: 5.00,
    output: 25.00,
    cache_read: 0.50,
    cache_write: 6.25,
  },
  'claude-sonnet-4-6': {
    input: 3.00,
    output: 15.00,
    cache_read: 0.30,
    cache_write: 3.75,
  },
  'claude-haiku-4-5': {
    input: 1.00,
    output: 5.00,
    cache_read: 0.10,
    cache_write: 1.25,
  },
};

// Aliases for common model ID variations
const ALIASES = {
  'claude-opus-4-6-20260315': 'claude-opus-4-6',
  'claude-sonnet-4-6-20260315': 'claude-sonnet-4-6',
  'claude-haiku-4-5-20251001': 'claude-haiku-4-5',
};

/**
 * Get pricing for a model ID. Returns null if unknown.
 * @param {string} modelId
 * @returns {{ input: number, output: number, cache_read: number, cache_write: number } | null}
 */
export function getPricing(modelId) {
  const resolved = ALIASES[modelId] || modelId;
  return PRICING[resolved] || null;
}

/**
 * Estimate cost in USD for a token event.
 * @param {{ model: string, input_tokens: number, output_tokens: number, cache_create: number, cache_read: number }} event
 * @returns {number|null} Cost in USD, or null if model is unknown
 */
export function estimateCost(event) {
  const pricing = getPricing(event.model);
  if (!pricing) return null;

  const perM = 1_000_000;
  return (
    ((event.input_tokens || 0) * pricing.input) / perM +
    ((event.output_tokens || 0) * pricing.output) / perM +
    ((event.cache_create || 0) * pricing.cache_write) / perM +
    ((event.cache_read || 0) * pricing.cache_read) / perM
  );
}

/**
 * Normalize a model ID to its canonical form.
 * @param {string} modelId
 * @returns {string}
 */
export function normalizeModelId(modelId) {
  return ALIASES[modelId] || modelId;
}

export { PRICING };
