// Per-partial harmonic generator.
//
// The bass is analysed with a short-time Fourier transform. Every spectral
// peak is one partial (a bass note, a kick's body, an instrument's low
// harmonic). Each frame measures its frequency f, amplitude a and phase φ,
// and its harmonics are synthesised from those numbers: order k at k·f
// with phase k·φ + ψk. A partial only ever gets its own harmonics; no
// partial multiplies another, so the sum and difference tones that a
// waveshaper or a power series makes whenever several partials sound at
// once cannot occur. The order phases ψk are spread (Schroeder), so a
// rich harmonic series has a flat envelope instead of the pulse train
// that every memoryless nonlinearity produces; the pulse train is the
// buzz heard as soon as more than two orders are strong.
//
// Frames: Hann analysis window Na (frequency resolution), hop H, Hann
// synthesis window Ns = 2H (time resolution of the output). Harmonics are
// synthesised by placing the synthesis window's transform at each exact
// frequency, inverse FFT and overlap-add. Latency (Na + Ns)/2 + 1 samples.
//
// Onsets: the long analysis window sees a note before it starts, so its
// harmonics would begin early. A second analysis with a window that ends
// shortly after the frame's output span measures each partial again
// without that look-ahead; a partial that is much weaker there has not
// started yet, and its harmonics are scaled down by the ratio. Partials
// that were already sounding keep a ratio of 1, so a sustained bass under
// a kick is untouched.
//
// Input is the analytic signal (re, im) of the bass, so partials close to
// DC have no mirror image in the analysis.

import { FFT } from './fft.js';

const TAU = 2 * Math.PI;
const princarg = (p) => p - TAU * Math.round(p / TAU);

function dirichlet(x, n) {
  if (Math.abs(x) < 1e-9) return n;
  return Math.sin(Math.PI * x) / Math.sin((Math.PI * x) / n);
}

/** Transform of a centred periodic Hann window of length n at fractional bin offset x. */
export function hannKernel(x, n) {
  return 0.5 * dirichlet(x, n) + 0.25 * dirichlet(x - 1, n) + 0.25 * dirichlet(x + 1, n);
}

function hann(n) {
  const w = new Float64Array(n);
  for (let i = 0; i < n; i++) w[i] = 0.5 - 0.5 * Math.cos((TAU * i) / n);
  return w;
}

// ±8 bins keeps the truncated Hann sidelobes (18 dB/octave) below −60 dB.
const KERNEL_STEPS = 64;
const KERNEL_HALF = 8;

