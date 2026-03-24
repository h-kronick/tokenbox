/**
 * SplitFlapModule — A single split-flap character module.
 * Port of SplitFlapModule.swift.
 *
 * Animates through its character set sequentially to reach the target —
 * NEVER jumps directly. The animation replicates a physical split-flap mechanism:
 * 1. Top half of current character folds down (easeIn)
 * 2. Bottom half of next character swings into place (easeOut)
 * 3. Repeat until target character is reached
 */
import { FlapSoundEngine } from '../audio/FlapSoundEngine.js';

export class SplitFlapModule {
  /**
   * @param {HTMLElement} container - Parent element to mount into
   * @param {string[]} characterSet - Ordered character set for this position
   * @param {object} [options]
   * @param {number} [options.flipDuration=0.08] - Total flip duration in seconds
   * @param {number} [options.startDelay=0] - Delay before starting a flip sequence
   * @param {number} [options.animationSpeed=1.0] - Speed multiplier
   * @param {boolean} [options.soundEnabled=true]
   */
  constructor(container, characterSet, options = {}) {
    this._container = container;
    this._characterSet = characterSet;
    this._flipDuration = options.flipDuration ?? 0.08;
    this._startDelay = options.startDelay ?? 0;
    this._animationSpeed = options.animationSpeed ?? 1.0;
    this._soundEnabled = options.soundEnabled ?? true;

    this._currentChar = ' ';
    this._nextChar = ' ';
    this._generation = 0;
    this._flipQueue = [];
    this._isFlipping = false;
    this._reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    window.matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', (e) => {
      this._reducedMotion = e.matches;
    });

    this._buildDOM();
    this._updateDisplay(this._currentChar, this._currentChar);
  }

  get effectiveDuration() {
    return this._flipDuration / Math.max(this._animationSpeed, 0.1);
  }

  /**
   * Set the target character. Triggers sequential flip animation.
   * @param {string} char
   */
  setTarget(char) {
    if (char === this._currentChar && !this._isFlipping) return;

    this._generation++;
    const gen = this._generation;

    if (this._reducedMotion) {
      this._currentChar = char;
      this._nextChar = char;
      this._updateDisplay(char, char);
      return;
    }

    const queue = this._buildFlipQueue(this._currentChar, char);
    if (queue.length === 0) return;

    this._flipQueue = queue;

    const delay = this._startDelay / Math.max(this._animationSpeed, 0.1);
    setTimeout(() => {
      if (this._generation !== gen) return;
      this._processNextFlip(gen);
    }, delay * 1000);
  }

  /** @param {boolean} enabled */
  setSoundEnabled(enabled) {
    this._soundEnabled = enabled;
  }

  /** @param {number} speed */
  setAnimationSpeed(speed) {
    this._animationSpeed = speed;
  }

  /** @param {boolean} reduced */
  setReducedMotion(reduced) {
    this._reducedMotion = reduced;
  }

  // ── DOM Construction ──

  _buildDOM() {
    const module = document.createElement('div');
    module.className = 'flap-module';

    const inner = document.createElement('div');
    inner.className = 'flap-module-inner';

    // Static top (next char, revealed as current folds away)
    this._staticTop = this._createHalf('top', 'static');
    // Animated top (current char, folds down)
    this._animTop = this._createHalf('top', 'animated');
    // Static bottom (current char, visible until covered)
    this._staticBottom = this._createHalf('bottom', 'static');
    // Animated bottom (next char, swings from behind)
    this._animBottom = this._createHalf('bottom', 'animated');

    // Hinge
    const hinge = document.createElement('div');
    hinge.className = 'flap-hinge';

    inner.appendChild(this._staticTop);
    inner.appendChild(this._animTop);
    inner.appendChild(this._staticBottom);
    inner.appendChild(this._animBottom);
    inner.appendChild(hinge);

    module.appendChild(inner);
    this._container.appendChild(module);
    this._module = module;
    this._inner = inner;
  }

  /**
   * @param {'top'|'bottom'} half
   * @param {'static'|'animated'} role
   * @returns {HTMLElement}
   */
  _createHalf(half, role) {
    const el = document.createElement('div');
    el.className = `flap-half flap-${half} ${role}`;

    const inner = document.createElement('div');
    inner.className = 'flap-half-inner';
    inner.textContent = ' ';

    // Set font size based on module height (will be set via CSS)
    el.appendChild(inner);
    return el;
  }

  /**
   * Update the displayed characters on all four flap halves.
   * @param {string} current
   * @param {string} next
   */
  _updateDisplay(current, next) {
    // Font size: 65% of module height
    const h = this._container.offsetHeight || 50;
    const fontSize = h * 0.65;

    const halves = [this._staticTop, this._animTop, this._staticBottom, this._animBottom];
    for (const half of halves) {
      half.querySelector('.flap-half-inner').style.fontSize = `${fontSize}px`;
    }

    // Static top shows NEXT char (revealed under folding current)
    this._staticTop.querySelector('.flap-half-inner').textContent = next;
    // Animated top shows CURRENT char (folds down)
    this._animTop.querySelector('.flap-half-inner').textContent = current;
    // Static bottom shows CURRENT char (visible until covered)
    this._staticBottom.querySelector('.flap-half-inner').textContent = current;
    // Animated bottom shows NEXT char (swings into place)
    this._animBottom.querySelector('.flap-half-inner').textContent = next;
  }

  // ── Animation Logic ──

  /**
   * Build the sequential flip queue from current to target character.
   * Cycles forward only through the character set (like a physical drum).
   * @param {string} from
   * @param {string} to
   * @returns {string[]}
   */
  _buildFlipQueue(from, to) {
    if (from === to) return [];

    const fromIdx = this._characterSet.indexOf(from);
    if (fromIdx === -1) return [to];
    if (!this._characterSet.includes(to)) return [to];

    const queue = [];
    let idx = fromIdx;
    for (let i = 0; i < this._characterSet.length; i++) {
      idx = (idx + 1) % this._characterSet.length;
      queue.push(this._characterSet[idx]);
      if (this._characterSet[idx] === to) break;
    }
    return queue;
  }

  /**
   * Process the next character in the flip queue.
   * Uses CSS transitions for the two-phase flip animation.
   * @param {number} gen - Generation counter to detect interruptions
   */
  _processNextFlip(gen) {
    if (this._generation !== gen || this._flipQueue.length === 0) {
      this._isFlipping = false;
      return;
    }

    this._isFlipping = true;
    const next = this._flipQueue.shift();
    this._nextChar = next;

    const halfDuration = this.effectiveDuration * 0.5 * 1000; // ms

    // Reset animated halves to starting positions
    this._animTop.style.transition = 'none';
    this._animTop.style.transform = 'rotateX(0deg)';
    this._animTop.style.opacity = '1';
    this._animBottom.style.transition = 'none';
    this._animBottom.style.transform = 'rotateX(90deg)';
    this._animBottom.style.opacity = '0';

    // Update display: current on animated top + static bottom, next on static top + animated bottom
    this._updateDisplay(this._currentChar, next);

    // Force reflow to apply reset
    void this._animTop.offsetHeight;

    // Phase 1: Top half folds down (easeIn)
    this._animTop.style.transition = `transform ${halfDuration}ms ease-in, opacity 1ms linear ${halfDuration - 1}ms`;
    this._animTop.style.transform = 'rotateX(-90deg)';
    this._animTop.style.opacity = '0';

    setTimeout(() => {
      if (this._generation !== gen) { this._isFlipping = false; return; }

      // Phase 2: Bottom half swings into place (easeOut)
      this._animBottom.style.opacity = '1';
      this._animBottom.style.transition = `transform ${halfDuration}ms ease-out`;
      this._animBottom.style.transform = 'rotateX(0deg)';

      setTimeout(() => {
        if (this._generation !== gen) { this._isFlipping = false; return; }

        // Play flap click when the flap lands
        if (this._soundEnabled) {
          FlapSoundEngine.shared.playFlap();
        }

        // Advance: next becomes current
        this._currentChar = next;
        this._updateDisplay(next, next);

        // Reset animated halves
        this._animTop.style.transition = 'none';
        this._animTop.style.transform = 'rotateX(0deg)';
        this._animTop.style.opacity = '1';
        this._animBottom.style.transition = 'none';
        this._animBottom.style.transform = 'rotateX(90deg)';
        this._animBottom.style.opacity = '0';

        // Continue with next character in queue
        this._processNextFlip(gen);
      }, halfDuration);
    }, halfDuration);
  }
}

// ── Character Sets ──

SplitFlapModule.DIGIT_SET = [' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', '.'];
SplitFlapModule.ALPHA_SET = [' ', ...Array.from({ length: 26 }, (_, i) => String.fromCharCode(65 + i))];
SplitFlapModule.SUFFIX_SET = [' ', 'K', 'M', 'B', 'T'];

/**
 * Per-position character sets for token display rows.
 * Positions 0-2: digits only
 * Position 3: space or decimal point
 * Positions 4-5: digits only
 * Position 6: digits + K/M/B/T suffixes
 */
SplitFlapModule.TOKEN_POSITION_SETS = (() => {
  const digitOnly = [' ', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
  const dotOnly = [' ', '.'];
  const suffixFlap = [...digitOnly, 'K', 'M', 'B', 'T'];
  return [
    digitOnly,  // pos 0
    digitOnly,  // pos 1
    digitOnly,  // pos 2
    dotOnly,    // pos 3
    digitOnly,  // pos 4
    digitOnly,  // pos 5
    suffixFlap, // pos 6
  ];
})();
