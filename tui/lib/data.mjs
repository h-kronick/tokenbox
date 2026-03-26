// Data pipeline — watches live.json for real-time updates, watches JSONL session logs
// for DB population, queries SQLite for aggregates, manages context rotation.

import { EventEmitter } from 'node:events';
import { homedir } from 'node:os';
import { join, basename, dirname } from 'node:path';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import chokidar from 'chokidar';
import { getDb, closeDb } from '../../skill/lib/db.mjs';
import { parseLine } from '../../skill/lib/jsonl-parser.mjs';
import { formatTokens, formatModelName, timeUntilReset, timeAgo, currentPSTDate } from './formatting.mjs';

const CONTEXT_ROTATION_MS = 15_000;

/**
 * Platform-aware data directory — matches hooks/status-relay.mjs.
 */
export function getDataDir() {
  if (process.platform === 'win32') return join(process.env.APPDATA || join(homedir(), 'AppData', 'Roaming'), 'TokenBox');
  if (process.platform === 'darwin') return join(homedir(), 'Library', 'Application Support', 'TokenBox');
  return join(process.env.XDG_DATA_HOME || join(homedir(), '.local', 'share'), 'tokenbox');
}

const PERIODS = ['today', 'week', 'month', 'allTime'];
const PERIOD_LABELS = { today: 'TODAY', week: 'THIS WEEK', month: 'THIS MONTH', allTime: 'ALL TIME' };

export class DataManager extends EventEmitter {
  constructor() {
    super();
    this._watcher = null;
    this._jsonlWatcher = null;
    this._rotationTimer = null;
    this._modelFilter = 'opus';
    this._pinnedPeriod = 'today';
    this._tokens = { today: 0, week: 0, month: 0, allTime: 0 };
    this._realtimeDelta = 0;
    this._serverAggregate = null;
    this._localTokensAtAggregateSnapshot = 0;
    this._friends = [];
    this._contextIndex = 0;
    this._db = null;
    this._dataDir = getDataDir();
    // JSONL watcher state — tracks byte offsets per file for incremental parsing
    this._fileOffsets = new Map();
    this._initialScanComplete = false;
    // Live event delta tracking — tracks cumulative output per session to compute deltas
    this._lastLiveOut = 0;
    this._lastLiveSid = null;
    this._firstLiveEvent = true;
    this._lastPSTDate = null;
    this._periodicTimer = null;
    this._serverAggregate = null; // server aggregate from linked devices
  }

  start(modelFilter, pinnedPeriod) {
    this._modelFilter = modelFilter || 'opus';
    this._pinnedPeriod = pinnedPeriod || 'today';

    // Init database
    const dbPath = join(this._dataDir, 'tokenbox.db');
    try {
      this._db = getDb(dbPath);
    } catch {
      // DB may not exist yet — that's OK, we'll work with zeros
    }

    // Backfill DB from Claude Code JSONL session logs before first refresh.
    // Mirrors macOS native app's JSONLWatcher initial scan.
    this._scanJSONLFiles();

    this._refreshTokens();
    this._startWatcher();
    this._startJSONLWatcher();
    this._startContextRotation();
    this._startPeriodicRefresh();
  }

  stop() {
    if (this._watcher) {
      this._watcher.close();
      this._watcher = null;
    }
    if (this._jsonlWatcher) {
      this._jsonlWatcher.close();
      this._jsonlWatcher = null;
    }
    if (this._rotationTimer) {
      clearInterval(this._rotationTimer);
      this._rotationTimer = null;
    }
    if (this._periodicTimer) {
      clearInterval(this._periodicTimer);
      this._periodicTimer = null;
    }
    if (this._refreshTimer) {
      clearInterval(this._refreshTimer);
      this._refreshTimer = null;
    }
    if (this._debounceTimeout) {
      clearTimeout(this._debounceTimeout);
      this._debounceTimeout = null;
    }
  }

  getTokens() {
    return { ...this._tokens };
  }

  setModelFilter(f) {
    this._modelFilter = f;
    this._realtimeDelta = 0;
    // Reset live tracking — cumulative values are model-agnostic but delta
    // should restart when the user switches models to avoid stale cross-model deltas
    this._firstLiveEvent = true;
    this._refreshTokens();
  }

