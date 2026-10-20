#!/usr/bin/env node
// Objective test suite: runs every mode over synthetic signals (and any
// audio files given on the command line) and reports the artifacts the
// listening complaints map to.
//
//   node tools/analyze.mjs [--cutoff 120] [--modes spectral,analytic,apple,legacyApp,legacyLab] [music files…]

import { VirtualBassEngine, DEFAULTS } from '../dsp/engine.js';
import * as S from '../dsp/signals.js';
import { QuadratureNetwork } from '../dsp/hilbert.js';
import { splForPhon } from '../dsp/loudness.js';
import { Biquad, design } from '../dsp/filters.js';
import { powerSpectrum, classify, bandPower, rms, peak, db10, db20, energyAbove, energyBelow } from './spectrum.mjs';
import { decode } from './audio-io.mjs';
import { normalizationGainDB } from '../dsp/lufs.js';

const fs = 48000;
const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const cutoff = Number(opt('cutoff', 120));
const modes = opt('modes', 'spectral,analytic,apple,legacyApp,legacyLab').split(',');
const extra = JSON.parse(opt('params', '{}'));
const quick = args.includes('--quick');
const files = args.filter((a) => !a.startsWith('--'));

const base = { ...DEFAULTS, cutoff, keepLowDB: -60, limiter: true, ...extra };

function run(params, sig) {
  const e = new VirtualBassEngine(fs, { ...base, ...params });
  const n = sig.L.length;
  const L = new Float64Array(n), R = new Float64Array(n);
  e.capture = { harm: new Float64Array(n), gain: new Float64Array(n), i: 0 };
  const B = 512;
  for (let i = 0; i < n; i += B) {
    const m = Math.min(B, n - i);
    e.process(sig.L.subarray(i, i + m), sig.R.subarray(i, i + m), L.subarray(i, i + m), R.subarray(i, i + m), m);
  }
  return { L, R, H: e.capture.harm, G: e.capture.gain, engine: e, latency: e.core.latency, limLatency: e.limiter.latency };
}

const fmt = (v, d = 1) => (Number.isFinite(v) ? v.toFixed(d) : String(v));
const table = (title, head, rows) => {
  console.log(`\n### ${title}\n`);
  console.log(`| ${head.join(' | ')} |`);
  console.log(`| ${head.map(() => '---').join(' | ')} |`);
  for (const r of rows) console.log(`| ${r.join(' | ')} |`);
};

// ---------------------------------------------------------------- self-checks
function selfChecks() {
  const rows = [];
  // Quadrature error of the phase splitter.
  let worst = 0, worstF = 0;
  for (const f of [15, 20, 25, 30, 40, 50, 63, 80, 100, 125, 160, 200, 250, 300]) {
    const q = new QuadratureNetwork(fs);
    const n = Math.round(fs * 2);
    let dot = 0, ii = 0, qq = 0, cross = 0;
    for (let i = 0; i < n; i++) {
      q.process(Math.sin(2 * Math.PI * f * i / fs));
      if (i > n / 2) { dot += q.re * q.im; ii += q.re * q.re; qq += q.im * q.im; }
    }
    // For exact quadrature the normalized correlation is 0 and powers match.
    const angle = Math.acos(Math.max(-1, Math.min(1, dot / Math.sqrt(ii * qq)))) * 180 / Math.PI;
    const err = Math.abs(angle - 90);
    if (err > worst) { worst = err; worstF = f; }
    cross += 0;
  }
  rows.push(['Phase splitter, worst quadrature error 15–300 Hz', `${fmt(worst, 2)}° at ${worstF} Hz`]);
  // Analytic signal rotates in the positive direction.
  {
    const q = new QuadratureNetwork(fs);
    let prevRe = 0, prevIm = 0, sum = 0;
    for (let i = 0; i < fs; i++) {
      q.process(Math.sin(2 * Math.PI * 50 * i / fs));
      if (i > fs / 2) sum += Math.atan2(prevRe * q.im - prevIm * q.re, prevRe * q.re + prevIm * q.im);
      prevRe = q.re; prevIm = q.im;
    }
    rows.push(['Analytic signal frequency for a 50 Hz input', `${fmt(sum / (fs / 2 - 1) * fs / (2 * Math.PI), 2)} Hz`]);
  }
  // ISO 226 spot values (published 40-phon contour).
  rows.push(['ISO 226 40 phon at 1 kHz / 100 Hz / 50 Hz / 31.5 Hz',
    [1000, 100, 50, 31.5].map((f) => fmt(splForPhon(f, 40), 1)).join(' / ') + ' dB (standard: 40.0 / 64.4 / 77.8 / 88.2)']);
  // Limiter: hot signal never exceeds the ceiling.
  {
    const sig = S.groove(fs, 4, { bassDB: 0, kickDB: 0 });
    const r = run({ mode: 'spectral', amountDB: 12 }, sig);
    rows.push(['Limiter on +12 dB harmonics over a 0 dBFS groove: output peak', `${fmt(db20(Math.max(peak(r.L), peak(r.R))), 2)} dBFS (ceiling −1)`]);
  }
  table('Self-checks', ['check', 'result'], rows);
}

