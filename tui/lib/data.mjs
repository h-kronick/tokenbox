// Data pipeline — watches live.json for real-time updates, queries SQLite for aggregates,
// manages context rotation (friends or period cycling).

import { EventEmitter } from 'node:events';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import chokidar from 'chokidar';
import { getDb, closeDb } from '../../skill/lib/db.mjs';
import { formatTokens, formatModelName, timeUntilReset, timeAgo } from './formatting.mjs';

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
    this._rotationTimer = null;
    this._modelFilter = 'opus';
    this._pinnedPeriod = 'today';
    this._tokens = { today: 0, week: 0, month: 0, allTime: 0 };
    this._realtimeDelta = 0;
    this._friends = [];
    this._contextIndex = 0;
    this._db = null;
    this._dataDir = getDataDir();
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

    this._refreshTokens();
    this._startWatcher();
    this._startContextRotation();
  }

  stop() {
    if (this._watcher) {
      this._watcher.close();
      this._watcher = null;
    }
    if (this._rotationTimer) {
      clearInterval(this._rotationTimer);
      this._rotationTimer = null;
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
    this._refreshTokens();
  }

  setPinnedPeriod(p) {
    this._pinnedPeriod = p;
    this._contextIndex = 0;
    this.emit('pinned-change', {
      label: PERIOD_LABELS[p],
      value: this._tokens[p] + (p === 'today' ? this._realtimeDelta : 0),
      modelName: formatModelName(this._modelFilter),
      resetTime: timeUntilReset(),
    });
    this._emitContextChange();
  }

  addRealtimeDelta(n) {
    this._realtimeDelta += n;
    // Update all periods with the delta
    const val = this._tokens[this._pinnedPeriod] + (this._pinnedPeriod === 'today' ? this._realtimeDelta : 0);
    this.emit('pinned-change', {
      label: PERIOD_LABELS[this._pinnedPeriod],
      value: val,
      modelName: formatModelName(this._modelFilter),
      resetTime: timeUntilReset(),
    });
  }

  setFriends(friends) {
    this._friends = friends || [];
    this._contextIndex = 0;
    // Immediately show friends in context rotation
    if (this._friends.length > 0) {
      this._emitContextChange();
    }
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

        // Apply model filter — substring match
        if (this._modelFilter && this._modelFilter !== 'all') {
          if (!data.model || !data.model.toLowerCase().includes(this._modelFilter.toLowerCase())) {
            return;
          }
        }

        this.emit('live-update', data);

        // Debounced DB refresh — matches macOS app's 500ms debounce on JSONL changes
        this._debouncedRefresh();
      } catch {
        // Ignore read/parse errors (atomic write race)
      }
    });
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

    // Emit current pinned value
    const pinnedVal = this._tokens[this._pinnedPeriod] + (this._pinnedPeriod === 'today' ? this._realtimeDelta : 0);
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
