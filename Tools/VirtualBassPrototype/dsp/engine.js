// Virtual bass prototype engine.
//
// Modes
//  spectral   Per-partial harmonics (proposed, see spectral.js). Each
//             partial of the bass is measured by a short-time Fourier
//             transform and gets only its own harmonics, so several notes
//             or a kick over a bass line never intermodulate; the orders
//             have spread phases, so a rich series does not form a pulse
//             train. Latency about 55 ms (standard) or 110 ms (high
//             resolution, for notes closer than about 25 Hz).
//  analytic   Analytic power series (second round).
//             The bass below the cutoff becomes an analytic signal z, which
//             has only positive frequencies. Harmonic k is z^k divided by a
//             level follower g^(k−1): for a note it is an exact k-th harmonic
//             whose level follows the note; for several notes it holds only
//             sum tones (k·f1, (k−1)·f1 + f2, …, k·f2), never difference
//             tones, so no thump or sub-bass beating is created. |z| ≤ g, so
//             the output can never exceed the bass level. Orders fall off
//             geometrically, so the lowest harmonic the speaker plays carries
//             the note, as in a gently driven amplifier rather than a pulse
//             train. A fixed EQ before the generator sets the harmonic level
//             per note; nothing tracks pitch, so nothing can glide or unlock.
//  apple      Level-normalized nonlinear device, modelled on Apple's patent
//             US10382857B1 (slow hold-type peak follower → normalize →
//             smooth NLD → harmonic band-pass → level match G1/G2).
//  legacyApp  Port of the app's current Classic kernel.
//  legacyLab  Port of VirtualBassLab's FixedHybridBass.
//
// Shared frame for analytic/apple: LR4 crossover at the cutoff, mono bass
// sum, harmonics added to both channels, dry path delayed to line up with
// the harmonics, optional physical bass kept below the cutoff, look-ahead
// safety limiter, optional small-speaker simulation for headphone checks.

import {
  Cascade, Delay, butterworth2, butterworth4, design, groupDelay, linkwitzRiley4, magnitude, onePole, Biquad,
} from './filters.js';
import { QuadratureNetwork } from './hilbert.js';
import { LookaheadLimiter, PeakHoldFollower } from './dynamics.js';
import { equalLoudnessShiftDB } from './loudness.js';
import { LegacyAppClassic, LegacyLabHybrid } from './legacy.js';
import { SpectralHarmonizer } from './spectral.js';

export const MODES = ['spectral', 'analytic', 'apple', 'legacyApp', 'legacyLab'];

export const DEFAULTS = Object.freeze({
  mode: 'spectral',
  orders: 6,            // harmonics per partial, from the lowest one the speaker plays (spectral)
  specSlopeDB: -3,      // level step from each of those orders to the next (spectral)
  dispersion: true,     // spread order phases: flat envelope instead of a pulse train (spectral)
  resolution: 'high',   // 'high' (170 ms window, separates partials ≥ 12 Hz apart) | 'standard' (85 ms, ≥ 25 Hz; faster attack)
  transientFix: true,   // remove harmonics that the analysis window spreads before an onset
  cutoff: 120,          // Hz: lowest frequency the target speaker reproduces well
  floor: 25,            // Hz: lowest fundamental that receives harmonics
  amountDB: 0,          // harmonic level; 0 = same power as the bass note (analytic)
  keepLowDB: -60,       // physical bass kept below the cutoff (−60 = removed)
  slopeDB: -8,          // level step from each harmonic order to the next (analytic)
  followMs: 60,         // level follower release (analytic)
  loudnessMatch: 0,     // 0 = equal power, 1 = ISO 226 equal loudness (analytic)
  loudnessRefDB: 85,    // assumed SPL of the bass fundamental for the match
  nld: 'smooth23',      // 'smooth23' | 'exp2' | 'tanh' (apple)
  drive: 0.6,           // base NLD input gain (apple)
  autoDrive: true,      // dynamically adapt drive with cutoff frequency to prevent cracking at high fc
  excursionProtect: 'tight6', // 'tight6' (36 dB/oct) | 'steep8' (48 dB/oct) | 'tight4' (24 dB/oct)
  holdMs: 60,           // peak follower hold (apple)
  releaseMs: 120,       // peak follower release (apple)
  topMult: 4,           // harmonic band upper edge = topMult × cutoff
  alignMs: -1,          // dry-path delay; −1 = automatic
  inputGainDB: 0,
  normGainDB: 0,        // loudness-normalization trim set by the host (−14 LUFS like the app)
  ceilingDB: -1,
  limiter: true,
  speakerSim: false,    // listen through a simulated small speaker
  simCutoff: 0,         // Hz; 0 = same as cutoff
  simOrder: 4,          // 2 (sealed) or 4 (ported)
  solo: 'none',         // 'none' | 'harmonics' | 'removed'
  bypass: false,
  legacyIntensity: 0.5,
  legacyBassGainDB: 3,
});

