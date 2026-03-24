// Cloud sharing — register, push tokens, fetch friends.
// Uses Node 18+ built-in fetch. State stored in SQLite config table.

import { EventEmitter } from 'node:events';
import { execSync } from 'node:child_process';
import { getDb, getConfig, setConfig } from '../../skill/lib/db.mjs';

const API_BASE = 'https://tokenbox.club';
const PUSH_INTERVAL_MS = 60_000;
const FETCH_INTERVAL_MS = 60_000;
const PUSH_THROTTLE_MS = 10_000;

export class SharingManager extends EventEmitter {
  constructor(dataManager, settingsManager) {
    super();
    this._data = dataManager;
    this._settings = settingsManager;
    this._pushTimer = null;
    this._fetchTimer = null;
    this._lastPushTime = 0;
    this._friends = []; // { code, displayName, nickname, tokens, todayDate }
  }

  start() {
    // On macOS, seed sharing state from UserDefaults (shared with native app)
    if (process.platform === 'darwin') {
      this._loadMacDefaults();
    }

    // Load friends from settings (macOS defaults may have already populated these)
    this._friends = (this._settings.getFriends() || []).map(f => ({
      ...f,
      nickname: f.nickname || null,
      tokens: f.tokens || 0,
      todayDate: f.todayDate || null,
    }));

    // Start push timer if registered
    if (this.isRegistered()) {
      this._pushTimer = setInterval(() => this._push(), PUSH_INTERVAL_MS);
      this._push(); // initial push
    }

    // Start friend fetch timer if we have friends
    if (this._friends.length > 0) {
      this._notifyFriendsChanged(); // Push friends to data manager immediately
      this._fetchTimer = setInterval(() => this._fetchAllFriends(), FETCH_INTERVAL_MS);
      this._fetchAllFriends(); // initial fetch from cloud
    }
  }

  stop() {
    if (this._pushTimer) { clearInterval(this._pushTimer); this._pushTimer = null; }
    if (this._fetchTimer) { clearInterval(this._fetchTimer); this._fetchTimer = null; }
  }

  isRegistered() {
    return !!this.getShareCode();
  }

  getShareCode() {
    try { return getConfig('shareCode'); } catch { return null; }
  }

  getShareURL() {
    const code = this.getShareCode();
    return code ? `${API_BASE}/share/${code}` : null;
  }

  _getSecretToken() {
    try { return getConfig('secretToken'); } catch { return null; }
  }