export class SpectralHarmonizer {
  /**
   * gains(f) → Float64Array g[k] (k = 2…kMax): amplitude of order k re the
   * partial. Tabulated once on a 1/48-octave grid over [fLo, fHi].
   * psi[k]: phase offset of order k.
   */
  constructor(fs, { Na = 8192, Ns = 1024, fLo = 15, fHi = 200, kMax = 16, gains, psi, relDB = -60, onsetGate = true, maxPeaks = 24 }) {
    this.fs = fs;
    this.Na = Na;
    this.Ns = Ns;
    this.H = Ns / 2;
    this.L = Na / 2 + Ns / 2;
    this.latency = this.L + 1;
    this.kMax = kMax;
    this.maxPeaks = maxPeaks;
    this.relGain = Math.pow(10, relDB / 20);
    this.onsetGate = onsetGate;

    this.inRe = new Float64Array(Na);
    this.inIm = new Float64Array(Na);
    this.w = 0;
    this.n = 0;
    this.winA = hann(Na);
    // Onset window: the analysis window up to the end of the frame's output
    // span (Ns/2 after the centre), then a short taper to zero.
    this.winB = new Float64Array(Na);
    const half = Na / 2, tf = Ns / 2, tt = Ns / 2;
    let sa = 0, sb = 0;
    for (let i = 0; i < Na; i++) {
      const t = i - half;
      let v = this.winA[i];
      if (t > tf + tt) v = 0;
      else if (t > tf) v *= 0.5 + 0.5 * Math.cos((Math.PI * (t - tf)) / tt);
      this.winB[i] = v;
      sa += this.winA[i];
      sb += v;
    }
    this.winASum = sa;
    this.gateNorm = sa / sb;
    this.fa = new FFT(Na);
    this.fsyn = new FFT(Ns);
    this.re = new Float64Array(Na);
    this.im = new Float64Array(Na);
    this.re2 = new Float64Array(Na);
    this.im2 = new Float64Array(Na);
    this.yr = new Float64Array(Ns);
    this.yi = new Float64Array(Ns);

    const df = fs / Na;
    this.df = df;
    this.b0 = Math.max(2, Math.floor(fLo / df));
    this.b1 = Math.min(Na / 2 - 2, Math.ceil(fHi / df));
    this.mag = new Float64Array(this.b1 + 2);
    this.phase = new Float64Array(this.b1 + 2);
    this.prevPhase = new Float64Array(this.b1 + 2);
    this.havePrev = false;

    let size = 1;
    while (size < this.L + Ns + this.H + 2) size <<= 1;
    this.mask = size - 1;
    this.acc = new Float64Array(size);

    // Synthesis kernel table (Hann of Ns), ±KERNEL_HALF bins.
    const nk = 2 * KERNEL_HALF * KERNEL_STEPS + 2;
    this.kernel = new Float64Array(nk);
    for (let i = 0; i < nk; i++) this.kernel[i] = hannKernel(i / KERNEL_STEPS - KERNEL_HALF, Ns);

    // Gain table on a log grid.
    this.gLo = fLo;
    this.gSteps = 48;
    const nGrid = Math.ceil(Math.log2(fHi / fLo) * this.gSteps) + 2;
    this.table = [];
    for (let i = 0; i < nGrid; i++) this.table.push(gains(fLo * Math.pow(2, i / this.gSteps)));
    this.g = new Float64Array(kMax + 1);
    this.cosPsi = Float64Array.from(psi, Math.cos);
    this.sinPsi = Float64Array.from(psi, Math.sin);
  }

  gainsAt(f) {
    const x = Math.log2(f / this.gLo) * this.gSteps;
    const g = this.g;
    if (!(x >= 0) || x >= this.table.length - 1) { g.fill(0); return g; }
    const i = Math.floor(x), t = x - i;
    const a = this.table[i], b = this.table[i + 1];
    for (let k = 2; k <= this.kMax; k++) g[k] = a[k] + (b[k] - a[k]) * t;
    return g;
  }

  /** Feeds one analytic sample; returns the harmonic output, latency samples late. */
  process(re, im) {
    this.inRe[this.w] = re;
    this.inIm[this.w] = im;
    this.w = (this.w + 1) & (this.Na - 1);
    this.n++;
    if (this.n % this.H === 0) this.frame();
    const j = (this.n - 1 - this.L) & this.mask;
    const y = this.acc[j];
    this.acc[j] = 0;
    return y;
  }