// ---------------------------------------------------------------- per-mode metrics
const N = 65536;

function tonePurity(mode) {
  const out = [];
  for (const f0 of [30, 40, 50, 63, 80, 100]) {
    // A fundamental above the cutoff is played by the speaker; no
    // harmonics are expected, so the ratios would only measure noise.
    if (f0 >= 0.9 * cutoff) { out.push({ f0, inharm: NaN, sub: NaN, level: NaN, crest: NaN }); continue; }
    const sig = S.sine(fs, f0, 3, -12);
    const r = run({ mode }, sig);
    const p = powerSpectrum(r.H, Math.round(1.5 * fs), N);
    const c = classify(p, fs, N, [f0], { tol: 4, lowHz: cutoff * 0.7 });
    const a = Math.round(1.5 * fs);
    const hdb = db20(rms(r.H, a, a + N)) - db20(rms(sig.L, a, a + N));
    // Crest factor of the harmonics as the speaker plays them (above the
    // cutoff). Many equal, in-phase harmonics with no fundamental form a
    // pulse train at the note's rate: below ~50 Hz that is heard as a buzz.
    const hp = [new Biquad(design('highpass', cutoff, fs, 0.5412)), new Biquad(design('highpass', cutoff, fs, 1.3066))];
    const y = Float64Array.from(r.H, (v) => hp[1].process(hp[0].process(v)));
    const crest = db20(peak(y, a, a + N) / Math.max(rms(y, a, a + N), 1e-15));
    out.push({ f0, inharm: db10(c.other / c.total), sub: db10(c.low / c.total), level: hdb, crest });
  }
  return out;
}

/**
 * Two-tone intermodulation: share of harmonic-bus energy that is not a
 * harmonic of either tone (or, with `root`, of the interval's common root).
 * `db2` sets the second tone's level relative to the first.
 */
function imd(mode, f1, f2, { db2 = 0, root = null } = {}) {
  const n = Math.round(3 * fs);
  const a1 = Math.pow(10, -12 / 20) / 2, a2 = a1 * Math.pow(10, db2 / 20);
  const x = new Float64Array(n);
  for (let i = 0; i < n; i++) x[i] = a1 * Math.sin(2 * Math.PI * f1 * i / fs) + a2 * Math.sin(2 * Math.PI * f2 * i / fs + 1);
  S.fadeEdges(x, fs, 0.01);
  const r = run({ mode }, { L: x, R: Float64Array.from(x) });
  const p = powerSpectrum(r.H, Math.round(1.5 * fs), N);
  const c = classify(p, fs, N, root ? [root] : [f1, f2], { tol: root ? 1.2 : 2.5, lowHz: cutoff * 0.7 });
  return db10(c.other / (c.total - c.low));
}

