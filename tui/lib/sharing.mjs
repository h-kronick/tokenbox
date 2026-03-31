// Cloud sharing — register, push tokens, fetch friends.
// Uses Node 18+ built-in fetch. State stored in SQLite config table.

import { EventEmitter } from 'node:events';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { getDb, getConfig, setConfig } from '../../skill/lib/db.mjs';
import { currentPSTDate } from './formatting.mjs';

const API_BASE = 'https://tokenbox.club';
const PUSH_INTERVAL_MS = 30_000;
const FETCH_INTERVAL_MS = 30_000;
const PUSH_THROTTLE_MS = 10_000;
const DEFAULT_FRIEND_CODE = 'XNBGBU';

export class SharingManager extends EventEmitter {
  constructor(dataManager, settingsManager) {
    super();
    this._data = dataManager;
    this._settings = settingsManager;
    this._pushTimer = null;
    this._fetchTimer = null;
    this._lastPushTime = 0;
    this._lastPushedPSTDate = null;
    this._friends = []; // { code, displayName, nickname, tokens, todayDate }
    this._devices = []; // { deviceId, label, lastPush }
    this._serverAggregate = null; // server-side aggregate across all linked devices
  }

  start() {
    // On macOS, seed sharing state from UserDefaults (shared with native app)
    if (process.platform === 'darwin') {
      this._loadMacDefaults();
    }

    // Ensure this device has a stable deviceId
    let deviceId = getConfig('deviceId');
    if (!deviceId) {
      deviceId = randomUUID();
      setConfig('deviceId', deviceId);
    }
    this._deviceId = deviceId;

    // Load persisted device list
    try {
      const devicesJson = getConfig('devices');
      if (devicesJson) this._devices = JSON.parse(devicesJson);
    } catch {}

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

  getDeviceId() {
    return this._deviceId || null;
  }

  getDevices() {
    return this._devices;
  }

  getServerAggregate() {
    return this._serverAggregate;
  }

  async createLinkCode() {
    const code = this.getShareCode();
    const token = this._getSecretToken();
    if (!code || !token) throw new Error('Not registered for sharing');

    const res = await fetch(`${API_BASE}/link/create`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
      body: JSON.stringify({ shareCode: code }),
    });

    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Failed: ${res.status}`);
    }

    const data = await res.json();
    return data.linkCode;
  }

  async redeemLinkCode(linkCode, deviceLabel) {
    const res = await fetch(`${API_BASE}/link/redeem`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        linkCode,
        ...(deviceLabel ? { deviceLabel } : {}),
      }),
    });

    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Failed: ${res.status}`);
    }

    const data = await res.json();

    // Device B already registered: leave old leaderboard if opted in
    if (this.isRegistered() && this.isLeaderboardOptIn()) {
      try { await this.leaveLeaderboard(); } catch {}
    }

    // Save new credentials (overwrites any existing registration)
    setConfig('shareCode', data.shareCode);
    setConfig('secretToken', data.secretToken);
    setConfig('displayName', data.displayName);
    setConfig('deviceId', data.deviceId);
    this._deviceId = data.deviceId;

    // Start push timer if not already running
    if (!this._pushTimer) {
      this._pushTimer = setInterval(() => this._push(), PUSH_INTERVAL_MS);
    }

    // Trigger an immediate push to get the device list back
    this._lastPushTime = 0;
    await this._push();

    return {
      shareCode: data.shareCode,
      displayName: data.displayName,
      deviceId: data.deviceId,
    };
  }

  async unlinkDevice(deviceId) {
    const code = this.getShareCode();
    const token = this._getSecretToken();
    if (!code || !token) throw new Error('Not registered for sharing');

    const res = await fetch(`${API_BASE}/unlink`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
      body: JSON.stringify({ shareCode: code, deviceId }),
    });

    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Failed: ${res.status}`);
    }

    // Remove from local cache
    this._devices = this._devices.filter(d => d.deviceId !== deviceId);
    setConfig('devices', JSON.stringify(this._devices));
    this.emit('devices-changed', this._devices);

    return { ok: true };
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

    // Ensure deviceId is set for first push
    if (!this._deviceId) {
      let deviceId = getConfig('deviceId');
      if (!deviceId) {
        deviceId = randomUUID();
        setConfig('deviceId', deviceId);
      }
      this._deviceId = deviceId;
    }

    // Start push timer
    if (!this._pushTimer) {
      this._pushTimer = setInterval(() => this._push(), PUSH_INTERVAL_MS);
    }

    // Auto-add default friend (silently — never block registration)
    await this._addDefaultFriend(data.shareCode);

    return {
      shareCode: data.shareCode,
      secretToken: data.secretToken,
      shareURL: `${API_BASE}/share/${data.shareCode}`,
    };
  }

  async _addDefaultFriend(ownCode) {
    const code = DEFAULT_FRIEND_CODE;
    if (code === ownCode) return;
    if (this._friends.some(f => f.code === code)) return;

    try {
      const friendData = await this._fetchFriend(code);
      const friend = {
        code,
        displayName: friendData.displayName || code,
        nickname: null,
        tokens: friendData.todayTokens || 0,
        tokensByModel: friendData.tokensByModel || {},
        weekByModel: friendData.weekByModel || {},
        monthByModel: friendData.monthByModel || {},
        allTimeByModel: friendData.allTimeByModel || {},
        todayDate: friendData.todayDate || null,
        lastTokenChange: friendData.lastTokenChange || null,
      };
      this._friends.push(friend);
      this._persistFriends();
      this._notifyFriendsChanged();

      if (this._friends.length === 1 && !this._fetchTimer) {
        this._fetchTimer = setInterval(() => this._fetchAllFriends(), FETCH_INTERVAL_MS);
      }
    } catch {
      // Silent — don't surface errors for the default friend add
    }
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
      tokensByModel: friendData.tokensByModel || {},
      weekByModel: friendData.weekByModel || {},
      monthByModel: friendData.monthByModel || {},
      allTimeByModel: friendData.allTimeByModel || {},
      todayDate: friendData.todayDate || null,
      lastTokenChange: friendData.lastTokenChange || null,
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
    const today = currentPSTDate();
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

  /** Force an immediate push, bypassing throttle. Used on day boundary. */
  forcePush() {
    this._lastPushTime = 0;
    this._serverAggregate = null;
    this._push();
  }

  async _push() {
    // Throttle
    const now = Date.now();
    if (now - this._lastPushTime < PUSH_THROTTLE_MS) return;

    const code = this.getShareCode();
    const token = this._getSecretToken();
    if (!code || !token) return;

    const tokens = this._data.getTokens();
    const today = currentPSTDate();

    // Detect PST day change: if push fires before the periodic day-boundary check
    // refreshes the data store, todayTokens still holds yesterday's value.
    // Send 0 for the new day so the server doesn't write stale data.
    // Server-side stale-from-yesterday detection handles subsequent pushes if
    // stale data slips through before the data store refreshes.
    const dayChanged = this._lastPushedPSTDate && today !== this._lastPushedPSTDate;
    const effectiveTokens = dayChanged ? 0 : tokens.today;
    const effectiveTokensByModel = dayChanged ? {} : this._data.getTokensByModel('today');

    // Populate per-model breakdown for non-today periods (cumulative, not day-sensitive)
    const weekByModel = this._data.getTokensByModel('week');
    const monthByModel = this._data.getTokensByModel('month');
    const allTimeByModel = this._data.getTokensByModel('allTime');

    try {
      const res = await fetch(`${API_BASE}/push`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${token}`,
        },
        body: JSON.stringify({
          shareCode: code,
          deviceId: this._deviceId,
          todayTokens: effectiveTokens,
          todayDate: today,
          tokensByModel: effectiveTokensByModel,
          weekByModel,
          monthByModel,
          allTimeByModel,
        }),
      });

      this._lastPushTime = Date.now();
      this._lastPushedPSTDate = today;

      // Silently absorb 429s
      if (res.status === 429) return;
      if (!res.ok) return;

      // Read response body for device list, displayName, and server aggregate
      try {
        const body = await res.json();
        if (body.displayName) {
          setConfig('displayName', body.displayName);
        }
        if (Array.isArray(body.devices)) {
          this._devices = body.devices;
          setConfig('devices', JSON.stringify(body.devices));
          this.emit('devices-changed', this._devices);
        }
        if (body.serverAggregate) {
          this._serverAggregate = body.serverAggregate;
          this.emit('aggregate-changed', this._serverAggregate);
        }
      } catch {}
    } catch {
      // Network errors are silent
    }
  }

  // --- Leaderboard methods ---

  isLeaderboardOptIn() {
    try { return getConfig('leaderboardOptIn') === 'true'; } catch { return false; }
  }

  getLeaderboardUsername() {
    try { return getConfig('leaderboardUsername'); } catch { return null; }
  }

  async joinLeaderboard(username, email) {
    const code = this.getShareCode();
    const token = this._getSecretToken();
    if (!code || !token) throw new Error('Not registered for sharing');

    const res = await fetch(`${API_BASE}/leaderboard/join`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
      body: JSON.stringify({ shareCode: code, username, email }),
    });

    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Failed: ${res.status}`);
    }

    const data = await res.json();
    setConfig('leaderboardOptIn', 'true');
    setConfig('leaderboardUsername', data.username || username);
    if (email) setConfig('leaderboardEmail', email);
    return data;
  }

  async leaveLeaderboard() {
    const code = this.getShareCode();
    const token = this._getSecretToken();
    if (!code || !token) throw new Error('Not registered for sharing');

    const res = await fetch(`${API_BASE}/leaderboard/leave`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${token}`,
      },
      body: JSON.stringify({ shareCode: code }),
    });

    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Failed: ${res.status}`);
    }

    setConfig('leaderboardOptIn', 'false');
    setConfig('leaderboardUsername', '');
    setConfig('leaderboardEmail', '');
  }

  async getLeaderboard(date, model, limit) {
    const params = new URLSearchParams();
    if (date) params.set('date', date);
    if (model) params.set('model', model);
    if (limit) params.set('limit', String(limit));

    const res = await fetch(`${API_BASE}/leaderboard?${params}`);
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Failed: ${res.status}`);
    }
    return res.json();
  }

  async getLeaderboardHistory(username, days) {
    const params = new URLSearchParams();
    if (days) params.set('days', String(days));

    const res = await fetch(`${API_BASE}/leaderboard/history/${encodeURIComponent(username)}?${params}`);
    if (!res.ok) {
      const data = await res.json().catch(() => ({}));
      throw new Error(data.error || `Failed: ${res.status}`);
    }
    return res.json();
  }

  async _fetchFriend(code) {
    const res = await fetch(`${API_BASE}/share/${code}`);
    if (!res.ok) throw new Error(`Friend fetch failed: ${res.status}`);
    return res.json();
  }

  async _fetchAllFriends() {
    const today = currentPSTDate();
    let changed = false;

    for (const friend of this._friends) {
      try {
        const data = await this._fetchFriend(friend.code);
        const newTokens = data.todayDate === today ? (data.todayTokens || 0) : 0;
        if (friend.tokens !== newTokens || friend.displayName !== data.displayName) {
          friend.tokens = data.todayTokens || 0;
          friend.tokensByModel = data.tokensByModel || {};
          friend.weekByModel = data.weekByModel || {};
          friend.monthByModel = data.monthByModel || {};
          friend.allTimeByModel = data.allTimeByModel || {};
          friend.todayDate = data.todayDate || null;
          friend.displayName = data.displayName || friend.code;
          friend.lastTokenChange = data.lastTokenChange || data.lastUpdated || null;
          changed = true;
        }
      } catch {
        // Skip friends we can't reach
      }
    }

    // Sync friend tokens with leaderboard values for consistency
    if (this.isLeaderboardOptIn() && this._friends.length > 0) {
      try {
        const model = this._settings.get('modelFilter') || 'opus';
        const lb = await this.getLeaderboard(today, model, 50);
        if (lb && lb.entries && lb.entries.length > 0) {
          const lbLookup = {};
          for (const entry of lb.entries) {
            lbLookup[entry.username.toLowerCase()] = entry.tokens;
          }
          for (const friend of this._friends) {
            const name = (friend.displayName || '').toLowerCase();
            if (name in lbLookup) {
              const lbTokens = lbLookup[name];
              const modelMap = friend.tokensByModel || {};
              // Find matching key (e.g. "claude-opus-4-6" contains "opus")
              const matchingKey = Object.keys(modelMap).find(k =>
                k.toLowerCase().includes(model.toLowerCase())
              );
              if (matchingKey) {
                if (modelMap[matchingKey] !== lbTokens) {
                  modelMap[matchingKey] = lbTokens;
                  friend.tokensByModel = modelMap;
                  friend.tokens = lbTokens;
                  changed = true;
                }
              } else if (Object.keys(modelMap).length > 0) {
                modelMap[model] = lbTokens;
                friend.tokensByModel = modelMap;
                friend.tokens = lbTokens;
                changed = true;
              } else {
                if (friend.tokens !== lbTokens) {
                  friend.tokens = lbTokens;
                  changed = true;
                }
              }
            }
          }
        }
      } catch {
        // Leaderboard sync is best-effort
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

    // Seed leaderboard state from UserDefaults
    const lbOptIn = _readMacDefault('leaderboardOptIn');
    const lbUsername = _readMacDefault('leaderboardUsername');
    const lbEmail = _readMacDefault('leaderboardEmail');
    if (lbOptIn && !getConfig('leaderboardOptIn')) {
      try { setConfig('leaderboardOptIn', lbOptIn === '1' || lbOptIn === 'true' ? 'true' : 'false'); } catch {}
    }
    if (lbUsername && !getConfig('leaderboardUsername')) {
      try { setConfig('leaderboardUsername', lbUsername); } catch {}
    }
    if (lbEmail && !getConfig('leaderboardEmail')) {
      try { setConfig('leaderboardEmail', lbEmail); } catch {}
    }

    // Seed deviceId from UserDefaults
    const macDeviceId = _readMacDefault('deviceId');
    if (macDeviceId && !getConfig('deviceId')) {
      try { setConfig('deviceId', macDeviceId); } catch {}
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
              weekByModel: f.weekByModel || {},
              monthByModel: f.monthByModel || {},
              allTimeByModel: f.allTimeByModel || {},
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
    return execFileSync('/usr/bin/defaults', ['read', 'TokenBox', key], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch { return null; }
}

// PST date for sharing is provided by currentPSTDate() from formatting.mjs
