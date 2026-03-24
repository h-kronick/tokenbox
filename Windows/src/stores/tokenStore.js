// Token data bindings to Rust backend — port of TokenDataStore.swift
// Singleton store that manages all token counts and listens for backend events.

const { invoke } = window.__TAURI__.core;
const { listen } = window.__TAURI__.event;

class TokenStore {
  constructor() {
    this.todayTokens = 0;
    this.weekTokens = 0;
    this.monthTokens = 0;
    this.allTimeTokens = 0;
    this.realtimeDelta = 0;
    this.modelFilter = 'opus';

    // Per-model breakdowns for each period
    this.todayByModel = [];
    this.weekByModel = [];
    this.monthByModel = [];
    this.allTimeByModel = [];

    // Change listeners
    this._listeners = new Set();

    this._setupListeners();
  }

  /** Computed: accurate DB total + live intermediate delta */
  get realtimeDisplayTokens() {
    return this.todayTokens + this.realtimeDelta;
  }

  /**
   * Get token count for a given period.
   * @param {string} period - "today", "week", "month", "allTime"
   * @returns {number}
   */
  getForPeriod(period) {
    switch (period) {
      case 'today': return this.realtimeDisplayTokens;
      case 'week': return this.weekTokens;
      case 'month': return this.monthTokens;
      case 'allTime': return this.allTimeTokens;
      default: return this.realtimeDisplayTokens;
    }
  }

  /**
   * Fetch all token data from the Rust backend.
   */
  async refresh() {
    try {
      const data = await invoke('get_token_data');
      this.todayTokens = data.todayTokens || 0;
      this.weekTokens = data.weekTokens || 0;
      this.monthTokens = data.monthTokens || 0;
      this.allTimeTokens = data.allTimeTokens || 0;
      this.todayByModel = data.todayByModel || [];
      this.weekByModel = data.weekByModel || [];
      this.monthByModel = data.monthByModel || [];
      this.allTimeByModel = data.allTimeByModel || [];
      // Reset realtime delta — DB totals now include completed events
      this.realtimeDelta = 0;
      this._notify();
    } catch (e) {
      console.error('TokenStore.refresh failed:', e);
    }
  }

  /**
   * Set the model filter and refresh data.
   * @param {string|null} filter - Model substring filter, or null for all
   */
  async setModelFilter(filter) {
    this.modelFilter = filter;
    try {
      await invoke('set_model_filter', { filter });
      await this.refresh();
    } catch (e) {
      console.error('TokenStore.setModelFilter failed:', e);
    }
  }

  /**
   * Subscribe to store changes.
   * @param {Function} fn - Callback invoked on any change
   * @returns {Function} Unsubscribe function
   */
  onChange(fn) {
    this._listeners.add(fn);
    return () => this._listeners.delete(fn);
  }

  _notify() {
    for (const fn of this._listeners) {
      try { fn(); } catch (e) { console.error('TokenStore listener error:', e); }
    }
  }

  async _setupListeners() {
    // Auto-refresh when backend signals new token data
    await listen('token-data-changed', (event) => {
      const data = event.payload;
      if (data) {
        this.todayTokens = data.todayTokens || 0;
        this.weekTokens = data.weekTokens || 0;
        this.monthTokens = data.monthTokens || 0;
        this.allTimeTokens = data.allTimeTokens || 0;
        if (data.todayByModel) this.todayByModel = data.todayByModel;
        if (data.weekByModel) this.weekByModel = data.weekByModel;
        if (data.monthByModel) this.monthByModel = data.monthByModel;
        if (data.allTimeByModel) this.allTimeByModel = data.allTimeByModel;
        this.realtimeDelta = 0;
        this._notify();
      }
    });

    // Accumulate realtime deltas from streaming events
    await listen('realtime-delta', (event) => {
      const { delta, model } = event.payload;
      // Only accumulate for the selected model filter
      if (this.modelFilter) {
        if (!model || !model.toLowerCase().includes(this.modelFilter.toLowerCase())) {
          return;
        }
      }
      this.realtimeDelta += (delta || 0);
      this._notify();
    });
  }
}

// Singleton
export const tokenStore = new TokenStore();
export default tokenStore;
