// Auditory-model measurements for the bass effect.
//
//  roughness   Rasp from fast envelope fluctuation in the auditory filters
//              (after Daniel & Weber 1997, on a gammatone bank). Partials
//              closer than a critical band beat at their difference
//              frequency; at 20–150 Hz that beating is heard as roughness,
//              the "farting" quality of buzzy or intermodulated bass.
//  sacf        Summary autocorrelation of a simple auditory periphery
//              (Meddis & Hewitt 1991). A peak at the lag 1/f0 that is
//              stronger than the one at 1/(2·f0) means the note is heard
//              at its own pitch, not an octave up.
//  imdShare    Share of the generated harmonics' energy that is not at an
//              integer multiple of any strong source partial.

import { Cascade, butterworth4, design } from '../dsp/filters.js';
import { powerSpectrum } from './spectrum.mjs';

const TAU = 2 * Math.PI;
export const erb = (f) => 24.7 * (4.37 * f / 1000 + 1);
const erbNumber = (f) => 21.4 * Math.log10(4.37 * f / 1000 + 1);
const erbFreq = (e) => (Math.pow(10, e / 21.4) - 1) * 1000 / 4.37;
const bark = (f) => 13 * Math.atan(0.00076 * f) + 3.5 * Math.atan((f / 7500) ** 2);
/** Hearing threshold in quiet, dB SPL (Terhardt 1979). */
export const threshold = (f) => {
  const k = f / 1000;
  return 3.64 * k ** -0.8 - 6.5 * Math.exp(-0.6 * (k - 3.3) ** 2) + 1e-3 * k ** 4;
};
const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));

/** Low-pass and keep every `factor`-th sample. */
export function decimate(x, fs, factor) {
  if (factor === 1) return Float64Array.from(x);
  const lp = new Cascade([...butterworth4('lowpass', 0.4 * fs / factor, fs), ...butterworth4('lowpass', 0.4 * fs / factor, fs)]);
  const y = new Float64Array(Math.floor(x.length / factor));
  for (let i = 0, j = 0; i < x.length; i++) {
    const v = lp.process(x[i]);
    if (i % factor === 0 && j < y.length) y[j++] = v;
  }
  return y;
}

/** Centre frequencies spaced `step` ERB apart between lo and hi. */
export function erbSpaced(lo, hi, step) {
  const out = [];
  for (let e = erbNumber(lo); e <= erbNumber(hi) + 1e-9; e += step) out.push(erbFreq(e));
  return out;
}

/**
 * Fourth-order all-pole gammatone at cf, run in baseband. Calls
 * visit(n, re, im) with the complex baseband output, whose magnitude is
 * the envelope (a unit-amplitude sine at cf gives 1).
 */
function gammatone(x, fsg, cf, visit) {
  const a = Math.exp(-TAU * 1.019 * erb(cf) / fsg);
  const b = 1 - a;
  const w = TAU * cf / fsg;
  const dr = Math.cos(w), di = -Math.sin(w);
  let cr = 1, ci = 0;
  let r1 = 0, i1 = 0, r2 = 0, i2 = 0, r3 = 0, i3 = 0, r4 = 0, i4 = 0;
  for (let n = 0; n < x.length; n++) {
    const v = 2 * x[n];
    r1 = a * r1 + b * v * cr; i1 = a * i1 + b * v * ci;
    r2 = a * r2 + b * r1; i2 = a * i2 + b * i1;
    r3 = a * r3 + b * r2; i3 = a * i3 + b * i2;
    r4 = a * r4 + b * r3; i4 = a * i4 + b * i3;
    visit(n, r4, i4, cr, ci);
    const t = cr * dr - ci * di;
    ci = cr * di + ci * dr;
    cr = t;
    if ((n & 1023) === 0) { const m = Math.hypot(cr, ci); cr /= m; ci /= m; }
  }
}

