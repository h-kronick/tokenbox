// Blessed-based ASCII split-flap display renderer.

import blessed from 'blessed';

export const THEMES = {
  'classic-amber': { bg: 'black', fg: '#d4a843', flapBg: '#1a1a1a', flapChar: '#d4a843', hinge: '#3a3520', label: '#d4a843', border: '#3a3520' },
  'green-phosphor': { bg: 'black', fg: '#33ff66', flapBg: '#0a0a0a', flapChar: '#33ff66', hinge: '#0a3a0a', label: '#33ff66', border: '#0a3a0a' },
  'white-minimal':  { bg: '#1a1a1a', fg: '#e0e0e0', flapBg: '#2a2a2a', flapChar: '#e0e0e0', hinge: '#3a3a3a', label: '#e0e0e0', border: '#3a3a3a' },
};

const MIN_WIDTH = 38;

// Each flap module: 5 chars wide, 4 lines tall
// ┌───┐
// │ X │
// ├───┤
// └───┘
// 6 modules with 1-space gaps = 6*5 + 5*1 = 35 chars, plus 2 side padding = 37

function renderFlapLine(chars, lineType) {
  const parts = chars.map(ch => {
    switch (lineType) {
      case 'top':    return '\u250c\u2500\u2500\u2500\u2510'; // ┌───┐
      case 'char':   return '\u2502 ' + ch + ' \u2502';       // │ X │
      case 'hinge':  return '\u251c\u2500\u2500\u2500\u2524'; // ├───┤
      case 'bottom': return '\u2514\u2500\u2500\u2500\u2518'; // └───┘
    }
  });
  return parts.join(' ');
}

export class Display {
  constructor(screen) {
    this._screen = screen;
    this._theme = THEMES['classic-amber'];
    this._themeName = 'classic-amber';

    // State
    this._pinnedLabel = 'TODAY';
    this._pinnedLeftSubtitle = '';
    this._pinnedRightSubtitle = '';
    this._pinnedChars = Array(6).fill(' ');
    this._contextLabel = 'WEEK';
    this._contextSubtitle = '';
    this._contextChars = Array(6).fill(' ');

    // Create the main box
    this._box = blessed.box({
      parent: screen,
      top: 'center',
      left: 'center',
      width: MIN_WIDTH + 2,
      height: 16,
      border: { type: 'line' },
      style: {
        border: { fg: this._theme.border },
        bg: this._theme.bg,
        fg: this._theme.fg,
      },
      tags: true,
    });

    // Leaderboard rank indicator (shown when opted in)
    this._leaderboardRank = null; // { rank: N, username: 'foo' }

    // Update available indicator
    this._updateAvailable = false;

    // Status bar
    this._statusBar = blessed.box({
      parent: this._box,
      bottom: 0,
      left: 0,
      right: 0,
      height: 1,
      content: ' [s]hare [l]eader [p]refs [r]efresh [q]uit',
      style: {
        bg: this._theme.bg,
        fg: this._theme.fg,
      },
      tags: true,
    });

    // Note: Ctrl+C / quit handled in app.mjs shutdown()
  }

  _updateStatusBar() {
    const base = ' [s]hare [l]eader [p]refs [r]efresh [q]uit';
    if (this._updateAvailable) {
      this._statusBar.setContent(`${base}  {green-fg}↑ update [u]{/green-fg}`);
    } else {
      this._statusBar.setContent(base);
    }
  }

  getScreen() {
    return this._screen;
  }

  setTheme(name) {
    const theme = THEMES[name];
    if (!theme) return;
    this._theme = theme;
    this._themeName = name;
    this._box.style.border.fg = theme.border;
    this._box.style.bg = theme.bg;
    this._box.style.fg = theme.fg;
    this._statusBar.style.bg = theme.bg;
    this._statusBar.style.fg = theme.fg;
    this.render();
  }

  setPinnedLabel(str, leftSubtitle, rightSubtitle) {
    this._pinnedLabel = str.toUpperCase();
    this._pinnedLeftSubtitle = leftSubtitle || '';
    this._pinnedRightSubtitle = rightSubtitle || '';
  }

