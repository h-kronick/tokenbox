// Data pipeline — watches live.json for real-time updates, queries SQLite for aggregates,
// manages context rotation (friends or period cycling).

import { EventEmitter } from 'node:events';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import chokidar from 'chokidar';
import { getDb, closeDb } from '../../skill/lib/db.mjs';
import { formatTokens } from './formatting.mjs';

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
    });
    this._emitContextChange();
  }

  addRealtimeDelta(n) {
    this._realtimeDelta += n;
    // Update all periods with the delta
    const val = this._tokens[this._pinnedPeriod] + (this._pinnedPeriod === 'today' ? this._realtimeDelta : 0);
    this.emit('pinned-change', { label: PERIOD_LABELS[this._pinnedPeriod], value: val });
  }

  setFriends(friends) {
    this._friends = friends || [];
    this._contextIndex = 0;
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
      } catch {
        // Ignore read/parse errors (atomic write race)
      }
    });
  }

  _refreshTokens() {
    if (!this._db) return;

    const filter = this._modelFilter && this._modelFilter !== 'all' ? this._modelFilter : null;
    const now = new Date();

    // Today — local timezone
    const todayStr = _localDateStr(now);

    // Week — Monday of current week
    const weekStart = new Date(now);
    const dow = weekStart.getDay();
    weekStart.setDate(weekStart.getDate() - (dow === 0 ? 6 : dow - 1));
    const weekStr = _localDateStr(weekStart);

    // Month — first of current month
    const monthStr = todayStr.slice(0, 7) + '-01';

    // All time — use a very early date
    const allTimeStr = '2020-01-01';

    this._tokens.today = this._queryOutputTokens(todayStr, todayStr, filter);
    this._tokens.week = this._queryOutputTokens(weekStr, todayStr, filter);
    this._tokens.month = this._queryOutputTokens(monthStr, todayStr, filter);
    this._tokens.allTime = this._queryOutputTokens(allTimeStr, todayStr, filter);

    // Emit current pinned value
    const pinnedVal = this._tokens[this._pinnedPeriod] + (this._pinnedPeriod === 'today' ? this._realtimeDelta : 0);
    this.emit('pinned-change', { label: PERIOD_LABELS[this._pinnedPeriod], value: pinnedVal });
    this._emitContextChange();
  }

  _queryOutputTokens(from, to, modelFilter) {
    try {
      let sql = `SELECT COALESCE(SUM(output_tokens), 0) AS total
        FROM token_events
        WHERE substr(timestamp, 1, 10) BETWEEN ? AND ?`;
      const params = [from, to];

      if (modelFilter) {
        sql += ` AND model LIKE ?`;
        params.push(`%${modelFilter}%`);
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
        label: (f.displayName || f.code || '').toUpperCase().slice(0, 7),
        value: f.tokens || 0,
        subtitle: 'friend',
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
