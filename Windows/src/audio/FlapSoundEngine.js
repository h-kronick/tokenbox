/**
 * FlapSoundEngine — Web Audio API procedural synthesis of split-flap click sounds.
 * Port of FlapSoundEngine.swift. Singleton pattern.
 *
 * Synthesizes a 55ms click buffer with 4 layered components:
 * 1. Initial click transient (0-3ms) — 2.5kHz damped sine burst
 * 2. Flutter/whoosh (3-35ms) — filtered noise
 * 3. Settle click (35-38ms) — softer secondary transient
 * 4. Resonance tail (38-55ms) — faint damped ring
 */
export class FlapSoundEngine {
  /** @type {FlapSoundEngine|null} */
  static _instance = null;

  static get shared() {
    if (!FlapSoundEngine._instance) {
      FlapSoundEngine._instance = new FlapSoundEngine();
    }
    return FlapSoundEngine._instance;
  }

  constructor() {
    /** @type {AudioContext|null} */
    this._ctx = null;
    /** @type {GainNode|null} */
    this._masterGain = null;
    /** @type {AudioBuffer|null} */
    this._flapBuffer = null;
    this._enabled = true;
    this._volume = 0.5;
    this._isSetUp = false;
    this._reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

    // Listen for reduced motion changes
    window.matchMedia('(prefers-reduced-motion: reduce)').addEventListener('change', (e) => {
      this._reducedMotion = e.matches;
    });
  }

  /**
   * Initialize the audio context and synthesize the flap sound buffer.
   * Call once at app startup. Idempotent.
   */
  setUp() {
    if (this._isSetUp) return;

    try {
      this._ctx = new AudioContext({ sampleRate: 44100 });
      this._masterGain = this._ctx.createGain();
      this._masterGain.gain.value = this._volume;
      this._masterGain.connect(this._ctx.destination);

      this._flapBuffer = this._synthesizeFlapSound();
      this._isSetUp = true;
    } catch (e) {
      // Audio setup failed silently — sound just won't play
    }
  }

  /**
   * Trigger a single flap click with subtle per-trigger randomization.
   */
  playFlap() {
    if (!this._enabled || !this._isSetUp || !this._flapBuffer || !this._ctx || this._reducedMotion) return;

    // Resume context if suspended (browsers require user gesture)
    if (this._ctx.state === 'suspended') {
      this._ctx.resume();
    }

    const source = this._ctx.createBufferSource();
    source.buffer = this._flapBuffer;

    // +/- 4% pitch variation
    source.playbackRate.value = 0.96 + Math.random() * 0.08;

    // Per-trigger gain node: base 0.35 +/- 15%
    const gainNode = this._ctx.createGain();
    const baseVolume = 0.35;
    const variation = (Math.random() * 0.3 - 0.15); // -0.15 to +0.15
    gainNode.gain.value = baseVolume * (1 + variation);

    source.connect(gainNode);
    gainNode.connect(this._masterGain);
    source.start();
  }

  /**
   * Set master volume (0-1).
   * @param {number} v
   */
  setVolume(v) {
    this._volume = v;
    if (this._masterGain) {
      this._masterGain.gain.value = v;
    }
  }

  /**
   * Enable or disable sound.
   * @param {boolean} b
   */
  setEnabled(b) {
    this._enabled = b;
  }

  /**
   * Synthesize the split-flap click sound buffer (55ms, 2426 samples at 44100Hz).
   * @returns {AudioBuffer}
   */
  _synthesizeFlapSound() {
    const sampleRate = 44100;
    const totalDuration = 0.055; // 55ms
    const frameCount = Math.ceil(sampleRate * totalDuration);
    const buffer = this._ctx.createBuffer(1, frameCount, sampleRate);
    const data = buffer.getChannelData(0);

    // Zero out
    data.fill(0);

    const PI2 = 2 * Math.PI;

    // Component 1: Initial click transient (0-3ms)
    // Damped sine burst at 2.5kHz with harmonics
    const clickEnd = Math.floor(sampleRate * 0.003);
    for (let i = 0; i < clickEnd; i++) {
      const t = i / sampleRate;
      const envelope = Math.exp(-t * 1500);
      const fundamental = Math.sin(PI2 * 2500 * t);
      const harmonic1 = 0.4 * Math.sin(PI2 * 5000 * t);
      const harmonic2 = 0.15 * Math.sin(PI2 * 7500 * t);
      data[i] = (fundamental + harmonic1 + harmonic2) * envelope * 0.7;
    }

    // Component 2: Flutter/whoosh (3-35ms)
    // Filtered noise approximation
    const flutterStart = clickEnd;
    const flutterEnd = Math.min(Math.floor(sampleRate * 0.035), frameCount);
    for (let i = flutterStart; i < flutterEnd; i++) {
      const t = (i - flutterStart) / sampleRate;
      const envelope = Math.exp(-t * 120) * 0.15;
      const noise = Math.sin(PI2 * 1800 * t + 0.7)
                   + 0.6 * Math.sin(PI2 * 2700 * t + 1.3)
                   + 0.3 * Math.sin(PI2 * 3400 * t + 2.1)
                   + 0.4 * Math.sin(PI2 * 1200 * t + 0.4);
      data[i] += noise * envelope;
    }

    // Component 3: Settle click (35-38ms)
    // Softer secondary transient
    const settleStart = Math.floor(sampleRate * 0.035);
    const settleEnd = Math.min(Math.floor(sampleRate * 0.038), frameCount);
    for (let i = settleStart; i < settleEnd; i++) {
      const t = (i - settleStart) / sampleRate;
      const envelope = Math.exp(-t * 2000) * 0.3;
      const fundamental = Math.sin(PI2 * 2000 * t);
      const harmonic = 0.3 * Math.sin(PI2 * 4000 * t);
      data[i] += (fundamental + harmonic) * envelope;
    }

    // Component 4: Resonance tail (38-55ms)
    // Faint damped ring
    const tailStart = Math.floor(sampleRate * 0.038);
    for (let i = tailStart; i < frameCount; i++) {
      const t = (i - tailStart) / sampleRate;
      const envelope = Math.exp(-t * 250) * 0.04;
      const ring = Math.sin(PI2 * 800 * t);
      data[i] += ring * envelope;
    }

    // High-pass filter at ~200Hz to remove DC offset / low rumble
    // First-order high-pass: y[n] = alpha * (y[n-1] + x[n] - x[n-1])
    const rc = 1.0 / (PI2 * 200.0);
    const dt = 1.0 / sampleRate;
    const alpha = rc / (rc + dt);
    let prevIn = 0;
    let prevOut = 0;
    for (let i = 0; i < frameCount; i++) {
      const input = data[i];
      const output = alpha * (prevOut + input - prevIn);
      data[i] = output;
      prevIn = input;
      prevOut = output;
    }

    // Normalize peak to 0.8
    let peak = 0;
    for (let i = 0; i < frameCount; i++) {
      peak = Math.max(peak, Math.abs(data[i]));
    }
    if (peak > 0) {
      const scale = 0.8 / peak;
      for (let i = 0; i < frameCount; i++) {
        data[i] *= scale;
      }
    }

    return buffer;
  }
}