  frame() {
    const Na = this.Na, Ns = this.Ns, re = this.re, im = this.im, re2 = this.re2, im2 = this.im2;
    const half = Na >> 1;
    for (let i = 0; i < Na; i++) {
      const j = (this.w + i) & (Na - 1);
      const k = (i + half) & (Na - 1);
      const xr = this.inRe[j], xi = this.inIm[j];
      const wa = this.winA[i];
      re[k] = xr * wa;
      im[k] = xi * wa;
      if (this.onsetGate) {
        const wb = this.winB[i];
        re2[k] = xr * wb;
        im2[k] = xi * wb;
      }
    }
    this.fa.forward(re, im);
    if (this.onsetGate) this.fa.forward(re2, im2);

    const { b0, b1, mag, phase } = this;
    let mx = 0;
    for (let b = b0 - 1; b <= b1 + 1; b++) {
      mag[b] = Math.sqrt(re[b] * re[b] + im[b] * im[b]);
      phase[b] = Math.atan2(im[b], re[b]);
      if (b >= b0 && b <= b1 && mag[b] > mx) mx = mag[b];
    }
    const yr = this.yr, yi = this.yi;
    yr.fill(0); yi.fill(0);
    if (mx > 1e-7 * this.winASum) {
      const thr = mx * this.relGain;
      const cand = [];
      for (let b = b0; b <= b1; b++) {
        const m = mag[b];
        if (m >= thr && m >= mag[b - 1] && m > mag[b + 1]) cand.push(b);
      }
      // Drop window sidelobes of a larger neighbour.
      const peaks = cand.filter((b) => !cand.some((b2) => {
        const d = Math.abs(b2 - b);
        if (d === 0 || d > 8 || mag[b2] <= mag[b]) return false;
        return mag[b] < (3.2 / (Math.PI * d * Math.max(d * d - 1, 0.5))) * mag[b2];
      }));
      if (peaks.length > this.maxPeaks) {
        peaks.sort((p, q) => mag[q] - mag[p]);
        peaks.length = this.maxPeaks;
      }
      const H = this.H, fs = this.fs, kMax = this.kMax, kern = this.kernel;
      const toS = Ns / fs;
      for (const b of peaks) {
        // Frequency from the phase advance since the previous frame;
        // parabolic interpolation when that is unavailable or implausible.
        let x = NaN;
        if (this.havePrev) {
          const dev = princarg(phase[b] - this.prevPhase[b] - (TAU * b * H) / Na);
          x = b + (dev * Na) / (TAU * H);
        }
        if (!(Math.abs(x - b) <= 1)) {
          const l = Math.log(mag[b - 1] + 1e-30), c = Math.log(mag[b] + 1e-30), r = Math.log(mag[b + 1] + 1e-30);
          const den = l - 2 * c + r;
          x = b + (den < 0 ? (0.5 * (l - r)) / den : 0);
        }
        let amp = mag[b] / Math.max(hannKernel(b - x, Na), 0.2 * this.winASum);
        if (this.onsetGate) {
          const r = (Math.sqrt(re2[b] * re2[b] + im2[b] * im2[b]) * this.gateNorm) / mag[b];
          if (r < 1) amp *= r;
        }
        const f = x * this.df;
        const ph = phase[b];
        const g = this.gainsAt(f);
        for (let k = 2; k <= kMax; k++) {
          const gk = g[k];
          if (gk <= 1e-5) continue;
          const xs = k * f * toS;
          if (xs > Ns / 2 - KERNEL_HALF - 1) break;
          const A = amp * gk;
          const th = k * ph;
          const c = Math.cos(th), s = Math.sin(th);
          // A·e^{j(kφ + ψk)}
          const ar = A * (c * this.cosPsi[k] - s * this.sinPsi[k]);
          const ai = A * (s * this.cosPsi[k] + c * this.sinPsi[k]);
          const q0 = Math.ceil(xs - KERNEL_HALF), q1 = Math.floor(xs + KERNEL_HALF);
          for (let q = q0; q <= q1; q++) {
            const u = (q - xs + KERNEL_HALF) * KERNEL_STEPS;
            const i0 = Math.floor(u);
            const wv = kern[i0] + (kern[i0 + 1] - kern[i0]) * (u - i0);
            const idx = q & (Ns - 1);
            yr[idx] += wv * ar;
            yi[idx] += wv * ai;
          }
        }
      }
    }
    for (let b = b0 - 1; b <= b1 + 1; b++) this.prevPhase[b] = phase[b];
    this.havePrev = true;

    // Real part of the inverse transform; Hann windows at hop Ns/2 sum to 1.
    this.fsyn.inverse(yr, yi);
    const t0 = this.n - this.L;
    const hs = Ns >> 1;
    for (let i = 0; i < Ns; i++) this.acc[(t0 + i) & this.mask] += yr[(i + hs) & (Ns - 1)];
  }
}
