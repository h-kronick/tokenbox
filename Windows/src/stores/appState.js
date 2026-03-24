// App-wide state management — port of AppState.swift
// Context rotation, pinned display, and display string management.

import { formatTokens, timeAgo } from '../lib/formatting.js';
import { tokenStore } from './tokenStore.js';

const { listen } = window.__TAURI__.event;

class AppState {
  constructor() {
    // Pinned row (rows 1-2)
    this.pinnedLabel = 'TODAY';
    this.pinnedValue = '      0';

    // Context row (rows 3-4)
    this.displayLabel = 'WEEK';
    this.displayValue = '      0';
    this.displaySubtitle = null;

    // Context rotation state
    this.contextItems = [];
    this.currentIndex = 0;

    // Settings
    this.pinnedDisplay = 'today';
    this.modelFilter = 'opus';
    this.realtimeFlipDisplay = true;

    // Data source references
    this._tokenStore = null;
    this._friends = [];

    // Rotation timer
    this._rotationTimer = null;
    this._rotationInterval = 15000; // 15 seconds

    // Change listeners
    this._listeners = new Set();

    this._setupListeners();
  }

  /**
   * Set the token store reference.
   * @param {import('./tokenStore.js').TokenStore} store
   */
  setTokenStore(store) {
    this._tokenStore = store;
  }

  /**
   * Set the current friends list.
   * @param {Array} friends
   */
  setFriends(friends) {
    this._friends = friends || [];
  }

  /**
   * Start the 15-second context rotation timer.
   */
  startContextRotation() {
    this.stopContextRotation();
    this._rotationTimer = setInterval(() => {
      this._rebuildAndAdvance();
    }, this._rotationInterval);
  }

  /**
   * Stop the context rotation timer.
   */
  stopContextRotation() {
    if (this._rotationTimer) {
      clearInterval(this._rotationTimer);
      this._rotationTimer = null;
    }
  }

  /**
   * Restart the rotation timer from now (e.g. after jumping to a new friend).
   */
  _restartRotationTimer() {
    this.stopContextRotation();
    this._rotationTimer = setInterval(() => {
      this._rebuildAndAdvance();
    }, this._rotationInterval);
  }

  /**
   * Called every rotation tick — rebuilds items from live data then advances.
   */
  _rebuildAndAdvance() {
    this.rebuildContextItems();
    this._advanceContext();
  }

  /**
   * Full rebuild of context items array.
   * Called on settings/friend changes and rotation ticks.
   */
  rebuildContextItems() {
    const store = this._tokenStore || tokenStore;
    const friends = this._friends;
    const items = [];

    // Always update pinned display
    this._updatePinnedDisplay(store);

    if (friends.length > 0) {
      // Sharing mode: only show friends — your data is already on the top row
      for (const friend of friends) {
        const sub = timeAgo(friend.lastTokenChange);
        items.push({
          label: friend.displayName.slice(0, 7).toUpperCase(),
          value: friend.formattedTokens || formatTokens(friend.currentTokens || 0),
          subtitle: sub,
        });
      }
    } else {
      // Default: rotate through periods — skip the pinned one
      if (this.pinnedDisplay !== 'today') {
        items.push({ label: 'TODAY', value: formatTokens(store.todayTokens) });
      }
      if (this.pinnedDisplay !== 'week') {
        items.push({ label: 'WEEK', value: formatTokens(store.weekTokens) });
      }
      if (this.pinnedDisplay !== 'month') {
        items.push({ label: 'MONTH', value: formatTokens(store.monthTokens) });
      }
      if (this.pinnedDisplay !== 'allTime') {
        items.push({ label: 'TOTAL', value: formatTokens(store.allTimeTokens) });
      }
    }

    const previousCount = this.contextItems.length;
    this.contextItems = items;

    if (items.length > previousCount) {
      // New item added — jump to it immediately and restart rotation
      this.currentIndex = items.length - 1;
      this._restartRotationTimer();
    } else if (this.currentIndex >= items.length) {
      this.currentIndex = 0;
    }

    // Update the display
    this._syncDisplayFromContext();
    this._notify();
  }

  /**
   * Only update pinned row values — called from realtime events without rebuilding context.
   */
  refreshValues() {
    const store = this._tokenStore || tokenStore;
    this._updatePinnedDisplay(store);
    this._notify();
  }

  /**
   * Full rebuild of context items (called on settings/friend changes).
   */
  refreshContext() {
    this.rebuildContextItems();
  }

  /**
   * Update the pinned display row from store data.
   */
  _updatePinnedDisplay(store) {
    switch (this.pinnedDisplay) {
      case 'today':
        this.pinnedLabel = 'TODAY';
        this.pinnedValue = formatTokens(
          this.realtimeFlipDisplay ? store.realtimeDisplayTokens : store.todayTokens
        );
        break;
      case 'week':
        this.pinnedLabel = 'WEEK';
        this.pinnedValue = formatTokens(store.weekTokens);
        break;
      case 'month':
        this.pinnedLabel = 'MONTH';
        this.pinnedValue = formatTokens(store.monthTokens);
        break;
      case 'allTime':
        this.pinnedLabel = 'TOTAL';
        this.pinnedValue = formatTokens(store.allTimeTokens);
        break;
      default:
        this.pinnedLabel = 'TODAY';
        this.pinnedValue = formatTokens(
          this.realtimeFlipDisplay ? store.realtimeDisplayTokens : store.todayTokens
        );
    }
  }

  /**
   * Advance to the next context item.
   */
  _advanceContext() {
    if (this.contextItems.length === 0) return;
    this.currentIndex = (this.currentIndex + 1) % this.contextItems.length;
    this._syncDisplayFromContext();
    this._notify();
  }

  /**
   * Sync display strings from the current context item.
   */
  _syncDisplayFromContext() {
    if (this.contextItems.length > 0 && this.currentIndex < this.contextItems.length) {
      const item = this.contextItems[this.currentIndex];
      this.displayLabel = item.label;
      this.displayValue = item.value;
      this.displaySubtitle = item.subtitle || null;
    }
  }

  /**
   * Subscribe to state changes.
   * @param {Function} fn - Callback
   * @returns {Function} Unsubscribe function
   */
  onChange(fn) {
    this._listeners.add(fn);
    return () => this._listeners.delete(fn);
  }

  _notify() {
    for (const fn of this._listeners) {
      try { fn(); } catch (e) { console.error('AppState listener error:', e); }
    }
  }

  async _setupListeners() {
    // Sync settings from other windows
    await listen('display-settings-changed', (event) => {
      const payload = event.payload || {};
      if (payload.pinnedDisplay !== undefined) {
        this.pinnedDisplay = payload.pinnedDisplay;
      }
      if (payload.modelFilter !== undefined) {
        this.modelFilter = payload.modelFilter;
      }
      if (payload.realtimeFlipDisplay !== undefined) {
        this.realtimeFlipDisplay = payload.realtimeFlipDisplay;
      }
      this.refreshContext();
    });

    // Rebuild context when friends change
    await listen('friends-changed', () => {
      this.refreshContext();
    });

    // Refresh values on realtime delta events
    await listen('realtime-delta', () => {
      this.refreshValues();
    });

    // Refresh values on live events
    await listen('live-event', () => {
      this.refreshValues();
    });

    // Refresh context on token data changes (week/month/allTime may have changed)
    await listen('token-data-changed', () => {
      this.refreshContext();
    });
  }
}

// Singleton
export const appState = new AppState();
export default appState;
