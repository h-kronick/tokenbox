// Auto-update checker — compares local git HEAD to remote.
// Polls every 30 minutes. The repo lives at ~/.tokenbox/repo.

import { execSync } from 'node:child_process';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { existsSync } from 'node:fs';

const REPO_DIR = join(homedir(), '.tokenbox', 'repo');
const REMOTE_URL = 'https://github.com/h-kronick/tokenbox.git';
const CHECK_INTERVAL_MS = 30 * 60 * 1000; // 30 minutes

export class UpdateChecker {
  constructor() {
    this._available = false;
    this._localSHA = '';
    this._remoteSHA = '';
    this._dismissedSHA = '';
    this._timer = null;
    this._onUpdate = null;
  }

  get updateAvailable() {
    return this._available;
  }

  /** Set callback: called with (available: boolean) when state changes. */
  onUpdate(fn) {
    this._onUpdate = fn;
  }

  start() {
    this.check();
    this._timer = setInterval(() => this.check(), CHECK_INTERVAL_MS);
  }

  stop() {
    if (this._timer) {
      clearInterval(this._timer);
      this._timer = null;
    }
  }

  dismiss() {
    this._dismissedSHA = this._remoteSHA;
    this._setAvailable(false);
  }

  check() {
    if (!existsSync(REPO_DIR)) return;

    try {
      this._localSHA = execSync('git rev-parse HEAD', {
        cwd: REPO_DIR, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'],
      }).trim().slice(0, 12);

      const lsRemote = execSync(`git ls-remote ${REMOTE_URL} HEAD`, {
        encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'], timeout: 10000,
      }).trim();
      this._remoteSHA = (lsRemote.split('\t')[0] || '').slice(0, 12);

      if (!this._localSHA || !this._remoteSHA) return;

      const available = this._localSHA !== this._remoteSHA
        && this._remoteSHA !== this._dismissedSHA;
      this._setAvailable(available);
    } catch {
      // Network error or git not available — silently skip
    }
  }

  _setAvailable(val) {
    if (val !== this._available) {
      this._available = val;
      if (this._onUpdate) this._onUpdate(val);
    }
  }
}