  async register(displayName) {
    const res = await fetch(`${API_BASE}/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ displayName }),
    });

    if (!res.ok) {
      const text = await res.text().catch(() => '');
      throw new Error(`Registration failed: ${res.status} ${text}`);
    }

    const data = await res.json();
    // Store credentials in SQLite config
    setConfig('shareCode', data.shareCode);
    setConfig('secretToken', data.secretToken);
    setConfig('displayName', displayName);

    // Start push timer
    if (!this._pushTimer) {
      this._pushTimer = setInterval(() => this._push(), PUSH_INTERVAL_MS);
    }

    return {
      shareCode: data.shareCode,
      secretToken: data.secretToken,
      shareURL: `${API_BASE}/share/${data.shareCode}`,
    };
  }

  async addFriend(codeOrUrl) {
    // Extract code from URL or use directly
    let code = codeOrUrl.trim().toUpperCase();
    const urlMatch = codeOrUrl.match(/\/share\/([A-Z0-9]{6})/i);
    if (urlMatch) code = urlMatch[1].toUpperCase();

    // Check not already added
    if (this._friends.some(f => f.code === code)) return;

    // Fetch friend data to validate
    const friendData = await this._fetchFriend(code);

    // Check for display name collision with existing friends
    const newName = (friendData.displayName || code).toUpperCase();
    const existingLabels = this._friends.map(f => (f.nickname || f.displayName || '').toUpperCase());
    const hasCollision = existingLabels.includes(newName);

    const friend = {
      code,
      displayName: friendData.displayName || code,
      nickname: null,
      tokens: friendData.todayTokens || 0,
      todayDate: friendData.todayDate || null,
    };

    this._friends.push(friend);
    this._persistFriends();
    this._notifyFriendsChanged();

    // Start fetch timer if first friend
    if (this._friends.length === 1 && !this._fetchTimer) {
      this._fetchTimer = setInterval(() => this._fetchAllFriends(), FETCH_INTERVAL_MS);
    }

    return { ...friend, needsNickname: hasCollision };
  }

  setNickname(code, nickname) {
    const friend = this._friends.find(f => f.code === code);
    if (!friend) return;
    const trimmed = (nickname || '').trim();
    friend.nickname = trimmed ? trimmed.toUpperCase().slice(0, 7) : null;
    this._persistFriends();
    this._notifyFriendsChanged();
  }

  removeFriend(code) {
    this._friends = this._friends.filter(f => f.code !== code);
    this._persistFriends();
    this._notifyFriendsChanged();

    if (this._friends.length === 0 && this._fetchTimer) {
      clearInterval(this._fetchTimer);
      this._fetchTimer = null;
    }
  }

  getFriends(modelFilter) {
    const today = _localTodayStr();
    return this._friends.map(f => {
      let tokens = f.tokens || 0;

      // Apply model filter using per-model breakdown (matches macOS app behavior)
      if (modelFilter && modelFilter !== 'all' && f.tokensByModel) {
        tokens = f.tokensByModel[modelFilter] || 0;
      }

      return {
        ...f,
        // label = nickname || displayName — used by display for the split-flap
        label: (f.nickname || f.displayName || f.code || '').toUpperCase().slice(0, 7),
        // Stale check: if friend's todayDate != our today, show 0 for today
        tokens: f.todayDate === today ? tokens : 0,
      };
    });
  }

  async _push() {
    // Throttle
    const now = Date.now();
    if (now - this._lastPushTime < PUSH_THROTTLE_MS) return;

    const code = this.getShareCode();
    const token = this._getSecretToken();
    if (!code || !token) return;

    const tokens = this._data.getTokens();
    const today = _localTodayStr();

    try {
      const res = await fetch(`${API_BASE}/push`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`,
        },
        body: JSON.stringify({
          shareCode: code,
          todayTokens: tokens.today,
          todayDate: today,
          tokensByModel: {},
        }),
      });

      this._lastPushTime = Date.now();

      // Silently absorb 429s
      if (res.status === 429) return;
      if (!res.ok) return;
    } catch {
      // Network errors are silent
    }
  }

  async _fetchFriend(code) {
    const res = await fetch(`${API_BASE}/share/${code}`);
    if (!res.ok) throw new Error(`Friend fetch failed: ${res.status}`);
    return res.json();
  }

  async _fetchAllFriends() {
    const today = _localTodayStr();
    let changed = false;

    for (const friend of this._friends) {
      try {
        const data = await this._fetchFriend(friend.code);
        const newTokens = data.todayDate === today ? (data.todayTokens || 0) : 0;
        if (friend.tokens !== newTokens || friend.displayName !== data.displayName) {
          friend.tokens = data.todayTokens || 0;
          friend.tokensByModel = data.tokensByModel || {};
          friend.todayDate = data.todayDate || null;
          friend.displayName = data.displayName || friend.code;
          friend.lastTokenChange = data.lastTokenChange || data.lastUpdated || null;
          changed = true;
        }
      } catch {
        // Skip friends we can't reach
      }
    }

    if (changed) {
      this._notifyFriendsChanged();
    }
  }

  _loadMacDefaults() {
    const shareCode = _readMacDefault('myShareCode');
    const secretToken = _readMacDefault('sharingSecretToken');
    const displayName = _readMacDefault('myDisplayName');

    // Seed SQLite config from UserDefaults if not already set
    if (shareCode && !this.getShareCode()) {
      try { setConfig('shareCode', shareCode); } catch {}
    }
    if (secretToken && !this._getSecretToken()) {
      try { setConfig('secretToken', secretToken); } catch {}
    }
    if (displayName) {
      try { setConfig('displayName', displayName); } catch {}
    }

    // Read friends from UserDefaults
    const friendsRaw = _readMacDefault('friendsJSON');
    if (friendsRaw) {
      try {
        const parsed = JSON.parse(friendsRaw);
        if (Array.isArray(parsed) && parsed.length > 0) {
          // Map from Swift format — preserve token data + per-model breakdown
          // Preserve any existing nicknames from local settings
          const existingFriends = this._settings.getFriends() || [];
          const nicknameMap = {};
          for (const ef of existingFriends) {
            if (ef.nickname) nicknameMap[ef.code] = ef.nickname;
          }

          const mapped = parsed.map(f => {
            const code = f.shareCode || f.code;
            return {
              code,
              displayName: f.displayName || code,
              nickname: f.nickname || nicknameMap[code] || null,
              tokens: f.todayTokens || 0,
              tokensByModel: f.tokensByModel || {},
              todayDate: f.todayDate || null,
              lastTokenChange: f.lastTokenChange || null,
            };
          });
          this._settings.setFriends(mapped);
        }
      } catch {}
    }
  }

  _persistFriends() {
    const list = this._friends.map(f => ({
      code: f.code,
      displayName: f.displayName,
      nickname: f.nickname || null,
    }));
    this._settings.setFriends(list);
  }

  _notifyFriendsChanged() {
    // Get model filter from settings to apply per-model friend token filtering
    const modelFilter = this._settings.get('modelFilter') || 'opus';
    const friends = this.getFriends(modelFilter);
    this._data.setFriends(friends);
    this.emit('friends-changed', friends);
  }
}

function _readMacDefault(key) {
  try {
    return execSync(`defaults read TokenBox ${key}`, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch { return null; }
}

function _localTodayStr() {
  const d = new Date();
  return d.getFullYear()
    + '-' + String(d.getMonth() + 1).padStart(2, '0')
    + '-' + String(d.getDate()).padStart(2, '0');
}
