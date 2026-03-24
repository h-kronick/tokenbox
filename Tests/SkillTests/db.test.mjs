import { describe, it, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

// We need to test db.mjs with a temp database, so we override the path
// by importing and calling getDb with a custom path.
// First, reset the module's internal state.

describe('db', () => {
  let db;
  let tempDir;
  let dbPath;

  // Dynamically import to get a fresh module each time
  let dbModule;

  before(async () => {
    tempDir = mkdtempSync(join(tmpdir(), 'tokenbox-test-'));
    dbPath = join(tempDir, 'test.db');

    // Dynamic import to get fresh module
    dbModule = await import('../../skill/lib/db.mjs');
    db = dbModule.getDb(dbPath);
  });

  after(() => {
    dbModule.closeDb();
    rmSync(tempDir, { recursive: true, force: true });
  });

  describe('insertEvent', () => {
    it('inserts a valid event', () => {
      const inserted = dbModule.insertEvent({
        timestamp: '2026-03-19T10:00:00Z',
        source: 'claude_code',
        session_id: 'sess-1',
        project: 'myproject',
        model: 'claude-sonnet-4-6',
        input_tokens: 1000,
        output_tokens: 500,
        cache_create: 200,
        cache_read: 100,
        cost_usd: 0.05,
      });
      assert.equal(inserted, true);
    });

    it('rejects duplicate events', () => {
      const inserted = dbModule.insertEvent({
        timestamp: '2026-03-19T10:00:00Z',
        source: 'claude_code',
        session_id: 'sess-1',
        model: 'claude-sonnet-4-6',
        input_tokens: 1000,
        output_tokens: 500,
      });
      assert.equal(inserted, false);
    });

    it('accepts events with same timestamp but different session', () => {
      const inserted = dbModule.insertEvent({
        timestamp: '2026-03-19T10:00:00Z',
        source: 'claude_code',
        session_id: 'sess-2',
        model: 'claude-sonnet-4-6',
        input_tokens: 500,
        output_tokens: 200,
      });
      assert.equal(inserted, true);
    });
  });

  describe('insertEvents (batch)', () => {
    it('inserts multiple events in a transaction', () => {
      const events = [
        {
          timestamp: '2026-03-18T10:00:00Z',
          source: 'claude_code',
          session_id: 'sess-3',
          model: 'claude-opus-4-6',
          input_tokens: 5000,
          output_tokens: 2000,
          cost_usd: 0.75,
        },
        {
          timestamp: '2026-03-18T11:00:00Z',
          source: 'claude_code',
          session_id: 'sess-3',
          model: 'claude-opus-4-6',
          input_tokens: 3000,
          output_tokens: 1000,
          cost_usd: 0.40,
        },
      ];

      const inserted = dbModule.insertEvents(events);
      assert.equal(inserted, 2);
    });
  });

  describe('getSummary', () => {
    it('returns correct totals for a date range', () => {
      const summary = dbModule.getSummary('2026-03-18', '2026-03-19');
      assert.ok(summary.total_tokens > 0);
      assert.ok(summary.session_count > 0);
      assert.ok(summary.by_model.length > 0);
      assert.ok(summary.by_day.length > 0);
    });

    it('returns zeros for empty date range', () => {
      const summary = dbModule.getSummary('2020-01-01', '2020-01-02');
      assert.equal(summary.total_tokens, 0);
      assert.equal(summary.session_count, 0);
    });
  });

  describe('rebuildDailySummary', () => {
    it('rebuilds without error', () => {
      assert.doesNotThrow(() => dbModule.rebuildDailySummary());

      // Verify daily_summary has rows
      const rows = db.prepare('SELECT COUNT(*) as cnt FROM daily_summary').get();
      assert.ok(rows.cnt > 0);
    });
  });

  describe('config', () => {
    it('sets and gets config values', () => {
      dbModule.setConfig('test_key', 'test_value');
      assert.equal(dbModule.getConfig('test_key'), 'test_value');
    });

    it('returns null for missing keys', () => {
      assert.equal(dbModule.getConfig('nonexistent'), null);
    });

    it('overwrites existing config values', () => {
      dbModule.setConfig('test_key', 'new_value');
      assert.equal(dbModule.getConfig('test_key'), 'new_value');
    });
  });

  describe('getStreak', () => {
    it('returns a streak count', () => {
      const streak = dbModule.getStreak();
      assert.ok(typeof streak === 'number');
      assert.ok(streak >= 0);
    });
  });
});