function linearity(mode) {
  const levels = [-40, -30, -20, -12, -6, -3];
  const sig = S.levelSteps(fs, 50, levels, 1.5);
  const r = run({ mode }, sig);
  const each = Math.round(1.5 * fs);
  const pts = [];
  const shapes = [];
  for (let s = 0; s < levels.length; s++) {
    const a = s * each + Math.round(0.6 * fs);
    const lvl = db20(rms(r.H, a, a + Math.round(0.8 * fs)));
    pts.push([levels[s], lvl]);
    const p = powerSpectrum(r.H, a, 32768);
    const tot = [2, 3, 4, 5, 6, 7, 8].map((k) => bandPower(p, fs, 32768, 50 * k, 4));
    const sum = tot.reduce((x, y) => x + y, 0);
    shapes.push(tot.map((v) => db10(v / sum)));
  }
  const mx = pts.reduce((a, b) => a + b[0], 0) / pts.length;
  const my = pts.reduce((a, b) => a + b[1], 0) / pts.length;
  const slope = pts.reduce((a, b) => a + (b[0] - mx) * (b[1] - my), 0) / pts.reduce((a, b) => a + (b[0] - mx) ** 2, 0);
  // timbre spread: largest range across levels of any harmonic that is
  // within 20 dB of the strongest one at the loudest step
  let spread = 0;
  const loud = shapes[shapes.length - 1];
  const top = Math.max(...loud);
  for (let k = 0; k < loud.length; k++) {
    if (loud[k] < top - 20) continue;
    const vals = shapes.slice(1).map((s) => s[k]);
    spread = Math.max(spread, Math.max(...vals) - Math.min(...vals));
  }
  return { slope, spread, quietToLoud: pts[pts.length - 1][1] - pts[1][1] };
}

// Sharp (FFT-based) band energy, so a filter skirt cannot leak the
// intended upper harmonics into the "splatter" figure.
const highPassEnergyRatio = (x, fc, start = 0) => energyAbove(x, fs, fc, Math.round(start));
const lowPassEnergyRatio = (x, fc, start = 0) => energyBelow(x, fs, fc, Math.round(start));

function envelope(x, ms) {
  const a = 1 - Math.exp(-1 / (ms * 1e-3 * fs));
  const y = new Float64Array(x.length);
  let v = 0;
  for (let i = 0; i < x.length; i++) { v += (x[i] * x[i] - v) * a; y[i] = Math.sqrt(v); }
  return y;
}

/**
 * Onset timing on abrupt tone bursts: when the harmonic envelope reaches
 * half its plateau, relative to the input burst plus the dry-path delay.
 * Positive = harmonics late. Also reports the 10→90 % rise time.
 */
function onsetAlignment(mode, f0 = 50) {
  const sig = S.bursts(fs, f0, 4, -10);
  const r = run({ mode }, sig);
  const eH = envelope(r.H, 4);
  const lags = [];
  const rises = [];
  for (let t = 0.2; t < 3.5; t += 0.5) {
    // Search from the burst start as delayed by the dry path.
    const on = Math.round(t * fs) + r.latency;
    const a = on + Math.round(0.12 * fs), b = on + Math.round(0.2 * fs);
    if (b >= eH.length) continue;
    let plateau = 0;
    for (let i = a; i < b; i++) plateau += eH[i];
    plateau /= b - a;
    let i10 = -1, i50 = -1, i90 = -1;
    for (let i = on; i < a; i++) {
      if (i10 < 0 && eH[i] >= 0.1 * plateau) i10 = i;
      if (i50 < 0 && eH[i] >= 0.5 * plateau) i50 = i;
      if (i90 < 0 && eH[i] >= 0.9 * plateau) { i90 = i; break; }
    }
    lags.push((i50 - on) / fs * 1000);
    rises.push((i90 - i10) / fs * 1000);
  }
  const median = (v) => [...v].sort((x, y) => x - y)[v.length >> 1];
  return { lag: median(lags), rise: median(rises), latency: r.latency / fs * 1000 };
}

function groove(mode) {
  const sig = S.groove(fs, 8);
  const r = run({ mode }, sig);
  // Probe: 1 kHz tone level in the output (narrow band-pass, 20 ms RMS).
  const bp1 = new Biquad(design('bandpass', 1000, fs, 25));
  const bp2 = new Biquad(design('bandpass', 1000, fs, 25));
  const y = r.L.map((v) => bp2.process(bp1.process(v)));
  const env = envelope(y, 20);
  let lo = Infinity, hi = 0;
  for (let i = Math.round(1 * fs); i < y.length - 0.5 * fs; i++) { lo = Math.min(lo, env[i]); hi = Math.max(hi, env[i]); }
  let minG = 1, below = 0;
  for (const g of r.G) { minG = Math.min(minG, g); if (g < 0.891) below++; }
  const crest = db20(peak(r.H) / Math.max(rms(r.H), 1e-12));
  return {
    pump: db20(hi / lo), gr: -db20(minG), grTime: 100 * below / r.G.length,
    outPeak: db20(Math.max(peak(r.L), peak(r.R))), crest,
    splatter: highPassEnergyRatio(r.H, 1500, fs),
    harmLevel: db20(rms(r.H)) - db20(rms(sig.L)),
  };
}

