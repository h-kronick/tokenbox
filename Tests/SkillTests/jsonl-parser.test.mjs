import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { parseLine } from '../../skill/lib/jsonl-parser.mjs';

describe('jsonl-parser', () => {
  describe('parseLine', () => {
    it('parses direct usage field', () => {
      const line = JSON.stringify({
        timestamp: '2026-03-19T10:00:00Z',
        model: 'claude-sonnet-4-6',
        usage: {
          input_tokens: 1000,
          output_tokens: 500,
          cache_creation_input_tokens: 200,
          cache_read_input_tokens: 100,
        },
      });

      const event = parseLine(line, 'sess-1', 'myproject');
      assert.equal(event.timestamp, '2026-03-19T10:00:00Z');
      assert.equal(event.model, 'claude-sonnet-4-6');
      assert.equal(event.input_tokens, 1000);
      assert.equal(event.output_tokens, 500);
      assert.equal(event.cache_create, 200);
      assert.equal(event.cache_read, 100);
      assert.equal(event.session_id, 'sess-1');
      assert.equal(event.project, 'myproject');
      assert.equal(event.source, 'claude_code');
    });

    it('parses message.usage format', () => {
      const line = JSON.stringify({
        timestamp: '2026-03-19T11:00:00Z',
        message: {
          model: 'claude-opus-4-6',
          usage: {
            input_tokens: 2000,
            output_tokens: 800,
          },
        },
      });

      const event = parseLine(line, 'sess-2', 'proj2');
      assert.equal(event.model, 'claude-opus-4-6');
      assert.equal(event.input_tokens, 2000);
      assert.equal(event.output_tokens, 800);
      assert.equal(event.cache_create, 0);
      assert.equal(event.cache_read, 0);
    });

    it('parses costInfo format', () => {
      const line = JSON.stringify({
        costInfo: {
          modelId: 'claude-haiku-4-5',
          inputTokens: 500,
          outputTokens: 100,
          cacheCreationInputTokens: 50,
          cacheReadInputTokens: 30,
        },
      });

      const event = parseLine(line, 'sess-3', 'proj3');
      assert.equal(event.model, 'claude-haiku-4-5');
      assert.equal(event.input_tokens, 500);
      assert.equal(event.output_tokens, 100);
      assert.equal(event.cache_create, 50);
      assert.equal(event.cache_read, 30);
    });

    it('returns null for empty lines', () => {
      assert.equal(parseLine('', 'sess', 'proj'), null);
      assert.equal(parseLine('   ', 'sess', 'proj'), null);
    });

    it('returns null for invalid JSON', () => {
      assert.equal(parseLine('not json at all', 'sess', 'proj'), null);
      assert.equal(parseLine('{broken', 'sess', 'proj'), null);
    });

    it('returns null for lines without usage data', () => {
      const line = JSON.stringify({ type: 'human', content: 'hello' });
      assert.equal(parseLine(line, 'sess', 'proj'), null);
    });

    it('normalizes dated model IDs', () => {
      const line = JSON.stringify({
        model: 'claude-opus-4-6-20260315',
        usage: { input_tokens: 100, output_tokens: 50 },
      });

      const event = parseLine(line, 'sess', 'proj');
      assert.equal(event.model, 'claude-opus-4-6');
    });
  });
});