  setPinnedValue(str) {
    const padded = str.padStart(6).slice(0, 6);
    this._pinnedChars = padded.split('');
  }

  setContextLabel(str, subtitle) {
    this._contextLabel = str.toUpperCase();
    this._contextSubtitle = subtitle || '';
  }

  setLeaderboardRank(rank, username) {
    if (rank && username) {
      this._leaderboardRank = { rank, username };
    } else {
      this._leaderboardRank = null;
    }
  }

  setUpdateAvailable(val) {
    this._updateAvailable = !!val;
    this._updateStatusBar();
  }

  setContextValue(str) {
    const padded = str.padStart(6).slice(0, 6);
    this._contextChars = padded.split('');
  }

  renderFlap(row, position, char) {
    // row 0 = pinned, row 1 = context
    if (row === 0) {
      this._pinnedChars[position] = char;
    } else {
      this._contextChars[position] = char;
    }
    this.render();
  }

  render() {
    const w = this._screen.width;
    if (w < MIN_WIDTH) {
      this._box.setContent('{center}Terminal too narrow{/center}');
      this._screen.render();
      return;
    }

    const t = this._theme;
    const lines = [];

    // Row 1: Pinned e-ink label with optional left/right subtitles
    const pinnedLabel = `\u2550 ${this._pinnedLabel} \u2550`;
    if (this._pinnedLeftSubtitle || this._pinnedRightSubtitle) {
      const flapWidth = 35; // 6*5 + 5
      const left = this._pinnedLeftSubtitle;
      const right = this._pinnedRightSubtitle ? `resets in ${this._pinnedRightSubtitle}` : '';
      const usedLen = left.length + pinnedLabel.length + right.length;
      const totalGap = flapWidth - usedLen;
      const leftGap = Math.max(1, Math.floor(totalGap / 2));
      const rightGap = Math.max(1, totalGap - leftGap);
      lines.push(`  ${left}${' '.repeat(leftGap)}${pinnedLabel}${' '.repeat(rightGap)}${right}`);
    } else {
      lines.push(`{center}${pinnedLabel}{/center}`);
    }

    // Row 2: Pinned flap row (top/char/hinge/bottom)
    const pTop    = renderFlapLine(this._pinnedChars, 'top');
    const pChar   = renderFlapLine(this._pinnedChars, 'char');
    const pHinge  = renderFlapLine(this._pinnedChars, 'hinge');
    const pBottom = renderFlapLine(this._pinnedChars, 'bottom');
    lines.push(`  ${pTop}`);
    lines.push(`  ${pChar}`);
    lines.push(`  ${pHinge}`);
    lines.push(`  ${pBottom}`);

    // Row 3: Context e-ink label with optional subtitle
    const ctxLabel = `\u2550 ${this._contextLabel} \u2550`;
    if (this._contextSubtitle) {
      const flapWidth = 35; // 6*5 + 5
      const labelLen = ctxLabel.length;
      const subtitleLen = this._contextSubtitle.length;
      const gap = flapWidth - labelLen - subtitleLen;
      const padding = gap > 0 ? ' '.repeat(gap) : '  ';
      lines.push(`  ${ctxLabel}${padding}${this._contextSubtitle}`);
    } else {
      lines.push(`{center}${ctxLabel}{/center}`);
    }

    // Row 4: Context flap row
    const cTop    = renderFlapLine(this._contextChars, 'top');
    const cChar   = renderFlapLine(this._contextChars, 'char');
    const cHinge  = renderFlapLine(this._contextChars, 'hinge');
    const cBottom = renderFlapLine(this._contextChars, 'bottom');
    lines.push(`  ${cTop}`);
    lines.push(`  ${cChar}`);
    lines.push(`  ${cHinge}`);
    lines.push(`  ${cBottom}`);

    // Leaderboard rank indicator or empty line
    if (this._leaderboardRank) {
      const { rank, username } = this._leaderboardRank;
      const rankStr = `#${rank} @${username}`;
      const flapWidth = 35;
      const pad = Math.max(0, flapWidth - rankStr.length);
      lines.push(`  ${' '.repeat(pad)}${rankStr}`);
    } else {
      lines.push('');
    }

    this._box.setContent(lines.join('\n'));
    this._screen.render();
  }
}