const STRUCTURAL = ['mode', 'cutoff', 'floor', 'slopeDB', 'followMs', 'loudnessMatch', 'loudnessRefDB',
  'nld', 'drive', 'autoDrive', 'excursionProtect', 'holdMs', 'releaseMs', 'topMult', 'alignMs', 'legacyIntensity', 'legacyBassGainDB',
  'ceilingDB', 'orders', 'specSlopeDB', 'dispersion', 'resolution', 'transientFix'];

const clamp = (x, lo, hi) => Math.min(hi, Math.max(lo, x));
const dbToGain = (db) => Math.pow(10, db / 20);
const gainToDB = (g) => 20 * Math.log10(Math.max(g, 1e-12));

/** Solves the small dense system A·x = b (Gaussian elimination, partial pivoting). */
function solve(A, b) {
  const n = b.length;
  const M = A.map((row, i) => [...row, b[i]]);
  for (let c = 0; c < n; c++) {
    let p = c;
    for (let r = c + 1; r < n; r++) if (Math.abs(M[r][c]) > Math.abs(M[p][c])) p = r;
    [M[c], M[p]] = [M[p], M[c]];
    const d = M[c][c] || 1e-12;
    for (let r = c + 1; r < n; r++) {
      const f = M[r][c] / d;
      for (let k = c; k <= n; k++) M[r][k] -= f * M[c][k];
    }
  }
  const x = new Array(n).fill(0);
  for (let r = n - 1; r >= 0; r--) {
    let s = M[r][n];
    for (let k = r + 1; k < n; k++) s -= M[r][k] * x[k];
    x[r] = s / (M[r][r] || 1e-12);
  }
  return x;
}

/**
 * Fits low shelves at fixed corners plus a broadband gain to a target
 * response in dB (damped Gauss–Newton on the shelf gains).
 */
function fitShelves(fs, grid, targetDB, corners) {
  const P = corners.length + 1;
  const shelvesDB = (gains, f) => {
    let s = 0;
    for (let i = 0; i < corners.length; i++) {
      if (gains[i] !== 0) s += gainToDB(magnitude([design('lowshelf', corners[i], fs, 1, gains[i])], f, fs));
    }
    return s;
  };
  const gains = corners.map(() => 0);
  let offset = 0;
  for (let it = 0; it < 10; it++) {
    const base = grid.map((f) => shelvesDB(gains, f));
    const r = grid.map((_, j) => targetDB[j] - base[j] - offset);
    const J = grid.map(() => new Float64Array(P));
    for (let i = 0; i < corners.length; i++) {
      const g = gains.slice();
      g[i] += 0.5;
      grid.forEach((f, j) => { J[j][i] = (shelvesDB(g, f) - base[j]) / 0.5; });
    }
    grid.forEach((_, j) => { J[j][P - 1] = 1; });
    const A = Array.from({ length: P }, () => new Array(P).fill(0));
    const b = new Array(P).fill(0);
    for (let j = 0; j < grid.length; j++) {
      for (let a = 0; a < P; a++) {
        b[a] += J[j][a] * r[j];
        for (let c = 0; c < P; c++) A[a][c] += J[j][a] * J[j][c];
      }
    }
    for (let a = 0; a < P; a++) A[a][a] += 0.05;
    const d = solve(A, b);
    for (let i = 0; i < corners.length; i++) gains[i] = clamp(gains[i] + d[i], -12, 24);
    offset += d[P - 1];
  }
  const sections = corners.map((c, i) => design('lowshelf', c, fs, 1, gains[i]));
  const fitDB = (f) => shelvesDB(gains, f) + offset;
  return { sections, gains, offset, fitDB };
}

/** Crossover, mono bass source and dry delay shared by analytic and apple cores. */
class CoreFrame {
  constructor(fs, p) {
    this.fs = fs;
    this.fc = clamp(p.cutoff, 30, 400);
    this.floorHz = clamp(p.floor, 10, this.fc * 0.7);
    // Source band for the harmonics: everything below the cutoff.
    this.lpL = new Cascade(linkwitzRiley4('lowpass', this.fc, fs));
    this.lpR = new Cascade(linkwitzRiley4('lowpass', this.fc, fs));
    // Dry crossover for removing physical bass below cutoff.
    // Scales with excursion protection: tight6 uses 0.85*fc, steep8 uses 0.95*fc, tight4 uses 0.75*fc.
    const protect = p.excursionProtect ?? 'tight6';
    const xoverRatio = protect === 'steep8' ? 0.95 : protect === 'tight6' ? 0.85 : 0.75;
    this.xover = xoverRatio * this.fc;
    const lr = (t) => linkwitzRiley4(t, this.xover, fs);
    this.dryLpL = new Cascade(lr('lowpass')); this.hpL = new Cascade(lr('highpass'));
    this.dryLpR = new Cascade(lr('lowpass')); this.hpR = new Cascade(lr('highpass'));
    this.floorHP = new Cascade(butterworth4('highpass', this.floorHz, fs));
    this.top = clamp(p.topMult * this.fc, this.fc * 2, 2000);
    this.postHP = new Cascade(butterworth4('highpass', this.fc * 0.9, fs));
    this.postLP = new Cascade(butterworth2('lowpass', this.top, fs));
    const maxDelay = Math.ceil(0.2 * fs);
    this.dL = new Delay(maxDelay);
    this.dR = new Delay(maxDelay);
    this.latency = 0;
    this.harmBus = 0;
    this.lowBus = 0;
    // With the physical bass fully kept, the dry path is the untouched
    // input (only delayed). Rebuilding it from the crossover would rotate
    // the bass phase, which undoes a mastering limiter's peak alignment and
    // can raise peaks of loud masters by several dB.
    this.transparent = p.keepLowDB >= 0;
  }