function kicksArtifacts(mode) {
  const sig = S.kicks(fs, 4, 0.5);
  const r = run({ mode }, sig);
  return { thump: lowPassEnergyRatio(r.H, cutoff * 0.6, fs * 0.2), splatter: highPassEnergyRatio(r.H, 1500, fs * 0.2) };
}

function burstsArtifacts(mode) {
  const sig = S.bursts(fs, 50, 4);
  const r = run({ mode }, sig);
  return { splatter: highPassEnergyRatio(r.H, 1500, fs * 0.1), thump: lowPassEnergyRatio(r.H, cutoff * 0.6, fs * 0.1) };
}

function postKick(mode) {
  // Harmonics of a quiet 55 Hz note before vs after loud kicks.
  const sig = S.bassUnderKicks(fs, 6);
  const r = run({ mode }, sig);
  const M = 16384;
  const measure = (t) => {
    const p = powerSpectrum(r.H, Math.round(t * fs), M);
    return [165, 220, 275].reduce((a, f) => a + bandPower(p, fs, M, f, 6), 0);
  };
  const before = measure(1.2);
  const after = [2, 3, 4].map((t) => measure(t + 0.45));
  const mean = after.reduce((a, b) => a + b, 0) / after.length;
  return db10(mean / before);
}

function sweepFlatness(mode) {
  const sig = S.sweep(fs, 25, cutoff, 10, -12);
  const r = run({ mode }, sig);
  // 120 ms smoothing: longer than any processed period, so the envelope
  // shows level, not waveform ripple.
  const env = envelope(r.H, 120);
  // largest level change between adjacent 1/6-octave steps
  const k = Math.log(cutoff / 25);
  let worst = 0, prev = null;
  for (let f = 30; f < cutoff * 0.95; f *= Math.pow(2, 1 / 6)) {
    const t = Math.log(f / 25) / k * 10;
    const v = db20(env[Math.round(t * fs)]);
    if (prev !== null) worst = Math.max(worst, Math.abs(v - prev));
    prev = v;
  }
  return worst;
}

