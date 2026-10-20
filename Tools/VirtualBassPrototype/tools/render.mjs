#!/usr/bin/env node
// Offline renders for A/B listening in any player.
//
//   node tools/render.mjs <audio file> [--modes spectral,analytic,apple,legacyApp,legacyLab]
//        [--start 30] [--duration 30] [--params '{"cutoff":150}'] [--sim] [--raw] [--out renders]
//
// Writes <name>.original.wav plus one file per mode. Every file goes through
// the same −14 LUFS normalization (unless --raw), limiter and, with --sim,
// the same small-speaker simulation, so they differ only in the bass effect.

import { basename, extname, join, resolve } from 'node:path';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { VirtualBassEngine, DEFAULTS } from '../dsp/engine.js';
import { normalizationGainDB } from '../dsp/lufs.js';
import { decode, writeWav } from './audio-io.mjs';

const args = process.argv.slice(2);
const opt = (name, def) => {
  const i = args.indexOf(`--${name}`);
  if (i < 0) return def;
  const v = args[i + 1];
  args.splice(i, 2);
  return v;
};
const here = fileURLToPath(new URL('..', import.meta.url));
const outDir = resolve(opt('out', join(here, 'renders')));
const modes = opt('modes', 'spectral,analytic,apple,legacyApp,legacyLab').split(',');
const start = Number(opt('start', 30));
const duration = Number(opt('duration', 30));
const extra = JSON.parse(opt('params', '{}'));
const sim = args.includes('--sim');
const raw = args.includes('--raw');
const input = args.find((a) => !a.startsWith('--'));
if (!input) {
  console.error('usage: node tools/render.mjs <audio file> [--modes …] [--start s] [--duration s] [--params json] [--sim] [--raw] [--out dir]');
  process.exit(1);
}

const fs = 48000;
mkdirSync(outDir, { recursive: true });
const sig = decode(input, fs, { start, duration });
const norm = raw ? { gainDB: 0, lufs: NaN } : normalizationGainDB([sig.L, sig.R], fs, -14);
const stem = basename(input, extname(input)).replace(/[^\p{L}\p{N}._ -]+/gu, '_');
const base = { ...DEFAULTS, ...extra, speakerSim: sim, normGainDB: norm.gainDB };

function render(params) {
  const e = new VirtualBassEngine(fs, params);
  const n = sig.L.length;
  const L = new Float64Array(n), R = new Float64Array(n);
  e.process(sig.L, sig.R, L, R, n);
  // Remove the processing latency so files line up in an editor.
  const lat = e.core.latency + e.limiter.latency;
  return { L: L.subarray(lat), R: R.subarray(lat), meters: e.readMeters() };
}

const jobs = [['original', { ...base, bypass: true }], ...modes.map((m) => [m, { ...base, mode: m }])];
for (const [name, params] of jobs) {
  const r = render(params);
  const file = join(outDir, `${stem}.${name}${sim ? '.speaker' : ''}.wav`);
  writeWav(file, r.L, r.R, fs);
  console.log(`${name.padEnd(10)} peak ${r.meters.outPeakDB.toFixed(1)} dBFS  limiter ${r.meters.grDB.toFixed(1)} dB  → ${file}`);
}
if (!raw) console.log(`normalized ${norm.lufs.toFixed(1)} LUFS → −14 LUFS (${norm.gainDB.toFixed(1)} dB)`);
