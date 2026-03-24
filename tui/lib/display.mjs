// Blessed-based ASCII split-flap display renderer.

import blessed from 'blessed';

export const THEMES = {
  'classic-amber': { bg: 'black', fg: '#d4a843', flapBg: '#1a1a1a', flapChar: '#d4a843', hinge: '#3a3520', label: '#d4a843', border: '#3a3520' },
  'green-phosphor': { bg: 'black', fg: '#33ff66', flapBg: '#0a0a0a', flapChar: '#33ff66', hinge: '#0a3a0a', label: '#33ff66', border: '#0a3a0a' },
  'white-minimal':  { bg: '#1a1a1a', fg: '#e0e0e0', flapBg: '#2a2a2a', flapChar: '#e0e0e0', hinge: '#3a3a3a', label: '#e0e0e0', border: '#3a3a3a' },
};

const MIN_WIDTH = 44;

// Each flap module: 5 chars wide, 4 lines tall
// ┌───┐
// │ X │
// ├───┤
// └───┘
// 7 modules with 1-space gaps = 7*5 + 6*1 = 41 chars, plus 2 side padding = 43

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
    this._pinnedChars = Array(7).fill(' ');
    this._contextLabel = 'WEEK';
    this._contextSubtitle = '';
    this._contextChars = Array(7).fill(' ');

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

    // Status bar
    this._statusBar = blessed.box({
      parent: this._box,
      bottom: 0,
      left: 0,
      right: 0,
      height: 1,
      content: '  [s]hare  [p]refs  [r]efresh  [q]uit',
      style: {
        bg: this._theme.bg,
        fg: this._theme.fg,
      },
      tags: true,
    });

    // Handle Ctrl+C for clean exit
    screen.key(['C-c'], () => {
      screen.destroy();
      process.exit(0);
    });
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

  setPinnedLabel(str) {
    this._pinnedLabel = str.toUpperCase();
  }

  setPinnedValue(str) {
    const padded = str.padStart(7).slice(0, 7);
    this._pinnedChars = padded.split('');
  }

  setContextLabel(str, subtitle) {
    this._contextLabel = str.toUpperCase();
    this._contextSubtitle = subtitle || '';
  }

  setContextValue(str) {
    const padded = str.padStart(7).slice(0, 7);
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

    // Row 1: Pinned e-ink label
    const pinnedLabel = `\u2550 ${this._pinnedLabel} \u2550`;
    lines.push(`{center}${pinnedLabel}{/center}`);

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
      const flapWidth = 41; // 7*5 + 6
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

    // Empty line before status bar
    lines.push('');

    this._box.setContent(lines.join('\n'));
    this._screen.render();
  }
}