  setAlignment(seconds, p) {
    const s = p.alignMs >= 0 ? p.alignMs * 1e-3 : Math.max(0, seconds);
    this.alignSeconds = s;
    this.latency = Math.round(s * this.fs);
    this.dL.setDelay(this.latency);
    this.dR.setDelay(this.latency);
  }

  /** Splits a stereo frame; leaves the mono bass source in this.bass. */
  split(xl, xr) {
    this.xl = xl;
    this.xr = xr;
    this.lowL = this.lpL.process(xl);
    this.lowR = this.lpR.process(xr);
    if (!this.transparent) {
      this.dryLowL = this.dryLpL.process(xl);
      this.highL = this.hpL.process(xl);
      this.dryLowR = this.dryLpR.process(xr);
      this.highR = this.hpR.process(xr);
    }
    this.bass = this.floorHP.process(0.5 * (this.lowL + this.lowR));
  }

  /** Writes outL/outR from the delayed dry path plus harmonics h. */
  mix(h, ctrl) {
    let dl, dr;
    if (this.transparent) {
      // high = low = 1 gives the input itself; the solo settings still work.
      dl = this.dL.process(ctrl.high * this.xl + (ctrl.low - ctrl.high) * this.lowL);
      dr = this.dR.process(ctrl.high * this.xr + (ctrl.low - ctrl.high) * this.lowR);
    } else {
      dl = this.dL.process(ctrl.high * this.highL + ctrl.low * this.dryLowL);
      dr = this.dR.process(ctrl.high * this.highR + ctrl.low * this.dryLowR);
    }
    const hh = h * ctrl.harm;
    this.outL = dl + hh;
    this.outR = dr + hh;
    this.harmBus = hh;
    this.lowBus = 0.5 * (this.lowL + this.lowR);
  }
}

