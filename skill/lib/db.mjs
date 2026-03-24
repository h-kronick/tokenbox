// SQLite interface for TokenBox — uses better-sqlite3
// Database location: ~/Library/Application Support/TokenBox/tokenbox.db

import { join } from 'node:path';
import { homedir } from 'node:os';
import { mkdirSync } from 'node:fs';
import Database from 'better-sqlite3';

const DB_DIR = join(homedir(), 'Library', 'Application Support', 'TokenBox');
const DB_PATH = join(DB_DIR, 'tokenbox.db');

let _db = null;

/**
 * Get or create the database connection with schema initialized.
 * @param {string} [dbPath] - Override path for testing
 * @returns {Database.Database}
 */
export function getDb(dbPath) {
  if (_db) return _db;

  const path = dbPath || DB_PATH;
  mkdirSync(join(path, '..'), { recursive: true });

  _db = new Database(path);
  _db.pragma('journal_mode = WAL');
  _db.pragma('foreign_keys = ON');

  initSchema(_db);
  return _db;
}

/**
 * Initialize the database schema.
 */
function initSchema(db) {
  db.exec(`
    CREATE TABLE IF NOT EXISTS token_events (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      timestamp       TEXT NOT NULL,
      source          TEXT NOT NULL,
      session_id      TEXT,
      project         TEXT,
      model           TEXT NOT NULL,
      input_tokens    INTEGER DEFAULT 0,
      output_tokens   INTEGER DEFAULT 0,
      cache_create    INTEGER DEFAULT 0,
      cache_read      INTEGER DEFAULT 0,
      cost_usd        REAL,
      UNIQUE(timestamp, session_id, model)
    );

    CREATE TABLE IF NOT EXISTS daily_summary (
      date            TEXT NOT NULL,
      source          TEXT NOT NULL,
      model           TEXT NOT NULL,
      total_input     INTEGER DEFAULT 0,
      total_output    INTEGER DEFAULT 0,
      total_cache_r   INTEGER DEFAULT 0,
      total_cache_w   INTEGER DEFAULT 0,
      total_cost      REAL,
      session_count   INTEGER DEFAULT 0,
      PRIMARY KEY (date, source, model)
    );

    CREATE TABLE IF NOT EXISTS friends (
      friend_id       TEXT PRIMARY KEY,
      display_name    TEXT NOT NULL,
      public_key      TEXT NOT NULL,
      first_seen      TEXT NOT NULL,
      last_updated    TEXT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS friend_snapshots (
      id              INTEGER PRIMARY KEY AUTOINCREMENT,
      friend_id       TEXT NOT NULL REFERENCES friends(friend_id),
      snapshot_date   TEXT NOT NULL,
      period_from     TEXT NOT NULL,
      period_to       TEXT NOT NULL,
      total_tokens    INTEGER NOT NULL,
      cost_estimate   REAL,
      by_model        TEXT,
      daily_avg       INTEGER,
      peak_tokens     INTEGER,
      cache_efficiency REAL,
      signature       TEXT NOT NULL,
      UNIQUE(friend_id, snapshot_date)
    );

    CREATE TABLE IF NOT EXISTS config (
      key             TEXT PRIMARY KEY,
      value           TEXT NOT NULL
    );

    CREATE INDEX IF NOT EXISTS idx_events_date ON token_events(timestamp);
    CREATE INDEX IF NOT EXISTS idx_events_session ON token_events(session_id);
    CREATE INDEX IF NOT EXISTS idx_events_model ON token_events(model);
  `);
}

/**
 * Insert a token event, ignoring duplicates (UNIQUE constraint).
 * @param {object} event
 * @returns {boolean} true if inserted, false if duplicate
 */
export function insertEvent(event) {
  const db = getDb();
  const stmt = db.prepare(`
    INSERT OR IGNORE INTO token_events
      (timestamp, source, session_id, project, model, input_tokens, output_tokens, cache_create, cache_read, cost_usd)
    VALUES
      (@timestamp, @source, @session_id, @project, @model, @input_tokens, @output_tokens, @cache_create, @cache_read, @cost_usd)
  `);

  const result = stmt.run({
    timestamp: event.timestamp,
    source: event.source || 'claude_code',
    session_id: event.session_id || null,
    project: event.project || null,
    model: event.model,
    input_tokens: event.input_tokens || 0,
    output_tokens: event.output_tokens || 0,
    cache_create: event.cache_create || 0,
    cache_read: event.cache_read || 0,
    cost_usd: event.cost_usd ?? null,
  });

  return result.changes > 0;
}

/**
 * Batch insert events in a transaction.
 * @param {object[]} events
 * @returns {number} Number of new events inserted
 */
