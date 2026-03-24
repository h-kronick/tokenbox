/**
 * SplitFlapRow — A horizontal row of 7 SplitFlapModule instances
 * with staggered animation timing.
 * Port of SplitFlapRow.swift.
 */
import { SplitFlapModule } from './SplitFlapModule.js';

export class SplitFlapRow {
  /**
   * @param {HTMLElement} container - Parent element to mount into
   * @param {object} [options]
   * @param {number} [options.moduleCount=7]
   * @param {string[][]} [options.perPositionSets] - Per-position character sets
   * @param {string[]} [options.characterSet] - Fallback character set for all positions
   * @param {number} [options.animationSpeed=1.0]
   * @param {boolean} [options.soundEnabled=true]
   */
  constructor(container, options = {}) {
    this._container = container;
    this._moduleCount = options.moduleCount ?? 7;
    this._animationSpeed = options.animationSpeed ?? 1.0;
    this._soundEnabled = options.soundEnabled ?? true;

    const perPositionSets = options.perPositionSets ?? null;
    const defaultSet = options.characterSet ?? SplitFlapModule.DIGIT_SET;

    // Build DOM
    const row = document.createElement('div');
    row.className = 'flap-row';
    container.appendChild(row);
    this._row = row;

    // Create modules with staggered delays
    this._modules = [];
    for (let i = 0; i < this._moduleCount; i++) {
      const charSet = (perPositionSets && i < perPositionSets.length)
        ? perPositionSets[i]
        : defaultSet;

      const delay = this._staggerDelay(i);

      const module = new SplitFlapModule(row, charSet, {
        flipDuration: 0.08,
        startDelay: delay,
        animationSpeed: this._animationSpeed,
        soundEnabled: this._soundEnabled,
      });
      this._modules.push(module);
    }
  }

  /**
   * Set the target value for the entire row.
   * @param {string} value - Must be exactly 7 characters (padded by caller)
   */
  setTarget(value) {
    const chars = value.padEnd(this._moduleCount, ' ');
    for (let i = 0; i < this._moduleCount; i++) {
      this._modules[i].setTarget(chars[i]);
    }
  }

  /** @param {boolean} enabled */
  setSoundEnabled(enabled) {
    this._soundEnabled = enabled;
    for (const m of this._modules) {
      m.setSoundEnabled(enabled);
    }
  }

  /** @param {number} speed */
  setAnimationSpeed(speed) {
    this._animationSpeed = speed;
    for (const m of this._modules) {
      m.setAnimationSpeed(speed);
    }
  }

  /** @param {boolean} reduced */
  setReducedMotion(reduced) {
    for (const m of this._modules) {
      m.setReducedMotion(reduced);
    }
  }

  /**
   * Generate stagger delay for a module at the given index.
   * Combines base offset with random jitter for cascading "waterfall" effect.
   * Matches FlipAnimation.staggerDelay(for:) in Swift.
   * @param {number} index
   * @returns {number} Delay in seconds
   */
  _staggerDelay(index) {
    const base = index * 0.03;
    const jitter = 0.05 + Math.random() * 0.10; // 50-150ms
    return base + jitter;
  }
}