class AnalyticCore extends CoreFrame {
  constructor(fs, p) {
    super(fs, p);
    const fc = this.fc;
    const floor = this.floorHz;
    // The crossover low band (LR4 at the cutoff) is steepened by a BW4 just
    // above it, so mid-range content leaking through the crossover skirt
    // stays out of the sum tones.
    this.srcLP = new Cascade(butterworth4('lowpass', 1.25 * fc, fs));
    this.quad = new QuadratureNetwork(fs);

    // Configure tight post bandpass filters before model/EQ fitting.
    // Respects excursionProtect (tight6 36 dB/oct default, steep8 48 dB/oct) to eliminate sub-cutoff fluttering.
    const protect = p.excursionProtect ?? 'tight6';
    if (protect === 'steep8') {
      this.postHP = new Cascade([...linkwitzRiley4('highpass', fc, fs), ...linkwitzRiley4('highpass', fc, fs)]);
    } else if (protect === 'tight4') {
      this.postHP = new Cascade(linkwitzRiley4('highpass', fc * 0.95, fs));
    } else {
      this.postHP = new Cascade([...linkwitzRiley4('highpass', fc * 0.95, fs), ...butterworth4('highpass', fc * 0.95, fs).slice(0, 1)]);
    }
    const topHz = Math.min(fc * 2.0, 320);
    this.postLP = new Cascade(butterworth4('lowpass', topHz, fs));

    // Order weights: a geometric series from the 2nd harmonic. Enough
    // orders that the lowest fundamental still has two above the cutoff.
    const rho = dbToGain(clamp(p.slopeDB, -24, 0));
    const K = clamp(Math.ceil((1.25 * fc) / floor) + 2, 3, 12);
    this.K = K;
    this.w = new Float64Array(K + 1);
    let sumW = 0;
    for (let k = 2; k <= K; k++) {
      this.w[k] = Math.pow(rho, k - 2);
      sumW += this.w[k];
    }
    // Crest-factor normalization ensures multiple in-phase harmonics don't artificially blow up peaks by +4.3 dB
    const wScale = 1.0 / Math.max(1.0, sumW * 0.72);
    for (let k = 2; k <= K; k++) this.w[k] *= wScale;

    // Harmonic level per fundamental. The band filter drops the orders the
    // speaker cannot play, so lower notes keep fewer and weaker orders;
    // fixed low shelves before the generator restore their level to the
    // target (the note's own power, moved toward ISO 226 equal loudness by
    // loudnessMatch). The generator scales exactly with its input, so a
    // linear EQ there sets the harmonic level of each note without any
    // gain that moves in time.
    const post = [...this.postHP.coeffs, ...this.postLP.coeffs];
    const match = clamp(p.loudnessMatch, 0, 1);
    const model = (f0) => {
      let pw = 0, fp = 0;
      for (let k = 2; k <= K; k++) {
        const m = this.w[k] * magnitude(post, k * f0, fs);
        pw += m * m;
        fp += m * m * k * f0;
      }
      const shift = match * equalLoudnessShiftDB(Math.max(f0, 20), fp / Math.max(pw, 1e-30), p.loudnessRefDB);
      return { powerDB: 10 * Math.log10(Math.max(pw, 1e-30)), targetDB: shift };
    };
    const lo = 1.2 * floor, hi = 0.75 * fc;
    const grid = [];
    if (hi > lo) for (let i = 0; i < 32; i++) grid.push(lo * Math.pow(hi / lo, i / 31));
    else grid.push(Math.sqrt(floor * fc));
    const want = grid.map((f) => {
      const m = model(f);
      return clamp(m.targetDB - m.powerDB, -9, 4.5);
    });
    const corners = [2, 3, 4].map((k) => (0.8 * fc) / k).filter((c) => c > 0.75 * floor && hi > lo);
    const fit = fitShelves(fs, grid, want, corners);
    this.eq = new Cascade(fit.sections);
    this.outGain = dbToGain(fit.offset);

    // Level follower: instant attack, so |z| ≤ g and |z/g| ≤ 1 always.
    // The release bridges the beating of two notes, so it acts like a slow
    // gain and the generator stays a polynomial (sum tones only); it is
    // short enough that a quiet note after a loud kick is back within
    // about a tenth of a second.
    this.rel = Math.exp(-1 / (clamp(p.followMs, 5, 2000) * 1e-3 * fs));
    this.g = 1e-9;

    // Predicted harmonic level re the note, for the info panel.
    const src = [...this.lpL.coeffs, ...this.srcLP.coeffs, ...this.floorHP.coeffs];
    this.levelModel = [20, 25, 30, 40, 50, 60, 80, 100, 120, 150, 200].filter((f) => f <= fc * 1.1).map((f0) => {
      const m = model(f0);
      const got = m.powerDB + fit.fitDB(f0) + 2 * gainToDB(magnitude(src, f0, fs));
      return [f0, Math.round(got * 10) / 10, Math.round(m.targetDB * 10) / 10];
    });
    this.eqInfo = { corners: corners.map((c) => Math.round(c)), gainsDB: fit.gains.map((g) => Math.round(g * 10) / 10), offsetDB: Math.round(fit.offset * 10) / 10 };

    // Dry delay that lines the harmonic envelope up with the dry signal:
    // the mean, over fundamentals across the processed range, of the
    // source delay at the note plus the band-filter delay at its lowest
    // audible harmonic, minus the dry high band's delay there.
    const chain = [...src, ...this.eq.coeffs];
    let sum = 0;
    const samples = [];
    for (let i = 0; i < 12; i++) {
      const f0 = floor * 1.15 * Math.pow((fc * 0.85) / (floor * 1.15), i / 11);
      const fh = Math.max(2, Math.ceil((0.9 * fc) / f0)) * f0;
      const d = groupDelay(chain, f0, fs) + this.quad.groupDelay(f0, fs)
        + groupDelay(post, fh, fs) - (this.transparent ? 0 : groupDelay(this.hpL.coeffs, fh, fs));
      samples.push([Math.round(f0), Math.round(d * 1e4) / 10]);
      sum += d;
    }
    this.delayModel = { perFundamentalMs: samples };
    this.setAlignment(sum / 12, p);
  }

  process(xl, xr, ctrl) {
    this.split(xl, xr);
    this.quad.process(this.eq.process(this.srcLP.process(this.bass)));
    const zr = this.quad.re, zi = this.quad.im;
    const a = Math.sqrt(zr * zr + zi * zi);
    const g = Math.max(a, this.g * this.rel, 1e-9);
    this.g = g;
    // u = z/g; harmonic k = g·Re(u^k) = Re(z^k)/g^(k−1).
    const ur = zr / g, ui = zi / g;
    const w = this.w;
    let pr = ur, pi = ui, acc = 0;
    for (let k = 2; k <= this.K; k++) {
      const nr = pr * ur - pi * ui;
      pi = pr * ui + pi * ur;
      pr = nr;
      acc += w[k] * pr;
    }
    const rawH = this.postLP.process(this.postHP.process(g * acc)) * this.outGain;
    // Soft saturation prevents harsh clipping and limiter over-compression when amount is high
    const h = Math.tanh(rawH * 0.9) / 0.9;
    this.mix(h, ctrl);
  }
}