function pearson(a, b, s, e) {
  let ma = 0, mb = 0;
  for (let i = s; i < e; i++) { ma += a[i]; mb += b[i]; }
  ma /= e - s; mb /= e - s;
  let sab = 0, saa = 0, sbb = 0;
  for (let i = s; i < e; i++) {
    const x = a[i] - ma, y = b[i] - mb;
    sab += x * y; saa += x * x; sbb += y * y;
  }
  return saa > 0 && sbb > 0 ? sab / Math.sqrt(saa * sbb) : 0;
}

const ROUGH_DEFAULTS = { lo: 70, hi: 2500, step: 0.5, frame: 0.2, hop: 0.05, spl: 89 };
let roughCal = null;

function roughnessRaw(x, fs, o) {
  const D = Math.max(1, Math.round(fs / 12000));
  const fsg = fs / D;
  const xd = decimate(x, fs, D);
  const E = 8;
  const fse = fsg / E;
  const ne = Math.floor(xd.length / E);
  const cfs = erbSpaced(o.lo, o.hi, o.step);
  const env = [], mod = [];
  for (const cf of cfs) {
    const e = new Float64Array(ne);
    let acc = 0, j = 0, c = 0;
    gammatone(xd, fsg, cf, (n, re, im) => {
      acc += Math.sqrt(re * re + im * im);
      if (++c === E) { if (j < ne) e[j++] = acc / E; acc = 0; c = 0; }
    });
    // Modulation weighting: roughness peaks near 70 Hz for carriers above
    // 1 kHz and at lower rates for lower carriers (Zwicker & Fastl).
    const fb = 70 * Math.sqrt(1 - Math.exp(-cf / 600));
    const bp = new Cascade([design('bandpass', fb, fse, 0.8), design('highpass', 12, fse, Math.SQRT1_2)]);
    const h = new Float64Array(ne);
    for (let k = 0; k < ne; k++) h[k] = bp.process(e[k]);
    env.push(e); mod.push(h);
  }
  const L = Math.round(o.frame * fse), H = Math.round(o.hop * fse);
  const nC = cfs.length;
  const g = cfs.map((f) => 0.6 + 0.4 * Math.min(1, bark(f) / 6));
  const series = [];
  const perChannel = new Float64Array(nC);
  const m = new Float64Array(nC), w = new Float64Array(nC), kk = new Float64Array(nC);
  for (let s = Math.round(0.05 * fse); s + L <= ne; s += H) {
    for (let i = 0; i < nC; i++) {
      let mu = 0, hm = 0;
      for (let k = s; k < s + L; k++) { mu += env[i][k]; hm += mod[i][k]; }
      mu /= L; hm /= L;
      let v = 0;
      for (let k = s; k < s + L; k++) { const d = mod[i][k] - hm; v += d * d; }
      m[i] = mu > 1e-9 ? Math.min(1, Math.SQRT2 * Math.sqrt(v / L) / mu) : 0;
      const spl = 20 * Math.log10(Math.max(mu, 1e-9)) + o.spl;
      w[i] = clamp((spl - threshold(cfs[i])) / 30, 0, 1);
    }
    for (let i = 0; i + 2 < nC; i++) kk[i] = Math.max(0, pearson(mod[i], mod[i + 2], s, s + L));
    let R = 0;
    for (let i = 0; i < nC; i++) {
      const kl = i >= 2 ? kk[i - 2] : (i + 2 < nC ? kk[i] : 1);
      const kr = i + 2 < nC ? kk[i] : kl;
      const r = (g[i] * m[i] * w[i]) ** 2 * kl * kr;
      perChannel[i] += r;
      R += r;
    }
    series.push(R);
  }
  return { series, perChannel: Array.from(perChannel, (v) => v / Math.max(1, series.length)), cfs };
}

/**
 * Roughness over time, scaled so a 1 kHz tone at 60 dB SPL, fully
 * amplitude-modulated at 70 Hz, is 1. `spl` maps dBFS to dB SPL (89: a
 * −14 LUFS track plays at roughly 75 dB SPL).
 */
