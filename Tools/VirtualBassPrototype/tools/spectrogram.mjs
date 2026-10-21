#!/usr/bin/env node
// Spectrogram panels of the input, generated harmonics and output, to see
// what each mode does to real music.
//
//   node tools/spectrogram.mjs <audio file> [--start 60] [--duration 8]
//        [--modes spectral,analytic,apple] [--params '{"cutoff":90}'] [--show harm,out]
//        [--fmax 1200] [--out renders/spec.png] [--sim]
//
// Panels top to bottom: input (mono), then per mode the selected buses.
// Log frequency 20 Hz – fmax, one shared dB scale. Grid rows at 50, 100,
// 200, 500, 1000 Hz; the cutoff is the bright row.

import { resolve } from 'node:path';
import { VirtualBassEngine, DEFAULTS } from '../dsp/engine.js';
import { normalizationGainDB } from '../dsp/lufs.js';
import { decode } from './audio-io.mjs';
import { powerSpectrum } from './spectrum.mjs';
import { colour, writePng } from './png.mjs';

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const start = Number(opt('start', 60));
const duration = Number(opt('duration', 8));
const modes = opt('modes', 'spectral,analytic,apple').split(',');
const extra = JSON.parse(opt('params', '{}'));
const show = opt('show', 'harm').split(',');
const fmax = Number(opt('fmax', 1200));
const out = resolve(opt('out', 'renders/spectrogram.png'));
const N = Number(opt('fft', 8192));
const hop = Number(opt('hop', 480));
const dbLo = Number(opt('dblo', -110));
const dbHi = Number(opt('dbhi', -20));
const sim = args.includes('--sim');
const input = args.find((a) => !a.startsWith('--'));
if (!input) { console.error('usage: node tools/spectrogram.mjs <file> [options]'); process.exit(1); }

const fs = 48000;
const sig = decode(input, fs, { start, duration });
const norm = normalizationGainDB([sig.L, sig.R], fs, -14);
const base = { ...DEFAULTS, ...extra, speakerSim: sim, normGainDB: norm.gainDB };
const g = Math.pow(10, norm.gainDB / 20);
const n = sig.L.length;

function run(params) {
  const e = new VirtualBassEngine(fs, params);
  e.capture = { harm: new Float64Array(n), gain: new Float64Array(n), i: 0 };
  const L = new Float64Array(n), R = new Float64Array(n);
  e.process(sig.L, sig.R, L, R, n);
  const lat = e.core.latency + e.limiter.latency;
  const mono = new Float64Array(n);
  for (let i = 0; i < n; i++) mono[i] = 0.5 * (L[i] + R[i]);
  // Harmonics are captured at the limiter input: shift by the core latency
  // only, outputs by the full latency, so all panels line up with the input.
  return {
    out: mono.subarray(lat), harm: e.capture.harm.subarray(e.core.latency), lat,
    minGainDB: 20 * Math.log10(e.capture.gain.subarray(lat).reduce((a, b) => Math.min(a, b), 1)),
  };
}

const inMono = new Float64Array(n);
for (let i = 0; i < n; i++) inMono[i] = 0.5 * (sig.L[i] + sig.R[i]) * g;

const panels = [['input', inMono]];
for (const m of modes) {
  const r = run({ ...base, mode: m });
  if (show.includes('harm')) panels.push([`${m} harmonics`, r.harm]);
  if (show.includes('out')) panels.push([`${m} output`, r.out]);
  console.log(`${m.padEnd(10)} latency ${(r.lat / fs * 1000).toFixed(1)} ms  limiter ${r.minGainDB.toFixed(1)} dB`);
}

const frames = Math.floor((n - N) / hop);
const W = frames;
const H = 260;
const gap = 3;
const fmin = 20;
const rowF = (y) => fmin * Math.pow(fmax / fmin, 1 - y / (H - 1));
const binHz = fs / N;
const rgb = new Uint8Array(W * (H + gap) * panels.length * 3);
const cutoff = base.cutoff;
const gridRows = [50, 100, 200, 500, 1000].filter((f) => f < fmax).map((f) => Math.round((1 - Math.log(f / fmin) / Math.log(fmax / fmin)) * (H - 1)));
const cutRow = Math.round((1 - Math.log(cutoff / fmin) / Math.log(fmax / fmin)) * (H - 1));
// Power of a full-scale sine with this window, for dBFS.
let wsum = 0;
for (let i = 0; i < N; i++) {
  const t = (2 * Math.PI * i) / (N - 1);
  wsum += 0.35875 - 0.48829 * Math.cos(t) + 0.14128 * Math.cos(2 * t) - 0.01168 * Math.cos(3 * t);
}
const ref = (wsum / 2) ** 2;

panels.forEach(([, x], p) => {
  const y0 = p * (H + gap);
  for (let fr = 0; fr < frames; fr++) {
    const ps = powerSpectrum(x, fr * hop, N);
    for (let y = 0; y < H; y++) {
      const f = rowF(y);
      // Peak of the bins covered by this row (rows are wider than bins at the top).
      const fA = rowF(y + 0.5), fB = rowF(y - 0.5);
      let i0 = Math.floor(fA / binHz), i1 = Math.ceil(fB / binHz);
      if (i1 <= i0) { i0 = Math.floor(f / binHz); i1 = i0 + 1; }
      let v = 0;
      for (let i = i0; i <= i1 && i < ps.length; i++) v = Math.max(v, ps[i]);
      const db = 10 * Math.log10(v / ref + 1e-30);
      let c = colour((db - dbLo) / (dbHi - dbLo));
      if (y === cutRow) c = c.map((k) => Math.max(k, 90)).map((k, j) => (j === 1 ? 200 : k));
      else if (gridRows.includes(y)) c = c.map((k) => Math.max(k, 45));
      const o = ((y0 + y) * W + fr) * 3;
      rgb[o] = c[0]; rgb[o + 1] = c[1]; rgb[o + 2] = c[2];
    }
  }
  for (let y = H; y < H + gap && p < panels.length - 1; y++) {
    for (let fr = 0; fr < W; fr++) {
      const o = ((y0 + y) * W + fr) * 3;
      rgb[o] = 255; rgb[o + 1] = 255; rgb[o + 2] = 255;
    }
  }
});
writePng(out, W, (H + gap) * panels.length - gap, rgb);
console.log(`panels: ${panels.map(([l]) => l).join(' | ')}`);
console.log(`${W}×${(H + gap) * panels.length - gap} px, ${(hop / fs * 1000).toFixed(0)} ms/px, ${fmin}–${fmax} Hz log, ${dbLo}…${dbHi} dBFS → ${out}`);