/**
 * Order gains for a partial at f (spectral core). Orders start at the
 * lowest one the speaker plays (k·f ≥ 0.95 × cutoff), fall by specSlopeDB
 * per order and stop after `orders` of them. Order positions are
 * continuous in f and both ends are tapered, so nothing jumps while a
 * note glides. Total power through the speaker model equals the partial's
 * power in the source band (an LR4 low-pass at the cutoff above a floor
 * high-pass), moved toward ISO 226 equal loudness by loudnessMatch.
 */
function spectralGains(p, fc, floor, kMax) {
  const M = clamp(Math.round(p.orders), 1, 8);
  const slope = clamp(p.specSlopeDB, -24, 0) / 20;
  const match = clamp(p.loudnessMatch, 0, 1);
  const lo = 0.75 * fc, hi = 0.95 * fc;
  const speaker = (f) => 1 / Math.sqrt(1 + Math.pow(fc / f, 8));
  return (f) => {
    const g = new Float64Array(kMax + 1);
    const src = 1 / (1 + Math.pow(f / fc, 4)) / Math.sqrt(1 + Math.pow(floor / f, 8));
    if (src < 1e-4) return g;
    const nu0 = Math.max(2, hi / f);
    let pw = 0, fp = 0;
    for (let k = 2; k <= kMax; k++) {
      const fk = k * f;
      if (fk > 4000) break;
      const j = k - nu0;
      const rise = fk >= hi ? 1 : fk <= lo ? 0 : 0.5 - 0.5 * Math.cos(Math.PI * Math.log(fk / lo) / Math.log(hi / lo));
      const taper = j <= M - 1 ? 1 : j >= M ? 0 : 0.5 + 0.5 * Math.cos(Math.PI * (j - (M - 1)));
      const v = rise * taper * Math.pow(10, slope * Math.max(0, j));
      g[k] = v;
      const h = v * speaker(fk);
      pw += h * h;
      fp += h * h * fk;
    }
    if (pw <= 1e-12) return g.fill(0);
    const shift = match > 0 ? match * equalLoudnessShiftDB(Math.max(f, 20), fp / pw, p.loudnessRefDB) : 0;
    const s = (src * dbToGain(shift)) / Math.sqrt(pw);
    for (let k = 2; k <= kMax; k++) g[k] *= s;
    return g;
  };
}

class SpectralCore extends CoreFrame {
  constructor(fs, p) {
    super(fs, p);
    const fc = this.fc, floor = this.floorHz;
    this.quad = new QuadratureNetwork(fs);
    const M = clamp(Math.round(p.orders), 1, 8);
    const kMax = clamp(Math.ceil((0.95 * fc) / (0.7 * floor)) + M + 1, 4, 24);
    const psi = new Float64Array(kMax + 1);
    if (p.dispersion) for (let k = 0; k <= kMax; k++) psi[k] = (Math.PI * k * (k - 1)) / Math.max(M, 2);
    const scale = fs > 60000 ? 2 : 1;
    const Na = (p.resolution === 'high' ? 8192 : 4096) * scale;
    const gains = spectralGains(p, fc, floor, kMax);
    this.gen = new SpectralHarmonizer(fs, {
      Na, Ns: 1024 * scale, fLo: 0.7 * floor, fHi: 1.3 * fc, kMax, gains, psi, onsetGate: p.transientFix,
    });
    this.K = kMax;

    // Orders and levels per fundamental, for the info panel.
    const speaker = (f) => 1 / Math.sqrt(1 + Math.pow(fc / f, 8));
    this.recipeInfo = [20, 25, 30, 40, 50, 60, 80, 100, 120, 150].filter((f) => f >= 0.8 * floor && f <= fc * 1.1).map((f0) => {
      const g = gains(f0);
      const orders = [];
      for (let k = 2; k <= kMax; k++) if (g[k] > 1e-3) orders.push([k, Math.round(gainToDB(g[k] * speaker(k * f0)) * 10) / 10]);
      return [f0, orders];
    });

    // Dry delay: generator latency plus the phase network's delay at the
    // note, minus the dry high band's delay at the lowest harmonic. A
    // frame reaches a new note's full level a little after the note
    // starts; a quarter synthesis window centres the harmonic attack on
    // the dry one (measured on tone bursts).
    let sum = 0;
    const samples = [];
    const attack = (0.25 * this.gen.Ns) / fs;
    for (let i = 0; i < 12; i++) {
      const f0 = floor * 1.15 * Math.pow((fc * 0.85) / (floor * 1.15), i / 11);
      const fh = Math.max(2, Math.ceil((0.95 * fc) / f0)) * f0;
      const d = this.gen.latency / fs + this.quad.groupDelay(f0, fs) + attack
        - (this.transparent ? 0 : groupDelay(this.hpL.coeffs, fh, fs));
      samples.push([Math.round(f0), Math.round(d * 1e4) / 10]);
      sum += d;
    }
    this.delayModel = { perFundamentalMs: samples, frameMs: Math.round((Na / fs) * 1000) };
    this.setAlignment(sum / 12, p);
  }