export function roughness(x, fs, options = {}) {
  const o = { ...ROUGH_DEFAULTS, ...options };
  if (!roughCal || roughCal.key !== `${fs}/${o.lo}/${o.hi}/${o.step}`) {
    const n = Math.round(1.2 * fs);
    const t = new Float64Array(n);
    const a = Math.pow(10, (60 - o.spl) / 20);
    for (let i = 0; i < n; i++) t[i] = a * (1 + Math.cos(TAU * 70 * i / fs)) / 2 * Math.sin(TAU * 1000 * i / fs);
    const r = roughnessRaw(t, fs, { ...o, lo: o.lo, hi: Math.max(o.hi, 1500) });
    const mid = r.series.slice(4, -4);
    roughCal = { key: `${fs}/${o.lo}/${o.hi}/${o.step}`, k: mid.length ? 1 / (mid.reduce((p, q) => p + q, 0) / mid.length) : 1 };
  }
  const r = roughnessRaw(x, fs, o);
  const series = r.series.map((v) => v * roughCal.k);
  const sorted = [...series].sort((p, q) => p - q);
  const q = (p) => sorted.length ? sorted[Math.min(sorted.length - 1, Math.floor(p * sorted.length))] : 0;
  return {
    mean: series.reduce((p, v) => p + v, 0) / Math.max(1, series.length),
    p90: q(0.9),
    series,
    perChannel: r.perChannel.map((v) => v * roughCal.k),
    cfs: r.cfs,
    hop: o.hop,
  };
}

const SACF_DEFAULTS = { lo: 30, hi: 2500, step: 1, frame: 0.08, hop: 0.02, maxLag: 0.042, spl: 89 };

/**
 * Summary autocorrelation per frame: frames[t][lag], lag in samples at
 * rate `rate`. Each channel: gammatone, half-wave rectification with
 * compression, 1 kHz low-pass, normalized autocorrelation; channels are
 * weighted by audibility and level.
 */
export function sacf(x, fs, options = {}) {
  const o = { ...SACF_DEFAULTS, ...options };
  const D = Math.max(1, Math.round(fs / 12000));
  const fsg = fs / D;
  const xd = decimate(x, fs, D);
  const D2 = 3;
  const rate = fsg / D2;
  const n2 = Math.floor(xd.length / D2);
  const L = Math.round(o.frame * rate), H = Math.round(o.hop * rate), T = Math.round(o.maxLag * rate);
  const nF = Math.max(0, Math.floor((n2 - L - T) / H));
  const sum = Array.from({ length: nF }, () => new Float64Array(T + 1));
  const wsum = new Float64Array(nF);
  const cfs = erbSpaced(o.lo, o.hi, o.step);
  for (const cf of cfs) {
    const lp = new Cascade(butterworth4('lowpass', 1000, fsg));
    const y = new Float64Array(n2);
    const env = new Float64Array(n2);
    let j = 0;
    gammatone(xd, fsg, cf, (n, re, im, cr, ci) => {
      // Band-pass signal: Re(w · e^{+jωn}); the oscillator holds e^{−jωn}.
      const s = re * cr + im * ci;
      const v = lp.process(Math.pow(Math.max(s, 0), 0.4));
      if (n % D2 === 0 && j < n2) { y[j] = v; env[j] = Math.sqrt(re * re + im * im); j++; }
    });
    const thr = threshold(cf);
    for (let f = 0; f < nF; f++) {
      const s0 = f * H;
      let mean = 0, emean = 0;
      for (let k = s0; k < s0 + L + T; k++) mean += y[k];
      mean /= L + T;
      for (let k = s0; k < s0 + L; k++) emean += env[k];
      emean /= L;
      const spl = 20 * Math.log10(Math.max(emean, 1e-9)) + o.spl;
      const aud = clamp((spl - thr) / 30, 0, 1);
      if (aud <= 0) continue;
      let e0 = 0;
      for (let k = s0; k < s0 + L; k++) { const d = y[k] - mean; e0 += d * d; }
      if (e0 <= 0) continue;
      const wgt = aud * Math.sqrt(e0 / L);
      const out = sum[f];
      for (let tau = 0; tau <= T; tau++) {
        let r = 0, e1 = 0;
        for (let k = s0; k < s0 + L; k++) {
          const b = y[k + tau] - mean;
          r += (y[k] - mean) * b;
          e1 += b * b;
        }
        out[tau] += wgt * (e1 > 0 ? r / Math.sqrt(e0 * e1) : 0);
      }
      wsum[f] += wgt;
    }
  }
  for (let f = 0; f < nF; f++) if (wsum[f] > 0) for (let t = 0; t <= T; t++) sum[f][t] /= wsum[f];
  return { frames: sum, rate, hop: o.hop, frame: o.frame };
}