  setPinnedPeriod(p) {
    this._pinnedPeriod = p;
    this._contextIndex = 0;
    const aggValue = this._aggregateTokens(p);
    const localValue = this._tokens[p] + (p === 'today' ? this._realtimeDelta : 0);
    let value;
    if (aggValue != null && p === 'today') {
      const currentLocal = this._tokens.today + this._realtimeDelta;
      const localGain = Math.max(0, currentLocal - (this._localTokensAtAggregateSnapshot || 0));
      value = aggValue + localGain;
    } else {
      value = aggValue != null ? aggValue : localValue;
    }
    this.emit('pinned-change', {
      label: PERIOD_LABELS[p],
      value,
      modelName: formatModelName(this._modelFilter),
      resetTime: timeUntilReset(),
    });
    this._emitContextChange();
  }

  /**
   * Handle a live output event — computes the actual delta from cumulative values.
   * live.json's `out` field is cumulative output tokens per context window, not a
   * per-message delta. We track the previous value per session to compute the real
   * increment. On first event after startup or session change, delta is 0 since the
   * JSONL watcher + DB refresh will account for existing tokens.
   * @param {number} outValue - Cumulative output tokens from live.json
   * @param {string} sessionId - Session ID from live.json
   */
  handleLiveOutput(outValue, sessionId) {
    let delta = 0;

    if (this._firstLiveEvent) {
      // First event after startup — DB was just backfilled from JSONL scan,
      // so these tokens are already counted. Skip to avoid double-counting.
      this._firstLiveEvent = false;
    } else if (sessionId && sessionId === this._lastLiveSid) {
      // Same session — delta is the increase in cumulative output
      delta = Math.max(0, outValue - this._lastLiveOut);
    }
    // New/different session: delta = 0, let JSONL import + DB refresh handle it

    this._lastLiveSid = sessionId || null;
    this._lastLiveOut = outValue;

    if (delta > 0) {
      this._realtimeDelta += delta;
      const aggValue = this._aggregateTokens(this._pinnedPeriod);
      const localBase = this._tokens[this._pinnedPeriod];
      let val;
      if (aggValue != null && this._pinnedPeriod === 'today') {
        const currentLocal = this._tokens.today + this._realtimeDelta;
        const localGain = Math.max(0, currentLocal - (this._localTokensAtAggregateSnapshot || 0));
        val = aggValue + localGain;
      } else {
        const base = aggValue != null ? aggValue : localBase;
        val = base + (this._pinnedPeriod === 'today' ? this._realtimeDelta : 0);
      }
      this.emit('pinned-change', {
        label: PERIOD_LABELS[this._pinnedPeriod],
        value: val,
        modelName: formatModelName(this._modelFilter),
        resetTime: timeUntilReset(),
      });
    }
  }

  setFriends(friends) {
    this._friends = friends || [];
    this._contextIndex = 0;
    // Immediately show friends in context rotation
    if (this._friends.length > 0) {
      this._emitContextChange();
    }
  }

  setServerAggregate(agg) {
    this._serverAggregate = agg || null;
    // Snapshot local today tokens so display can smoothly interpolate:
    // displayValue = aggregate + (currentLocal - localAtSnapshot)
    this._localTokensAtAggregateSnapshot = this._tokens.today;
    this._refreshTokens();
  }

  /**
   * Extract filtered aggregate value for a period from server aggregate.
   * Mirrors macOS SharingManager.aggregateTokens(for:period:).
   * Returns null if no aggregate or no linked devices.
   */
  _aggregateTokens(period) {
    const agg = this._serverAggregate;
    if (!agg) return null;

    const periodMap = {
      today: agg.tokensByModel,
      week: agg.weekByModel,
      month: agg.monthByModel,
      allTime: agg.allTimeByModel,
    };
    const map = periodMap[period] || agg.tokensByModel;

    // If no per-model map, fall back to todayTokens for "today" period
    if (!map || Object.keys(map).length === 0) {
      return period === 'today' ? (agg.todayTokens || 0) : null;
    }

    const filter = this._modelFilter;
    if (!filter || filter === 'all') {
      return Object.values(map).reduce((a, b) => a + b, 0);
    }

    // Substring match on model keys (e.g. "opus" matches "claude-opus-4-6")
    const lf = filter.toLowerCase();
    let total = 0;
    for (const [key, val] of Object.entries(map)) {
      if (key.toLowerCase().includes(lf)) total += val;
    }
    return total;
  }