  process(xl, xr, ctrl) {
    this.split(xl, xr);
    this.quad.process(0.5 * (xl + xr));
    this.mix(this.gen.process(this.quad.re, this.quad.im), ctrl);
  }
}

// Critically damped 2nd-order DC blocker (Q=0.5, two cascaded 1st-order real poles; no overshoot/ringing)
class DCBlocker {
  constructor(fs, freq = 20) {
    this.hp1 = new Biquad(design('highpass', freq, fs, 0.5));
    this.hp2 = new Biquad(design('highpass', freq, fs, 0.5));
  }
  process(x) { return this.hp2.process(this.hp1.process(x)); }
  reset() { this.hp1.reset(); this.hp2.reset(); }
}

const NLD = {
  // Ultra-smooth triode saturation: strictly continuous C^inf, zero sharp corners
  smooth23: (u, dc) => {
    const raw = Math.tanh(u) + 0.42 * (u * u);
    return dc.process(raw);
  },
  // Oo & Gan EXP2 with DC removal
  exp2: (u, dc) => {
    const raw = (Math.E - Math.exp(1 - u)) / (Math.E - 1);
    return dc.process(raw);
  },
  // Soft tanh with 2nd harmonic blend
  tanh: (u, dc) => {
    const raw = Math.tanh(1.5 * u) + 0.3 * (u * u);
    return dc.process(raw);
  },
};

class LevelNormalizedCore extends CoreFrame {
  constructor(fs, p) {
    super(fs, p);
    const fc = this.fc;
    // Limit bass input to the NLD to true sub-bass (< 95 Hz) when cutoff is high (120-200 Hz)
    // so vocals/instruments in 100-200 Hz are never pulled into nonlinear distortion
    const srcFc = Math.min(fc, 95);
    this.srcLP = new Cascade(linkwitzRiley4('lowpass', srcFc, fs));

    // Post bandpass highpass with selectable excursion protection slope:
    // steep8: 8th-order LR8 (48 dB/oct) highpass at 1.0 * fc for extreme protection against woofer over-excursion
    // tight6: 6th-order (LR4 + BW2, 36 dB/oct) at 0.95 * fc, optimal balance between bass punch and leakage suppression
    // tight4: 4th-order Linkwitz-Riley (24 dB/oct) at 0.95 * fc for gentle roll-off
    const protect = p.excursionProtect ?? 'tight6';
    if (protect === 'steep8') {
      this.postHP = new Cascade([...linkwitzRiley4('highpass', fc, fs), ...linkwitzRiley4('highpass', fc, fs)]);
    } else if (protect === 'tight4') {
      this.postHP = new Cascade(linkwitzRiley4('highpass', fc * 0.95, fs));
    } else {
      this.postHP = new Cascade([...linkwitzRiley4('highpass', fc * 0.95, fs), ...butterworth4('highpass', fc * 0.95, fs).slice(0, 1)]);
    }
    // Tight 4th-order lowpass tracking 2.0 * fc (capped at 300 Hz) to eliminate inharmonic IMD splatter
    const topHz = Math.min(fc * 2.0, 300);
    this.postLP = new Cascade(butterworth4('lowpass', topHz, fs));
    this.dcBlock = new DCBlocker(fs, 20);

    // Adaptive low-cutoff equal-loudness compensation: compensates for human ear insensitivity
    // when cutoff is low (50-80 Hz). Kept to +3.0 dB max to prevent output clipping / overs.
    const lowCutoffBoost = Math.max(0, Math.min(3.0, (100 - fc) / (100 - 50) * 3.0));
    this.baseGain = dbToGain(lowCutoffBoost) * 1.15;

    const opts = { holdMs: p.holdMs ?? 60, releaseMs: p.releaseMs ?? 120, smoothMs: 15, nearPeak: 0.9, floor: 1e-5 };
    this.f1 = new PeakHoldFollower(fs, opts);
    this.f2 = new PeakHoldFollower(fs, { ...opts, floor: 1e-7 });
    this.nldName = p.nld in NLD ? p.nld : 'smooth23';
    this.nld = NLD[this.nldName];
    // Dynamic drive scaling: scales drive inversely with cutoff frequency (~(60/fc)^1.05).
    // Automatically prevents intermodulation distortion and harsh cracking when fc is high,
    // while keeping rich punch when fc is low.
    const autoDrive = p.autoDrive ?? true;
    const driveScale = autoDrive ? Math.pow(60 / fc, 1.05) : 1.0;
    const baseDrive = p.drive ?? 0.6;
    this.drive = clamp(baseDrive * driveScale, 0.05, 3.0);
    this.effDrive = this.drive;
    const fh = 2 * fc;
    const post = groupDelay([...this.postHP.coeffs, ...this.postLP.coeffs], fh, fs);
    this.g1Delay = new Delay(Math.ceil(0.1 * fs));
    this.g1Delay.setDelay(Math.round(post * fs));
    const f0 = Math.sqrt(this.floorHz * fc);
    const source = groupDelay(this.lpL.coeffs, f0, fs) + groupDelay(this.floorHP.coeffs, f0, fs);
    const dry = this.transparent ? 0 : groupDelay(this.hpL.coeffs, fh, fs);
    this.delayModel = { f0, fh, source, post, dry };
    this.setAlignment(source + post - dry, p);
  }