/** SACF value at the lag of frequency f (linear interpolation). */
export function sacfAt(frame, rate, f) {
  const t = rate / f;
  const i = Math.floor(t);
  if (i + 1 >= frame.length) return NaN;
  return frame[i] + (frame[i + 1] - frame[i]) * (t - i);
}

/**
 * Share of harmonic-bus energy that does not lie at k·f (k = 2…maxK) of
 * any source partial within relDB of the frame's strongest one. Also
 * returns how much of the spectrum the harmonic mask covers (the share
 * a random spectrum would get); a share well above 1 − coverage means
 * intermodulation.
 */
export function imdShare(src, harm, fs, { N = 16384, hop = 4096, relDB = -25, maxK = 24, srcMax = 200, fLo = 40, fHi = 2000 } = {}) {
  const lp = new Cascade(butterworth4('lowpass', srcMax, fs));
  const s = Float64Array.from(src, (v) => lp.process(v));
  const df = fs / N;
  const bMax = Math.ceil(srcMax * 1.3 / df);
  const j0 = Math.floor(fLo / df), j1 = Math.min(N / 2 - 1, Math.ceil(fHi / df));
  let eh = 0, ei = 0, cover = 0, coverW = 0;
  for (let start = 0; start + N <= Math.min(s.length, harm.length); start += hop) {
    const pi = powerSpectrum(s, start, N);
    const ph = powerSpectrum(harm, start, N);
    let mx = 0;
    for (let b = 1; b <= bMax; b++) mx = Math.max(mx, pi[b]);
    if (mx <= 1e-14) continue;
    const t = mx * Math.pow(10, relDB / 10);
    const A = new Uint8Array(bMax + 4);
    for (let b = 1; b <= bMax; b++) if (pi[b] >= t) for (let d = -2; d <= 2; d++) if (b + d >= 0 && b + d < A.length) A[b + d] = 1;
    const pre = new Int32Array(A.length + 1);
    for (let b = 0; b < A.length; b++) pre[b + 1] = pre[b] + A[b];
    const any = (lo, hi) => {
      const a = Math.max(0, Math.floor(lo)), z = Math.min(A.length - 1, Math.ceil(hi));
      return z >= a && pre[z + 1] - pre[a] > 0;
    };
    let frameE = 0, marked = 0;
    for (let j = j0; j <= j1; j++) {
      let hit = false;
      for (let k = 2; k <= maxK && !hit; k++) {
        const c = j / k;
        if (c > bMax) continue;
        hit = any(c - 4 / k, c + 4 / k);
      }
      if (hit) { eh += ph[j]; marked++; } else ei += ph[j];
      frameE += ph[j];
    }
    cover += frameE * (marked / (j1 - j0 + 1));
    coverW += frameE;
  }
  const tot = eh + ei;
  return { share: tot > 0 ? ei / tot : 0, coverage: coverW > 0 ? cover / coverW : 0 };
}
