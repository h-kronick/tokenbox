// Settings manager — persists preferences and friends list to JSON files.

import { EventEmitter } from 'node:events';
import { execFileSync } from 'node:child_process';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';

const SETTINGS_DIR = join(homedir(), '.tokenbox');
const SETTINGS_PATH = join(SETTINGS_DIR, 'settings.json');
const FRIENDS_PATH = join(SETTINGS_DIR, 'friends.json');

const DEFAULTS = {
  modelFilter: 'opus',
  pinnedPeriod: 'today',
  animationSpeed: 1.0,
  theme: 'classic-amber',
  soundEnabled: false,
  realtimeFlip: true,
};

export class SettingsManager extends EventEmitter {
  constructor() {
    super();
    this._settings = { ...DEFAULTS };
    this._friends = [];
    this._load();
  }

  get(key) {
    return this._settings[key];
  }

  set(key, value) {
    if (this._settings[key] === value) return;
    this._settings[key] = value;
    this._save();
    this.emit('settings-changed', { key, value, settings: { ...this._settings } });
  }

  getAll() {
    return { ...this._settings };
  }

  getFriends() {
    return [...this._friends];
  }

  setFriends(friends) {
    this._friends = friends || [];
    this._saveFriends();
  }

  _load() {
    mkdirSync(SETTINGS_DIR, { recursive: true });

    try {
      const raw = readFileSync(SETTINGS_PATH, 'utf8');
      const parsed = JSON.parse(raw);
      this._settings = { ...DEFAULTS, ...parsed };
    } catch {
      // File doesn't exist or is corrupt — use defaults and create
      this._save();
    }

    try {
      const raw = readFileSync(FRIENDS_PATH, 'utf8');
      this._friends = JSON.parse(raw);
    } catch {
      this._friends = [];
    }

    // On macOS, overlay with UserDefaults from the native app
    if (process.platform === 'darwin') {
      this._loadMacDefaults();
    }
  }

  _loadMacDefaults() {
    const macModelFilter = _readMacDefault('modelFilter');
    if (macModelFilter) this._settings.modelFilter = macModelFilter;

    const macPinned = _readMacDefault('pinnedDisplay') || _readMacDefault('pinnedPeriod');
    if (macPinned) this._settings.pinnedPeriod = macPinned;

    const macTheme = _readMacDefault('theme');
    if (macTheme) this._settings.theme = macTheme;
  }

  _save() {
    try {
      mkdirSync(SETTINGS_DIR, { recursive: true });
      writeFileSync(SETTINGS_PATH, JSON.stringify(this._settings, null, 2) + '\n', 'utf8');
    } catch {
      // Silent — settings are best-effort
    }
  }

  _saveFriends() {
    try {
      mkdirSync(SETTINGS_DIR, { recursive: true });
      writeFileSync(FRIENDS_PATH, JSON.stringify(this._friends, null, 2) + '\n', 'utf8');
    } catch {
      // Silent
    }
  }
}

function _readMacDefault(key) {
  try {
    return execFileSync('/usr/bin/defaults', ['read', 'TokenBox', key], { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch { return null; }
}
