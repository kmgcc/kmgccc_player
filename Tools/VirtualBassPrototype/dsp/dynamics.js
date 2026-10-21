// Level followers and the output safety limiter.

import { onePole } from './filters.js';

/**
 * Peak follower after Apple's US10382857B1 (FIGS. 5B/6): instant attack,
 * a hold stage that restarts while the input stays near the peak, an
 * exponential release, then a smoothing stage. The smoothing only acts on
 * falling values, so the estimate never drops below the instantaneous
 * peak and a signal divided by it stays within ±1.
 */
export class PeakHoldFollower {
  constructor(fs, { holdMs = 500, releaseMs = 500, smoothMs = 20, nearPeak = 0.9, floor = 1e-4 } = {}) {
    this.fs = fs;
    this.configure({ holdMs, releaseMs, smoothMs, nearPeak, floor });
    this.peak = 0;
    this.out = 0;
    this.holdLeft = 0;
  }

  configure({ holdMs, releaseMs, smoothMs, nearPeak, floor }) {
    if (holdMs !== undefined) this.holdSamples = Math.round(holdMs * 1e-3 * this.fs);
    if (releaseMs !== undefined) this.release = Math.exp(-1 / (Math.max(1, releaseMs) * 1e-3 * this.fs));
    if (smoothMs !== undefined) this.smooth = onePole(smoothMs * 1e-3, this.fs);
    if (nearPeak !== undefined) this.nearPeak = nearPeak;
    if (floor !== undefined) this.floor = floor;
  }

  process(x) {
    const a = Math.abs(x);
    if (a >= this.peak) {
      this.peak = a;
      this.holdLeft = this.holdSamples;
    } else if (this.holdLeft > 0) {
      this.holdLeft--;
      if (a >= this.nearPeak * this.peak) this.holdLeft = this.holdSamples;
    } else {
      this.peak = Math.max(a, this.peak * this.release);
    }
    if (this.peak >= this.out) this.out = this.peak;
    else this.out += (this.peak - this.out) * this.smooth;
    return Math.max(this.out, this.floor);
  }

  reset() { this.peak = 0; this.out = 0; this.holdLeft = 0; }
}

/** Mean-square envelope with separate attack and release. */
export class PowerEnvelope {
  constructor(fs, attackMs, releaseMs) {
    this.att = onePole(attackMs * 1e-3, fs);
    this.rel = onePole(releaseMs * 1e-3, fs);
    this.v = 0;
  }

  process(x) {
    const p = x * x;
    this.v += (p - this.v) * (p > this.v ? this.att : this.rel);
    return this.v;
  }

  reset() { this.v = 0; }
}

/**
 * Stereo-linked look-ahead peak limiter.
 *  1. required gain g = min(1, ceiling / |peak|) per input sample;
 *  2. sliding minimum over the look-ahead window;
 *  3. release smoothing (instant down, exponential up);
 *  4. moving average over the window, which guarantees the gain has fully
 *     reached each peak's requirement when that peak leaves the delay line.
 * Output gain therefore has no steps (no clicks) and no overshoot.
 */
export class LookaheadLimiter {
  constructor(fs, { lookaheadMs = 5, releaseMs = 120, ceilingDB = -1 } = {}) {
    this.fs = fs;
    this.L = Math.max(1, Math.round(lookaheadMs * 1e-3 * fs));
    this.release = onePole(releaseMs * 1e-3, fs);
    this.setCeiling(ceilingDB);
    const n = this.L + 1;
    this.dl = new Float64Array(n);
    this.dr = new Float64Array(n);
    this.dpos = 0;
    // monotonic deque for the sliding minimum
    this.qv = new Float64Array(n + 1);
    this.qi = new Int32Array(n + 1);
    this.qh = 0; this.qt = 0; this.qn = n + 1;
    this.t = 0;
    this.r = 1;
    this.avgBuf = new Float64Array(this.L);
    this.avgPos = 0;
    this.avgSum = this.L;
    this.avgBuf.fill(1);
    this.gain = 1;
  }

  setCeiling(ceilingDB) { this.ceiling = Math.pow(10, ceilingDB / 20); }

  /** Processes one stereo frame; results in this.l / this.r_ (and this.gain). */
  process(l, r) {
    const peak = Math.max(Math.abs(l), Math.abs(r));
    const need = peak > this.ceiling ? this.ceiling / peak : 1;
    const t = this.t++;
    // push to deque (keep increasing values from head to tail)
    while (this.qt !== this.qh) {
      const last = (this.qt - 1 + this.qn) % this.qn;
      if (this.qv[last] >= need) this.qt = last; else break;
    }
    this.qv[this.qt] = need; this.qi[this.qt] = t;
    this.qt = (this.qt + 1) % this.qn;
    while (this.qi[this.qh] <= t - this.L - 1) this.qh = (this.qh + 1) % this.qn;
    const windowMin = this.qv[this.qh];
    // release smoothing
    if (windowMin < this.r) this.r = windowMin;
    else this.r += (windowMin - this.r) * this.release;
    // moving average across the look-ahead
    this.avgSum += this.r - this.avgBuf[this.avgPos];
    this.avgBuf[this.avgPos] = this.r;
    this.avgPos = this.avgPos + 1 === this.L ? 0 : this.avgPos + 1;
    const g = Math.min(1, this.avgSum / this.L);
    // delay line
    const n = this.L + 1;
    this.dl[this.dpos] = l; this.dr[this.dpos] = r;
    let rp = this.dpos - this.L; if (rp < 0) rp += n;
    this.outL = this.dl[rp] * g;
    this.outR = this.dr[rp] * g;
    this.dpos = this.dpos + 1 === n ? 0 : this.dpos + 1;
    this.gain = g;
  }

  get latency() { return this.L; }

  reset() {
    this.dl.fill(0); this.dr.fill(0); this.dpos = 0;
    this.qh = 0; this.qt = 0; this.t = 0; this.r = 1;
    this.avgBuf.fill(1); this.avgSum = this.L; this.avgPos = 0; this.gain = 1;
  }
}
