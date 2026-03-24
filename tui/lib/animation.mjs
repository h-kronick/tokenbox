// Split-flap animation engine — characters cycle sequentially through the charset, never jump.

const BASE_FLIP_MS = 80;

export class SplitFlapModule {
  constructor(charset) {
    this._charset = charset;
    this._current = charset[0]; // start at space
    this._target = charset[0];
    this._flipQueue = [];
  }

  get current() {
    return this._current;
  }

  get isFlipping() {
    return this._flipQueue.length > 0;
  }

  setTarget(char) {
    if (char === this._current && this._flipQueue.length === 0) return;

    const cs = this._charset;
    let startIdx = cs.indexOf(this._flipQueue.length > 0 ? this._flipQueue[this._flipQueue.length - 1] : this._current);
    if (startIdx === -1) startIdx = 0;

    let targetIdx = cs.indexOf(char);
    if (targetIdx === -1) targetIdx = 0; // fallback to space

    this._flipQueue = [];
    if (startIdx === targetIdx) return;

    // Cycle forward through charset, wrapping around
    let i = startIdx;
    while (true) {
      i = (i + 1) % cs.length;
      this._flipQueue.push(cs[i]);
      if (i === targetIdx) break;
    }
    this._target = char;
  }

  step() {
    if (this._flipQueue.length === 0) return false;
    this._current = this._flipQueue.shift();
    return this._flipQueue.length > 0;
  }
}

export class SplitFlapRow {
  constructor(positionSets) {
    this._modules = positionSets.map(cs => new SplitFlapModule(cs));
    this._timers = [];
  }

  get modules() {
    return this._modules;
  }

  setTarget(str) {
    const padded = str.padEnd(this._modules.length).slice(0, this._modules.length);
    for (let i = 0; i < this._modules.length; i++) {
      this._modules[i].setTarget(padded[i]);
    }
  }

  startAnimation(renderCallback, speed = 1.0) {
    // Clear any existing animation timers
    this._timers.forEach(t => clearTimeout(t));
    this._timers = [];

    const flipInterval = BASE_FLIP_MS / speed;

    for (let i = 0; i < this._modules.length; i++) {
      const mod = this._modules[i];
      if (!mod.isFlipping) continue;

      // Staggered start: base delay + random jitter
      const delay = i * 30 + (50 + Math.random() * 100);

      const startFlipping = () => {
        const tick = () => {
          const more = mod.step();
          renderCallback(i, mod.current);
          if (more) {
            const timer = setTimeout(tick, flipInterval);
            this._timers.push(timer);
          }
        };
        tick();
      };

      const timer = setTimeout(startFlipping, delay);
      this._timers.push(timer);
    }
  }

  stopAnimation() {
    this._timers.forEach(t => clearTimeout(t));
    this._timers = [];
  }
}