export function insertEvents(events) {
  const db = getDb();
  let inserted = 0;

  const insert = db.prepare(`
    INSERT OR IGNORE INTO token_events
      (timestamp, source, session_id, project, model, input_tokens, output_tokens, cache_create, cache_read, cost_usd)
    VALUES
      (@timestamp, @source, @session_id, @project, @model, @input_tokens, @output_tokens, @cache_create, @cache_read, @cost_usd)
  `);

  const tx = db.transaction((evts) => {
    for (const event of evts) {
      const result = insert.run({
        timestamp: event.timestamp,
        source: event.source || 'claude_code',
        session_id: event.session_id || null,
        project: event.project || null,
        model: event.model,
        input_tokens: event.input_tokens || 0,
        output_tokens: event.output_tokens || 0,
        cache_create: event.cache_create || 0,
        cache_read: event.cache_read || 0,
        cost_usd: event.cost_usd ?? null,
      });
      inserted += result.changes;
    }
  });

  tx(events);
  return inserted;
}

/**
 * Rebuild daily_summary from token_events.
 */
export function rebuildDailySummary() {
  const db = getDb();
  db.exec(`
    DELETE FROM daily_summary;

    INSERT INTO daily_summary (date, source, model, total_input, total_output, total_cache_r, total_cache_w, total_cost, session_count)
    SELECT
      substr(timestamp, 1, 10) AS date,
      source,
      model,
      SUM(input_tokens),
      SUM(output_tokens),
      SUM(cache_read),
      SUM(cache_create),
      SUM(cost_usd),
      COUNT(DISTINCT session_id)
    FROM token_events
    GROUP BY date, source, model;
  `);
}

/**
 * Get summary stats for a date range.
 * @param {string} from - YYYY-MM-DD
 * @param {string} to - YYYY-MM-DD
 * @returns {object}
 */
export function getSummary(from, to) {
  const db = getDb();

  const totals = db.prepare(`
    SELECT
      SUM(input_tokens + output_tokens + cache_create + cache_read) AS total_tokens,
      SUM(cost_usd) AS total_cost,
      COUNT(DISTINCT session_id) AS session_count,
      COUNT(*) AS event_count
    FROM token_events
    WHERE substr(timestamp, 1, 10) BETWEEN ? AND ?
  `).get(from, to);

  const byModel = db.prepare(`
    SELECT
      model,
      SUM(input_tokens + output_tokens + cache_create + cache_read) AS tokens,
      SUM(cost_usd) AS cost
    FROM token_events
    WHERE substr(timestamp, 1, 10) BETWEEN ? AND ?
    GROUP BY model
    ORDER BY tokens DESC
  `).all(from, to);

  const byDay = db.prepare(`
    SELECT
      substr(timestamp, 1, 10) AS date,
      SUM(input_tokens + output_tokens + cache_create + cache_read) AS tokens
    FROM token_events
    WHERE substr(timestamp, 1, 10) BETWEEN ? AND ?
    GROUP BY date
    ORDER BY date
  `).all(from, to);

  const cacheStats = db.prepare(`
    SELECT
      SUM(cache_read) AS total_cache_read,
      SUM(cache_create) AS total_cache_write,
      SUM(input_tokens) AS total_input
    FROM token_events
    WHERE substr(timestamp, 1, 10) BETWEEN ? AND ?
  `).get(from, to);

  const cacheEfficiency =
    cacheStats.total_input + cacheStats.total_cache_read > 0
      ? cacheStats.total_cache_read /
        (cacheStats.total_input + cacheStats.total_cache_read)
      : 0;

  return {
    total_tokens: totals.total_tokens || 0,
    total_cost: totals.total_cost,
    session_count: totals.session_count || 0,
    event_count: totals.event_count || 0,
    by_model: byModel,
    by_day: byDay,
    cache_efficiency: Math.round(cacheEfficiency * 100) / 100,
  };
}

/**
 * Get a config value.
 * @param {string} key
 * @returns {string|null}
 */
export function getConfig(key) {
  const db = getDb();
  const row = db.prepare('SELECT value FROM config WHERE key = ?').get(key);
  return row ? row.value : null;
}

/**
 * Set a config value.
 * @param {string} key
 * @param {string} value
 */
export function setConfig(key, value) {
  const db = getDb();
  db.prepare(
    'INSERT OR REPLACE INTO config (key, value) VALUES (?, ?)'
  ).run(key, value);
}

/**
 * Get the streak of consecutive days with usage, ending today.
 * @returns {number}
 */
export function getStreak() {
  const db = getDb();
  const days = db.prepare(`
    SELECT DISTINCT substr(timestamp, 1, 10) AS date
    FROM token_events
    ORDER BY date DESC
  `).all();

  if (days.length === 0) return 0;

  let streak = 1;
  for (let i = 1; i < days.length; i++) {
    // Parse date strings as local timezone (YYYY-MM-DD noon local avoids DST edge cases)
    const curr = new Date(days[i - 1].date + 'T12:00:00');
    const prev = new Date(days[i].date + 'T12:00:00');
    const diffDays = Math.round((curr.getTime() - prev.getTime()) / (1000 * 60 * 60 * 24));
    if (diffDays === 1) {
      streak++;
    } else {
      break;
    }
  }

  return streak;
}

/**
 * Close the database connection.
 */
export function closeDb() {
  if (_db) {
    _db.close();
    _db = null;
  }
}
