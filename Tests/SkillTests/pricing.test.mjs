import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { getPricing, estimateCost, normalizeModelId, PRICING } from '../../skill/lib/pricing.mjs';

describe('pricing', () => {
  describe('getPricing', () => {
    it('returns pricing for known models', () => {
      const opus = getPricing('claude-opus-4-6');
      assert.equal(opus.input, 5.00);
      assert.equal(opus.output, 25.00);
      assert.equal(opus.cache_read, 0.50);
      assert.equal(opus.cache_write, 6.25);

      const sonnet = getPricing('claude-sonnet-4-6');
      assert.equal(sonnet.input, 3.00);
      assert.equal(sonnet.output, 15.00);

      const haiku = getPricing('claude-haiku-4-5');
      assert.equal(haiku.input, 1.00);
    });

    it('resolves aliases', () => {
      const pricing = getPricing('claude-opus-4-6-20260315');
      assert.deepEqual(pricing, PRICING['claude-opus-4-6']);
    });

    it('returns null for unknown models', () => {
      assert.equal(getPricing('gpt-4o'), null);
      assert.equal(getPricing('unknown'), null);
    });
  });

  describe('estimateCost', () => {
    it('computes cost correctly for opus', () => {
      const cost = estimateCost({
        model: 'claude-opus-4-6',
        input_tokens: 1_000_000,
        output_tokens: 1_000_000,
        cache_create: 0,
        cache_read: 0,
      });
      // 1M input * $5/M + 1M output * $25/M = $30
      assert.equal(cost, 30.00);
    });

    it('includes cache costs', () => {
      const cost = estimateCost({
        model: 'claude-opus-4-6',
        input_tokens: 0,
        output_tokens: 0,
        cache_create: 1_000_000,
        cache_read: 1_000_000,
      });
      // 1M cache_write * $6.25/M + 1M cache_read * $0.50/M = $6.75
      assert.equal(cost, 6.75);
    });

    it('returns null for unknown models', () => {
      const cost = estimateCost({
        model: 'unknown-model',
        input_tokens: 1000,
        output_tokens: 500,
        cache_create: 0,
        cache_read: 0,
      });
      assert.equal(cost, null);
    });

    it('handles zero tokens', () => {
      const cost = estimateCost({
        model: 'claude-sonnet-4-6',
        input_tokens: 0,
        output_tokens: 0,
        cache_create: 0,
        cache_read: 0,
      });
      assert.equal(cost, 0);
    });
  });

  describe('normalizeModelId', () => {
    it('normalizes dated model IDs', () => {
      assert.equal(normalizeModelId('claude-opus-4-6-20260315'), 'claude-opus-4-6');
      assert.equal(normalizeModelId('claude-sonnet-4-6-20260315'), 'claude-sonnet-4-6');
      assert.equal(normalizeModelId('claude-haiku-4-5-20251001'), 'claude-haiku-4-5');
    });

    it('passes through canonical IDs unchanged', () => {
      assert.equal(normalizeModelId('claude-opus-4-6'), 'claude-opus-4-6');
    });

    it('passes through unknown IDs unchanged', () => {
      assert.equal(normalizeModelId('future-model'), 'future-model');
    });
  });
});
