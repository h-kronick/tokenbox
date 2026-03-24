/**
 * SplitFlapDisplay — The complete 4-row split-flap display assembly.
 * Port of SplitFlapDisplayView.swift.
 *
 * Layout:
 * - Row 1: E-ink label panel (pinned label, e.g. "TODAY")
 * - Row 2: 7 split-flap modules (pinned token counter)
 * - Row 3: E-ink label panel (rotating context label)
 * - Row 4: 7 split-flap modules (context token counter)
 */
import { EInkLabelView } from './EInkLabelView.js';
import { SplitFlapRow } from './SplitFlapRow.js';
import { SplitFlapModule } from './SplitFlapModule.js';
import { FlapSoundEngine } from '../audio/FlapSoundEngine.js';

export class SplitFlapDisplay {
  /**
   * @param {HTMLElement} container - Root element to mount the display into
   * @param {object} [options]
   * @param {string} [options.theme='classic-amber']
   * @param {boolean} [options.soundEnabled=true]
   * @param {number} [options.animationSpeed=1.0]
   */
  constructor(container, options = {}) {
    this._container = container;
    this._soundEnabled = options.soundEnabled ?? true;
    this._animationSpeed = options.animationSpeed ?? 1.0;

    // Initialize sound engine
    FlapSoundEngine.shared.setUp();
    FlapSoundEngine.shared.setEnabled(this._soundEnabled);

    // Apply theme
    this.setTheme(options.theme ?? 'classic-amber');

    // Build the display
    this._buildDOM();
  }

  _buildDOM() {
    // Clear container
    this._container.innerHTML = '';

    // Outer display wrapper
    const display = document.createElement('div');
    display.className = 'split-flap-display';
    display.setAttribute('data-tauri-drag-region', '');

    // Housing
    const housing = document.createElement('div');
    housing.className = 'split-flap-housing';

    // Row 1: E-ink pinned label
    const row1Container = document.createElement('div');
    row1Container.className = 'eink-row';
    this._einkRow1 = new EInkLabelView(row1Container, { isRow1: true });

    // Row 2: Split-flap pinned value
    const row2Container = document.createElement('div');
    row2Container.className = 'flap-row-container';
    this._flapRow2 = new SplitFlapRow(row2Container, {
      moduleCount: 7,
      perPositionSets: SplitFlapModule.TOKEN_POSITION_SETS,
      animationSpeed: this._animationSpeed,
      soundEnabled: this._soundEnabled,
    });

    // Spacer
    const spacer = document.createElement('div');
    spacer.className = 'row-spacer';

    // Row 3: E-ink context label
    const row3Container = document.createElement('div');
    row3Container.className = 'eink-row';
    this._einkRow3 = new EInkLabelView(row3Container, { isRow1: false });

    // Row 4: Split-flap context value
    const row4Container = document.createElement('div');
    row4Container.className = 'flap-row-container';
    this._flapRow4 = new SplitFlapRow(row4Container, {
      moduleCount: 7,
      perPositionSets: SplitFlapModule.TOKEN_POSITION_SETS,
      animationSpeed: this._animationSpeed,
      soundEnabled: this._soundEnabled,
    });

    housing.appendChild(row1Container);
    housing.appendChild(row2Container);
    housing.appendChild(spacer);
    housing.appendChild(row3Container);
    housing.appendChild(row4Container);

    display.appendChild(housing);
    this._container.appendChild(display);
    this._display = display;
    this._housing = housing;
  }

  // ── Public API ──

  /**
   * Set pinned label (Row 1 e-ink panel).
   * @param {string} label - Main label text (e.g. "TODAY")
   * @param {string} [subtitleLeft] - Lower-left subtitle (e.g. model name)
   * @param {string} [subtitleRight] - Lower-right subtitle (e.g. "resets in 11h 46m")
   */
  setPinnedLabel(label, subtitleLeft, subtitleRight) {
    this._einkRow1.setLabel(label);
    if (subtitleLeft !== undefined) this._einkRow1.setSubtitleLeft(subtitleLeft);
    if (subtitleRight !== undefined) this._einkRow1.setSubtitleRight(subtitleRight);
  }

  /**
   * Set pinned token value (Row 2 split-flap modules).
   * @param {string} value - 7-char formatted token string
   */
  setPinnedValue(value) {
    this._flapRow2.setTarget(this._padTokenString(value));
  }

  /**
   * Set context label (Row 3 e-ink panel).
   * @param {string} label - Main label text (e.g. "WEEK", friend name)
   * @param {string} [subtitleLeft]
   * @param {string} [subtitleRight] - e.g. "2m ago" for friends
   */
  setContextLabel(label, subtitleLeft, subtitleRight) {
    this._einkRow3.setLabel(label);
    if (subtitleLeft !== undefined) this._einkRow3.setSubtitleLeft(subtitleLeft);
    if (subtitleRight !== undefined) this._einkRow3.setSubtitleRight(subtitleRight);
  }

  /**
   * Set context token value (Row 4 split-flap modules).
   * @param {string} value - 7-char formatted token string
   */
  setContextValue(value) {
    this._flapRow4.setTarget(this._padTokenString(value));
  }

  /**
   * Apply a theme to the display.
   * @param {string} theme - 'classic-amber', 'green-phosphor', or 'white-minimal'
   */
  setTheme(theme) {
    document.documentElement.setAttribute('data-theme', theme);
    // Also set body background for areas outside the display
    document.body.style.backgroundColor = getComputedStyle(document.documentElement).getPropertyValue('--background');
  }

  /**
   * Enable or disable sound.
   * @param {boolean} enabled
   */
  setSoundEnabled(enabled) {
    this._soundEnabled = enabled;
    FlapSoundEngine.shared.setEnabled(enabled);
    this._flapRow2.setSoundEnabled(enabled);
    this._flapRow4.setSoundEnabled(enabled);
  }

  /**
   * Set sound volume.
   * @param {number} volume - 0 to 1
   */
  setSoundVolume(volume) {
    FlapSoundEngine.shared.setVolume(volume);
  }

  /**
   * Set animation speed.
   * @param {number} speed - Multiplier (1.0 = normal)
   */
  setAnimationSpeed(speed) {
    this._animationSpeed = speed;
    this._flapRow2.setAnimationSpeed(speed);
    this._flapRow4.setAnimationSpeed(speed);
  }

  /**
   * Get the shared sound engine instance.
   */
  get soundEngine() {
    return FlapSoundEngine.shared;
  }

  /**
   * Enable or disable reduced motion mode.
   * @param {boolean} reduced
   */
  setReducedMotion(reduced) {
    this._flapRow2.setReducedMotion(reduced);
    this._flapRow4.setReducedMotion(reduced);
    this._einkRow1.setReducedMotion(reduced);
    this._einkRow3.setReducedMotion(reduced);
  }

  // ── Helpers ──

  /**
   * Pad or truncate a token string to 7 characters.
   * @param {string} str
   * @returns {string}
   */
  _padTokenString(str) {
    const s = str.substring(0, 7);
    return s.length < 7 ? ' '.repeat(7 - s.length) + s : s;
  }
}