  process(xl, xr, ctrl) {
    this.split(xl, xr);
    // When fc <= 95 Hz, this.bass is already sharply low-passed at fc; avoid redundant cascading
    const x = this.fc > 95 ? this.srcLP.process(this.bass) : this.bass;
    const g1 = this.f1.process(x);
    // Smooth tanh saturation prevents hard-clipping clicks/cracks when drive is boosted
    const u = Math.tanh((x / g1) * this.drive);
    const y = this.nld(u, this.dcBlock);
    const hb = this.postLP.process(this.postHP.process(y));
    const g1d = this.g1Delay.process(g1);
    const g2 = this.f2.process(hb);
    // Dynamic ratio: allow up to 4.0 so that clean harmonics maintain proper acoustic energy across cutoffs
    const gainRatio = Math.min(4.0, g1d / Math.max(1e-6, g2));
    const h = hb * gainRatio * this.baseGain;
    this.mix(h, ctrl);
  }
}

class LegacyCore {
  constructor(fs, p) {
    this.kernel = p.mode === 'legacyApp'
      ? new LegacyAppClassic(fs, {
        cutoff: p.cutoff, floor: p.floor, intensity: p.legacyIntensity, bassGainDB: p.legacyBassGainDB,
        ceilingDB: p.ceilingDB,
      })
      : new LegacyLabHybrid(fs, { cutoff: p.cutoff, intensity: 1, transient: 1 });
    this.latency = 0;
    this.harmBus = 0;
    this.lowBus = 0;
  }

  process(xl, xr) {
    this.kernel.process(xl, xr);
    this.outL = this.kernel.outL;
    this.outR = this.kernel.outR;
    this.harmBus = this.kernel.harmBus;
  }
}

function makeCore(fs, p) {
  switch (p.mode) {
    case 'analytic': return new AnalyticCore(fs, p);
    case 'apple': return new LevelNormalizedCore(fs, p);
    case 'legacyApp':
    case 'legacyLab': return new LegacyCore(fs, p);
    default: return new SpectralCore(fs, p);
  }
}

class Smoother {
  constructor(fs, value, ms = 30) { this.v = value; this.target = value; this.a = onePole(ms * 1e-3, fs); }
  next() { this.v += (this.target - this.v) * this.a; return this.v; }
}

export class VirtualBassEngine {
  constructor(fs, params = {}) {
    this.fs = fs;
    this.p = { ...DEFAULTS, ...params };
    this.core = makeCore(fs, this.p);
    this.oldCore = null;
    this.fade = 1;
    this.fadeStep = 1 / (0.05 * fs);
    this.limiter = new LookaheadLimiter(fs, { ceilingDB: this.p.limiter ? this.p.ceilingDB : 40 });
    this.byL = new Delay(Math.ceil(0.25 * fs));
    this.byR = new Delay(Math.ceil(0.25 * fs));
    this.byL.setDelay(this.core.latency);
    this.byR.setDelay(this.core.latency);
    this.buildSim();
    const t = this.targets();
    this.s = {
      gin: new Smoother(fs, t.gin), amount: new Smoother(fs, t.amount), low: new Smoother(fs, t.low),
      high: new Smoother(fs, t.high), bypass: new Smoother(fs, t.bypass), sim: new Smoother(fs, t.sim),
    };
    this.ctrl = { harm: 1, low: 0, high: 1 };
    this.resetMeters();
  }

  targets() {
    const p = this.p;
    const keep = p.keepLowDB <= -60 ? 0 : dbToGain(p.keepLowDB);
    const legacy = p.mode === 'legacyApp' || p.mode === 'legacyLab';
    let low = keep, high = 1, amount = legacy ? 1 : dbToGain(p.amountDB);
    if (p.solo === 'harmonics') { low = 0; high = 0; }
    if (p.solo === 'removed') { low = 1; high = 0; amount = 0; }
    return {
      gin: dbToGain(p.inputGainDB + p.normGainDB), amount, low, high,
      bypass: p.bypass ? 1 : 0, sim: p.speakerSim ? 1 : 0,
    };
  }

  buildSim() {
    const fc = this.p.simCutoff > 0 ? this.p.simCutoff : this.p.cutoff;
    const make = () => new Cascade(this.p.simOrder === 2 ? butterworth2('highpass', fc, this.fs)
      : butterworth4('highpass', fc, this.fs));
    if (!this.simL || this.simKey !== `${fc}/${this.p.simOrder}`) {
      const l = make(), r = make();
      if (this.simL && this.simL.sections.length === l.sections.length) {
        this.simL.set(l.coeffs); this.simR.set(r.coeffs);
      } else {
        this.simL = l; this.simR = r;
      }
      this.simKey = `${fc}/${this.p.simOrder}`;
    }
  }

