// Tray icon state management — port of MenuBarState.swift
// Polls token store at 500ms and updates the system tray via Rust backend.

import { formatMenuBarTokens } from '../lib/formatting.js';
import { tokenStore } from './tokenStore.js';

const { invoke } = window.__TAURI__.core;

class MenuBarState {
  constructor() {
    this.displayTokens = 0;
    this.displayLabel = 'today';
    this.isStreaming = false;

    this._lastKnownTokens = 0;
    this._lastChangeTime = 0;
    this._pollTimer = null;
    this._tokenStore = null;
  }

  /**
   * Start polling. Call once after tokenStore is initialized.
   * @param {import('./tokenStore.js').TokenStore} [store]
   */
  start(store) {
    this._tokenStore = store || tokenStore;
    if (this._pollTimer) return;
    this._pollTimer = setInterval(() => this._poll(), 500);
  }

  /**
   * Stop polling.
   */
  stop() {
    if (this._pollTimer) {
      clearInterval(this._pollTimer);
      this._pollTimer = null;
    }
  }

  _poll() {
    const ds = this._tokenStore;
    if (!ds) return;

    // Read pinned period from appState's pinnedDisplay
    // We read from the store directly since settings sync through events
    const pinned = this.displayLabel;
    let newTokens;
    switch (pinned) {
      case 'week': newTokens = ds.weekTokens; break;
      case 'month': newTokens = ds.monthTokens; break;
      case 'allTime': newTokens = ds.allTimeTokens; break;
      default: newTokens = ds.realtimeDisplayTokens; break;
    }

    if (newTokens !== this._lastKnownTokens) {
      this._lastKnownTokens = newTokens;
      this._lastChangeTime = Date.now();
    }
    this.displayTokens = newTokens;

    // Streaming = tokens changed within the last 3 seconds
    this.isStreaming = (Date.now() - this._lastChangeTime) < 3000 && this._lastChangeTime > 0;

    // Update tray via Rust backend
    const formattedCount = formatMenuBarTokens(newTokens);
    invoke('update_tray_state', {
      count: formattedCount,
      isStreaming: this.isStreaming,
    }).catch(() => {}); // Swallow errors — tray updates are best-effort
  }

  /**
   * Update the pinned display label (called when settings change).
   * @param {string} label
   */
  setPinnedDisplay(label) {
    this.displayLabel = label;
  }
}

// Singleton
export const menuBarState = new MenuBarState();
export default menuBarState;