  _startWatcher() {
    const livePath = join(this._dataDir, 'live.json');
    this._watcher = chokidar.watch(livePath, {
      persistent: true,
      ignoreInitial: true,
      awaitWriteFinish: { stabilityThreshold: 50, pollInterval: 20 },
    });

    this._watcher.on('change', () => {
      try {
        const raw = readFileSync(livePath, 'utf8');
        const data = JSON.parse(raw);

        // Always trigger debounced DB refresh — the JSONL watcher may have inserted
        // events for any model, and we need the DB totals to stay current.
        this._debouncedRefresh();

        // Apply model filter — substring match (only for display/delta, not DB refresh)
        if (this._modelFilter && this._modelFilter !== 'all') {
          if (!data.model || !data.model.toLowerCase().includes(this._modelFilter.toLowerCase())) {
            return;
          }
        }

        this.emit('live-update', data);
      } catch {
        // Ignore read/parse errors (atomic write race)
      }
    });
  }

  // --- JSONL session log watcher (mirrors macOS JSONLWatcher.swift) ---

  /**
   * Scan all existing JSONL files on startup for DB backfill.
   * Processes files synchronously so the first _refreshTokens() has accurate data.
   */
  _scanJSONLFiles() {
    if (!this._db) return;

    const claudeProjectsDir = join(homedir(), '.claude', 'projects');
    if (!existsSync(claudeProjectsDir)) return;

    try {
      const projects = readdirSync(claudeProjectsDir);
      for (const project of projects) {
        const projectDir = join(claudeProjectsDir, project);
        let entries;
        try {
          entries = readdirSync(projectDir);
        } catch { continue; }
        for (const entry of entries) {
          if (entry.endsWith('.jsonl')) {
            this._processJSONLFile(join(projectDir, entry));
          }
        }
      }
    } catch {
      // ~/.claude/projects/ not readable — skip
    }
    this._initialScanComplete = true;
  }

  /**
   * Start watching ~/.claude/projects/ for JSONL file changes.
   * Uses chokidar (FSEvents on macOS, inotify on Linux, polling fallback).
   */
  _startJSONLWatcher() {
    const claudeProjectsDir = join(homedir(), '.claude', 'projects');

    // Don't crash if the directory doesn't exist yet — Claude Code creates it on first use
    if (!existsSync(claudeProjectsDir)) return;

    this._jsonlWatcher = chokidar.watch(join(claudeProjectsDir, '**', '*.jsonl'), {
      persistent: true,
      ignoreInitial: true,
      awaitWriteFinish: { stabilityThreshold: 100, pollInterval: 50 },
      // Limit depth to avoid watching deeply nested directories
      depth: 2,
    });

    this._jsonlWatcher.on('change', (filePath) => {
      this._processJSONLFile(filePath);
      this._debouncedRefresh();
    });

    this._jsonlWatcher.on('add', (filePath) => {
      this._processJSONLFile(filePath);
      this._debouncedRefresh();
    });

    // Silently handle watcher errors (permissions, too many watchers, etc.)
    this._jsonlWatcher.on('error', () => {});
  }

