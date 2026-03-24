/**
 * EInkLabelView — An e-ink style label panel.
 * Port of EInkLabelView.swift.
 *
 * Renders a recessed panel with a main centered label, plus optional
 * subtitle text at the bottom corners (model name, reset countdown).
 * Text changes trigger a brief refresh animation (fade out → update → fade in).
 */
export class EInkLabelView {
  /**
   * @param {HTMLElement} container - Parent element to mount into
   * @param {object} [options]
   * @param {boolean} [options.isRow1=false] - If true, uses taller min-height (52px)
   */
  constructor(container, options = {}) {
    this._container = container;
    this._currentLabel = '';
    this._hasAppeared = false;
    this._isRefreshing = false;
    this._reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    window.matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', (e) => {
      this._reducedMotion = e.matches;
    });

    this._buildDOM(options.isRow1 ?? false);
  }

  _buildDOM(isRow1) {
    const panel = document.createElement('div');
    panel.className = 'eink-panel' + (isRow1 ? ' row1' : '');

    const content = document.createElement('div');
    content.className = 'eink-panel-content';

    const label = document.createElement('div');
    label.className = 'label';
    label.textContent = '';

    const subtitleBar = document.createElement('div');
    subtitleBar.className = 'subtitle-bar';

    const subtitleLeft = document.createElement('span');
    subtitleLeft.className = 'subtitle-left';
    subtitleLeft.textContent = '';

    const subtitleRight = document.createElement('span');
    subtitleRight.className = 'subtitle-right';
    subtitleRight.textContent = '';

    subtitleBar.appendChild(subtitleLeft);
    subtitleBar.appendChild(subtitleRight);

    content.appendChild(label);
    content.appendChild(subtitleBar);
    panel.appendChild(content);
    this._container.appendChild(panel);

    this._panel = panel;
    this._content = content;
    this._label = label;
    this._subtitleLeft = subtitleLeft;
    this._subtitleRight = subtitleRight;
  }

  /**
   * Update the main label text with refresh animation.
   * @param {string} text
   */
  setLabel(text) {
    const trimmed = text.trim();

    if (!this._hasAppeared) {
      this._currentLabel = trimmed;
      this._label.textContent = trimmed.toUpperCase();
      this._hasAppeared = true;
      return;
    }

    if (trimmed === this._currentLabel) return;

    if (this._reducedMotion) {
      this._currentLabel = trimmed;
      this._label.textContent = trimmed.toUpperCase();
      return;
    }

    // E-ink refresh animation: fade out (80ms) → update → fade in (150ms)
    if (this._isRefreshing) {
      // If already refreshing, just queue the update
      this._currentLabel = trimmed;
      this._label.textContent = trimmed.toUpperCase();
      return;
    }

    this._isRefreshing = true;
    this._content.classList.add('refreshing');

    setTimeout(() => {
      this._currentLabel = trimmed;
      this._label.textContent = trimmed.toUpperCase();

      // Remove refreshing class to trigger fade-in
      this._content.classList.remove('refreshing');
      // Transition back to opacity 1 is handled by CSS (150ms ease-out would need
      // to be set dynamically since CSS transition is on the class). We use a
      // simple approach: set transition for the fade-in.
      this._content.style.transition = 'opacity 150ms ease-out';
      setTimeout(() => {
        this._content.style.transition = '';
        this._isRefreshing = false;
      }, 150);
    }, 80);
  }

  /**
   * Update the left subtitle (e.g. model name).
   * @param {string} text
   */
  setSubtitleLeft(text) {
    this._subtitleLeft.textContent = text || '';
  }

  /**
   * Update the right subtitle (e.g. "resets in Xh Ym" or "2m ago").
   * @param {string} text
   */
  setSubtitleRight(text) {
    this._subtitleRight.textContent = text || '';
  }

  /** @param {boolean} reduced */
  setReducedMotion(reduced) {
    this._reducedMotion = reduced;
  }
}
