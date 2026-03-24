// Sharing state management — port of SharingManager.swift
// Manages registration, friends, and token sharing via Rust backend.

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

class SharingStore {
  constructor() {
    this.isRegistered = false;
    this.sharingEnabled = false;
    this.friends = [];
    this.shareCode = '';
    this.displayName = '';
    this.lastError = null;

    // Change listeners
    this._listeners = new Set();

    this._setupListeners();
  }

  /**
   * Register for sharing with a display name.
   * @param {string} name - Display name (max 7 chars)
   */
  async register(name) {
    try {
      this.lastError = null;
      const result = await invoke('register_sharing', { displayName: name.slice(0, 7) });
      this.shareCode = result.shareCode || '';
      this.displayName = name.slice(0, 7);
      this.isRegistered = true;
      this.sharingEnabled = true;
      this._notify();
    } catch (e) {
      this.lastError = e.toString();
      this._notify();
    }
  }

  /**
   * Add a friend by share code or URL.
   * @param {string} input - 6-char share code or URL containing one
   */
  async addFriend(input) {
    try {
      this.lastError = null;
      await invoke('add_friend', { input: input.trim() });
      await this.getFriends();
    } catch (e) {
      this.lastError = e.toString();
      this._notify();
      throw e;
    }
  }

  /**
   * Remove a friend by share code.
   * @param {string} code - 6-char share code
   */
  async removeFriend(code) {
    try {
      this.lastError = null;
      await invoke('remove_friend', { code });
      await this.getFriends();
    } catch (e) {
      this.lastError = e.toString();
      this._notify();
    }
  }

  /**
   * Fetch the current friends list from backend.
   */
  async getFriends() {
    try {
      const friends = await invoke('get_friends');
      this.friends = (friends || []).map(f => new CloudFriend(f));
      this._notify();
    } catch (e) {
      console.error('SharingStore.getFriends failed:', e);
    }
  }

  /**
   * Reset registration and clear all sharing state.
   */
  async resetRegistration() {
    try {
      await invoke('reset_registration');
      this.isRegistered = false;
      this.sharingEnabled = false;
      this.shareCode = '';
      this.displayName = '';
      this.lastError = null;
      this._notify();
    } catch (e) {
      this.lastError = e.toString();
      this._notify();
    }
  }

  /**
   * Push current token data to the sharing server.
   * @param {object} data - Token data payload
   */
  async pushMyTokens(data) {
    try {
      await invoke('push_tokens', data);
    } catch (e) {
      this.lastError = e.toString();
      this._notify();
    }
  }

  /**
   * Subscribe to state changes.
   * @param {Function} fn
   * @returns {Function} Unsubscribe
   */
  onChange(fn) {
    this._listeners.add(fn);
    return () => this._listeners.delete(fn);
  }

  _notify() {
    for (const fn of this._listeners) {
      try { fn(); } catch (e) { console.error('SharingStore listener error:', e); }
    }
  }

  async _setupListeners() {
    await listen('friends-changed', (event) => {
      const payload = event.payload;
      if (payload && payload.friends) {
        this.friends = payload.friends.map(f => new CloudFriend(f));
        this._notify();
      }
    });
  }
}

/**
 * Represents a friend's shared token data.
 * Port of CloudFriend from the Swift app.
 */
class CloudFriend {
  constructor(data) {
    this.shareCode = data.shareCode || '';
    this.displayName = data.displayName || '';
    this.todayTokens = data.todayTokens || 0;
    this.todayDate = data.todayDate || '';
    this.tokensByModel = data.tokensByModel || {};
    this.weekByModel = data.weekByModel || {};
    this.monthByModel = data.monthByModel || {};
    this.allTimeByModel = data.allTimeByModel || {};
    this.lastTokenChange = data.lastTokenChange || null;
  }

  /**
   * Get filtered token count for a given period and model filter.
   * @param {string|null} modelFilter - Model substring filter, or null for all
   * @param {string} period - "today", "week", "month", "allTime"
   * @returns {number}
   */
  tokens(modelFilter, period) {
    const modelMap = this._getModelMap(period);

    // Stale data protection: if friend's todayDate doesn't match local today, return 0
    if (period === 'today') {
      const now = new Date();
      const localToday = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')}`;
      if (this.todayDate && this.todayDate.slice(0, 10) !== localToday) {
        return 0;
      }
    }

    // If per-model maps are empty, fall back to todayTokens for today period
    if (!modelMap || Object.keys(modelMap).length === 0) {
      if (period === 'today') return this.todayTokens;
      return 0;
    }

    // Apply model filter
    if (modelFilter) {
      const filterLower = modelFilter.toLowerCase();
      let total = 0;
      for (const [model, count] of Object.entries(modelMap)) {
        if (model.toLowerCase().includes(filterLower)) {
          total += (count || 0);
        }
      }
      return total;
    }

    // No filter — sum all models
    let total = 0;
    for (const count of Object.values(modelMap)) {
      total += (count || 0);
    }
    return total;
  }

  /**
   * Get the per-model map for a given period.
   */
  _getModelMap(period) {
    switch (period) {
      case 'today': return this.tokensByModel;
      case 'week': return this.weekByModel;
      case 'month': return this.monthByModel;
      case 'allTime': return this.allTimeByModel;
      default: return this.tokensByModel;
    }
  }
}

// Singleton
export const sharingStore = new SharingStore();
export { CloudFriend };
export default sharingStore;