  /**
   * Process a single JSONL file — read new content from last known byte offset,
   * parse lines, and insert completed events into SQLite.
   * @param {string} filePath - Absolute path to the .jsonl file
   */
  _processJSONLFile(filePath) {
    if (!this._db) return;

    const offset = this._fileOffsets.get(filePath) || 0;
    let buf;
    try {
      buf = readFileSync(filePath);
    } catch { return; }

    // Handle file truncation (shouldn't happen, but be safe)
    if (buf.length < offset) {
      this._fileOffsets.set(filePath, 0);
      return this._processJSONLFile(filePath);
    }
    if (buf.length <= offset) return;

    const newContent = buf.slice(offset).toString('utf8');
    this._fileOffsets.set(filePath, buf.length);

    const sessionId = basename(filePath, '.jsonl');
    const project = basename(dirname(filePath));

    const insertStmt = this._db.prepare(`
      INSERT OR IGNORE INTO token_events
        (timestamp, source, session_id, project, model, input_tokens, output_tokens, cache_create, cache_read, cost_usd)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    `);

    for (const line of newContent.split('\n')) {
      const event = parseLine(line, sessionId, project);
      if (event) {
        try {
          insertStmt.run(
            event.timestamp, event.source, event.session_id,
            event.project, event.model, event.input_tokens,
            event.output_tokens, event.cache_create, event.cache_read,
            event.cost_usd ?? null
          );
        } catch {
          // Ignore dedup conflicts and other insert errors
        }
      }
    }
  }

  _debouncedRefresh() {
    if (this._debounceTimeout) clearTimeout(this._debounceTimeout);
    this._debounceTimeout = setTimeout(() => {
      this._debounceTimeout = null;
      this._realtimeDelta = 0;
      this._refreshTokens();
    }, 500);
  }

  _refreshTokens() {
    if (!this._db) return;

    const filter = this._modelFilter && this._modelFilter !== 'all' ? this._modelFilter : null;
    const now = new Date();

    // Use UTC ISO boundaries to match macOS app's Swift ISO8601DateFormatter behavior.
    // Calendar.current.startOfDay → ISO8601DateFormatter (UTC) produces UTC timestamp strings.
    // This ensures TUI and native app show identical token counts.
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const startOfTomorrow = new Date(startOfToday.getTime() + 86400000);
    const todayStart = startOfToday.toISOString();
    const todayEnd = startOfTomorrow.toISOString();

    // Week — Monday of current week
    const dow = startOfToday.getDay();
    const weekStart = new Date(startOfToday.getTime() - ((dow === 0 ? 6 : dow - 1)) * 86400000);
    const weekStartStr = weekStart.toISOString();

    // Month — first of current month
    const monthStart = new Date(now.getFullYear(), now.getMonth(), 1);
    const monthStartStr = monthStart.toISOString();

    const nowStr = now.toISOString();

    this._tokens.today = this._queryOutputTokens(todayStart, todayEnd, filter);
    this._tokens.week = this._queryOutputTokens(weekStartStr, nowStr, filter);
    this._tokens.month = this._queryOutputTokens(monthStartStr, nowStr, filter);
    this._tokens.allTime = this._queryOutputTokens(null, null, filter);

    // Emit current pinned value — use server aggregate when linked devices exist.
    // Smooth interpolation: aggregate + max(0, currentLocal - localAtSnapshot)
    // avoids choppy drops when realtimeDelta resets on DB refresh.
    const aggValue = this._aggregateTokens(this._pinnedPeriod);
    const localValue = this._tokens[this._pinnedPeriod] + (this._pinnedPeriod === 'today' ? this._realtimeDelta : 0);
    let pinnedVal;
    if (aggValue != null && this._pinnedPeriod === 'today') {
      const currentLocal = this._tokens.today + this._realtimeDelta;
      const localGain = Math.max(0, currentLocal - (this._localTokensAtAggregateSnapshot || 0));
      pinnedVal = aggValue + localGain;
    } else {
      pinnedVal = aggValue != null ? aggValue : localValue;
    }
    this.emit('pinned-change', {
      label: PERIOD_LABELS[this._pinnedPeriod],
      value: pinnedVal,
      modelName: formatModelName(this._modelFilter),
      resetTime: timeUntilReset(),
    });
    this._emitContextChange();
  }