function perMode() {
  const results = {};
  for (const mode of modes) {
    const t0 = Date.now();
    const res = { tone: tonePurity(mode) };
    res.imd1 = imd(mode, 41.25, 55, { root: 13.75 });
    res.imd2 = imd(mode, 43, 61);
    res.imd3 = imd(mode, 55, 41.2, { db2: -10 });
    res.imd4 = imd(mode, 43, 61, { db2: -10 });
    res.lin = linearity(mode);
    res.align = onsetAlignment(mode);
    res.groove = groove(mode);
    res.kicks = kicksArtifacts(mode);
    res.bursts = burstsArtifacts(mode);
    res.postKick = postKick(mode);
    res.sweep = sweepFlatness(mode);
    res.ms = Date.now() - t0;
    results[mode] = res;
  }
  const cols = ['metric (ideal)', ...modes];
  const row = (name, f, d = 1) => [name, ...modes.map((m) => fmt(f(results[m]), d))];
  table(`Per-mode metrics (cutoff ${cutoff} Hz, physical bass removed, amount 0 dB)`, cols, [
    row('Inharmonic energy, single tones, worst (dB, lower better)', (r) => Math.max(...r.tone.filter((t) => !Number.isNaN(t.inharm)).map((t) => t.inharm))),
    row('Sub-cutoff energy in harmonics, worst (dB, lower better)', (r) => Math.max(...r.tone.filter((t) => !Number.isNaN(t.sub)).map((t) => t.sub))),
    row('Buzz: crest factor above cutoff, 30–50 Hz tones, worst (dB; sine 3.0)', (r) => Math.max(...r.tone.slice(0, 3).filter((t) => !Number.isNaN(t.crest)).map((t) => t.crest))),
    row('Harmonic level re input, 30 Hz / 100 Hz (dB)', (r) => 0, 1),
    row('IMD, fourth 41.25+55 Hz vs common root 13.75 Hz (dB, lower better)', (r) => r.imd1),
    row('IMD, dissonant 43+61 Hz, equal level (dB, lower better)', (r) => r.imd2),
    row('IMD, 55 Hz + 41.2 Hz at −10 dB (dB, lower better)', (r) => r.imd3),
    row('IMD, 43 Hz + 61 Hz at −10 dB (dB, lower better)', (r) => r.imd4),
    row('Level tracking slope (1.00 = linear)', (r) => r.lin.slope, 2),
    row('Timbre change across levels (dB, lower better)', (r) => r.lin.spread),
    row('Kick: thump below 0.6×cutoff (dB, lower better)', (r) => r.kicks.thump),
    row('Kick: HF splatter >1.5 kHz (dB, lower better)', (r) => r.kicks.splatter),
    row('Bursts: HF splatter >1.5 kHz (dB, lower better)', (r) => r.bursts.splatter),
    row('Bursts: thump below 0.6×cutoff (dB, lower better)', (r) => r.bursts.thump),
    row('Quiet note after loud kick (dB, 0 ideal)', (r) => r.postKick),
    row('Harmonic onset (50 % point) vs dry, 50 Hz burst (ms, ~0 ideal)', (r) => r.align.lag),
    row('Harmonic rise time 10→90 %, 50 Hz burst (ms)', (r) => r.align.rise),
    row('Dry-path delay (ms)', (r) => r.align.latency),
    row('Sweep: worst step between 1/6-oct points (dB)', (r) => r.sweep),
    row('Groove: 1 kHz probe level swing (dB, 0 ideal)', (r) => r.groove.pump, 2),
    row('Groove: limiter max GR (dB)', (r) => r.groove.gr),
    row('Groove: time with GR > 1 dB (%)', (r) => r.groove.grTime),
    row('Groove: harmonic crest factor (dB)', (r) => r.groove.crest),
    row('Groove: harmonic HF splatter >1.5 kHz (dB)', (r) => r.groove.splatter),
    row('Groove: harmonics re input RMS (dB)', (r) => r.groove.harmLevel),
  ].map((r, i) => (i === 3 ? ['Harmonic level re input, 30 / 50 / 80 Hz (dB)', ...modes.map((m) => [0, 2, 4].map((j) => fmt(results[m].tone[j].level)).join(' / '))] : r)));
  table('Single-tone detail: inharmonic / sub-cutoff / crest (dB)', ['f0', ...modes],
    [30, 40, 50, 63, 80, 100].map((f, i) => [`${f} Hz`, ...modes.map((m) => {
      const t = results[m].tone[i];
      return `${fmt(t.inharm)} / ${fmt(t.sub)} / ${fmt(t.crest)}`;
    })]));
  return results;
}

function music() {
  if (!files.length) return;
  const rows = [];
  for (const file of files) {
    const sig = decode(file, fs, { start: 30, duration: quick ? 20 : 45 });
    // Play at the app's normalized level unless --raw is given.
    const norm = args.includes('--raw') ? { gainDB: 0 } : normalizationGainDB([sig.L, sig.R], fs, -14);
    for (const mode of ['unprocessed', ...modes]) {
      const r = mode === 'unprocessed'
        ? run({ mode: 'analytic', bypass: true, normGainDB: norm.gainDB }, sig)
        : run({ mode, normGainDB: norm.gainDB }, sig);
      let minG = 1, below = 0;
      for (const g of r.G) { minG = Math.min(minG, g); if (g < 0.891) below++; }
      rows.push([
        file.split('/').pop().slice(0, 28) + (mode === 'unprocessed' ? ` (${fmt(norm.gainDB)} dB)` : ''), mode,
        fmt(db20(Math.max(peak(sig.L), peak(sig.R)))),
        fmt(db20(Math.max(peak(r.L), peak(r.R)))),
        fmt(-db20(minG)), fmt(100 * below / r.G.length),
        fmt(db20(rms(r.H)) - db20(rms(sig.L))),
        fmt(highPassEnergyRatio(r.H, 1500, fs)),
        fmt(lowPassEnergyRatio(r.H, cutoff * 0.6, fs)),
      ]);
    }
  }
  table('Music excerpts', ['track', 'mode', 'in peak', 'out peak', 'max GR', '% GR>1dB', 'harm re in', 'harm >1.5k', 'harm <0.6fc'], rows);
}

if (!args.includes('--music-only')) {
  selfChecks();
  perMode();
}
music();