  setParams(partial) {
    const prev = this.p;
    this.p = { ...prev, ...partial };
    const structural = STRUCTURAL.some((k) => partial[k] !== undefined && partial[k] !== prev[k])
      || (prev.keepLowDB >= 0) !== (this.p.keepLowDB >= 0);
    if (structural) {
      // Keep the core that is currently audible as the outgoing one.
      if (!this.oldCore || this.fade >= 0.5) this.oldCore = this.core;
      this.core = makeCore(this.fs, this.p);
      this.fade = 0;
      this.byL.setDelay(this.core.latency);
      this.byR.setDelay(this.core.latency);
    }
    this.limiter.setCeiling(this.p.limiter ? this.p.ceilingDB : 40);
    this.buildSim();
    const t = this.targets();
    for (const k of Object.keys(t)) this.s[k].target = t[k];
  }

  resetMeters() {
    this.m = { n: 0, inPeak: 0, outPeak: 0, minGain: 1, harm2: 0, low2: 0, out2: 0, in2: 0, overs: 0 };
  }

  readMeters() {
    const m = this.m;
    const n = Math.max(1, m.n);
    const db = (v) => (v > 0 ? 10 * Math.log10(v) : -120);
    const out = {
      inPeakDB: 20 * Math.log10(m.inPeak + 1e-12), outPeakDB: 20 * Math.log10(m.outPeak + 1e-12),
      grDB: 20 * Math.log10(m.minGain), harmDB: db(m.harm2 / n), lowDB: db(m.low2 / n),
      inDB: db(m.in2 / n), outDB: db(m.out2 / n), overs: m.overs,
      latencyMs: (this.core.latency + this.limiter.latency) / this.fs * 1000,
    };
    this.resetMeters();
    return out;
  }

  info() {
    const c = this.core;
    return {
      levelModel: c.levelModel || null, eq: c.eqInfo || null, orders: c.K || null,
      recipe: c.recipeInfo || null,
      effDrive: c.effDrive ? Math.round(c.effDrive * 100) / 100 : null,
      delayModel: c.delayModel || null, alignMs: (c.latency / this.fs) * 1000,
    };
  }

  /** Processes planar stereo blocks (outL/outR may alias inL/inR). */
  process(inL, inR, outL, outR, n) {
    const s = this.s;
    const ctrl = this.ctrl;
    const m = this.m;
    for (let i = 0; i < n; i++) {
      const gin = s.gin.next();
      const xl = inL[i] * gin;
      const xr = inR[i] * gin;
      ctrl.harm = s.amount.next();
      ctrl.low = s.low.next();
      ctrl.high = s.high.next();
      this.core.process(xl, xr, ctrl);
      let pl = this.core.outL;
      let pr = this.core.outR;
      let hb = this.core.harmBus;
      if (this.fade < 1) {
        this.oldCore.process(xl, xr, ctrl);
        const f = this.fade;
        pl = pl * f + this.oldCore.outL * (1 - f);
        pr = pr * f + this.oldCore.outR * (1 - f);
        hb = hb * f + this.oldCore.harmBus * (1 - f);
        this.fade = Math.min(1, this.fade + this.fadeStep);
        if (this.fade >= 1) this.oldCore = null;
      }
      const by = s.bypass.next();
      const bl = this.byL.process(xl);
      const br = this.byR.process(xr);
      const ml = pl + (bl - pl) * by;
      const mr = pr + (br - pr) * by;
      if (Math.abs(ml) > 1 || Math.abs(mr) > 1) m.overs++;
      // The limiter always runs so latency never changes; switched off,
      // its ceiling is raised out of reach.
      this.limiter.process(ml, mr);
      let ol = this.limiter.outL;
      let or = this.limiter.outR;
      const sim = s.sim.next();
      const sl = this.simL.process(ol);
      const sr = this.simR.process(or);
      ol += (sl - ol) * sim;
      or += (sr - or) * sim;
      outL[i] = ol;
      outR[i] = or;
      // meters
      const ip = Math.max(Math.abs(inL[i]), Math.abs(inR[i]));
      const op = Math.max(Math.abs(ol), Math.abs(or));
      if (ip > m.inPeak) m.inPeak = ip;
      if (op > m.outPeak) m.outPeak = op;
      if (this.limiter.gain < m.minGain) m.minGain = this.limiter.gain;
      m.harm2 += hb * hb;
      const lb = this.core.lowBus || 0;
      m.low2 += lb * lb;
      m.out2 += 0.5 * (ol * ol + or * or);
      m.in2 += 0.5 * (inL[i] * inL[i] + inR[i] * inR[i]);
      m.n++;
      // Offline analysis taps: harmonic bus (aligned with the dry path at
      // the limiter input) and the limiter gain.
      if (this.capture) {
        const c = this.capture;
        if (c.i < c.harm.length) { c.harm[c.i] = hb; c.gain[c.i] = this.limiter.gain; c.i++; }
      }
    }
  }
}