  _queryOutputTokens(from, to, modelFilter) {
    try {
      let sql = `SELECT COALESCE(SUM(output_tokens), 0) AS total FROM token_events WHERE 1=1`;
      const params = [];

      // Use full timestamp string comparison (matches macOS Swift ISO8601DateFormatter behavior)
      if (from) {
        sql += ` AND timestamp >= ?`;
        params.push(from);
      }
      if (to) {
        sql += ` AND timestamp <= ?`;
        params.push(to);
      }

      if (modelFilter) {
        sql += ` AND lower(model) LIKE '%' || lower(?) || '%'`;
        params.push(modelFilter);
      }

      const row = this._db.prepare(sql).get(...params);
      return row ? row.total : 0;
    } catch {
      return 0;
    }
  }

  _startPeriodicRefresh() {
    // Track current PST date
    this._lastPSTDate = currentPSTDate();

    // Check every 60 seconds if the PST day has changed
    this._periodicTimer = setInterval(() => {
      const now = currentPSTDate();
      if (now !== this._lastPSTDate) {
        this._lastPSTDate = now;
        this._realtimeDelta = 0;
        this._firstLiveEvent = true;
        this._refreshTokens();
      }
    }, 60_000);
  }

  _startContextRotation() {
    this._rotationTimer = setInterval(() => {
      this._contextIndex++;
      this._emitContextChange();
    }, CONTEXT_ROTATION_MS);
  }

  _emitContextChange() {
    if (this._friends.length > 0) {
      // Rotate through friends
      const idx = this._contextIndex % this._friends.length;
      const f = this._friends[idx];
      this.emit('context-change', {
        label: f.label || (f.displayName || f.code || '').toUpperCase().slice(0, 7),
        value: f.tokens || 0,
        subtitle: f.lastTokenChange ? timeAgo(f.lastTokenChange) : '',
      });
      return;
    }

    // Rotate through non-pinned periods
    const available = PERIODS.filter(p => p !== this._pinnedPeriod);
    if (available.length === 0) return;
    const idx = this._contextIndex % available.length;
    const period = available[idx];
    this.emit('context-change', {
      label: PERIOD_LABELS[period],
      value: this._tokens[period],
      subtitle: '',
    });
  }

  /**
   * Get output tokens grouped by model for a given period.
   * Returns { opus: N, sonnet: N, haiku: N } with short model name keys
   * matching the macOS app's buildModelMap pattern.
   */
  getTokensByModel(period) {
    if (!this._db) return {};

    const now = new Date();
    const startOfToday = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    const startOfTomorrow = new Date(startOfToday.getTime() + 86400000);

    let from, to;
    switch (period) {
      case 'today':
        from = startOfToday.toISOString();
        to = startOfTomorrow.toISOString();
        break;
      case 'week': {
        const dow = startOfToday.getDay();
        const weekStart = new Date(startOfToday.getTime() - ((dow === 0 ? 6 : dow - 1)) * 86400000);
        from = weekStart.toISOString();
        to = now.toISOString();
        break;
      }
      case 'month':
        from = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
        to = now.toISOString();
        break;
      case 'allTime':
        from = null;
        to = null;
        break;
      default:
        from = startOfToday.toISOString();
        to = startOfTomorrow.toISOString();
    }

    try {
      let sql = `SELECT model, SUM(output_tokens) as tokens FROM token_events WHERE 1=1`;
      const params = [];
      if (from) { sql += ` AND timestamp >= ?`; params.push(from); }
      if (to) { sql += ` AND timestamp <= ?`; params.push(to); }
      sql += ` GROUP BY model`;

      const rows = this._db.prepare(sql).all(...params);
      const result = {};
      for (const row of rows) {
        const m = (row.model || '').toLowerCase();
        let key;
        if (m.includes('opus')) key = 'opus';
        else if (m.includes('sonnet')) key = 'sonnet';
        else if (m.includes('haiku')) key = 'haiku';
        else key = row.model;
        result[key] = (result[key] || 0) + (row.tokens || 0);
      }
      return result;
    } catch {
      return {};
    }
  }

  /**
   * Force a full data refresh from the database.
   */
  refresh() {
    this._realtimeDelta = 0;
    this._refreshTokens();
  }
}

function _localDateStr(d) {
  return d.getFullYear()
    + '-' + String(d.getMonth() + 1).padStart(2, '0')
    + '-' + String(d.getDate()).padStart(2, '0');
}
