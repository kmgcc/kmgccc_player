// Synthetic test material, shared by the browser demo and the harness.
// Every generator returns { L, R } Float64Arrays at sample rate fs.

const TAU = 2 * Math.PI;

function rng(seed) {
  let s = seed >>> 0;
  return () => {
    s = (s * 1664525 + 1013904223) >>> 0;
    return s / 4294967296 * 2 - 1;
  };
}

const stereo = (x) => ({ L: x, R: Float64Array.from(x) });
const dbToGain = (db) => Math.pow(10, db / 20);

export function sine(fs, f, seconds, db = -12) {
  const n = Math.round(seconds * fs);
  const x = new Float64Array(n);
  const a = dbToGain(db);
  for (let i = 0; i < n; i++) x[i] = a * Math.sin(TAU * f * i / fs);
  fadeEdges(x, fs, 0.01);
  return stereo(x);
}

export function twoTone(fs, f1, f2, seconds, db = -12) {
  const n = Math.round(seconds * fs);
  const x = new Float64Array(n);
  const a = dbToGain(db) / 2;
  for (let i = 0; i < n; i++) x[i] = a * (Math.sin(TAU * f1 * i / fs) + Math.sin(TAU * f2 * i / fs + 1));
  fadeEdges(x, fs, 0.01);
  return stereo(x);
}

/** Sine at each level for `each` seconds, with short ramps between. */
export function levelSteps(fs, f, levelsDB, each = 1) {
  const n = Math.round(each * fs);
  const x = new Float64Array(n * levelsDB.length);
  let phase = 0;
  const ramp = Math.round(0.02 * fs);
  for (let s = 0; s < levelsDB.length; s++) {
    const a = dbToGain(levelsDB[s]);
    const prev = s > 0 ? dbToGain(levelsDB[s - 1]) : 0;
    for (let i = 0; i < n; i++) {
      const g = i < ramp ? prev + (a - prev) * (i / ramp) : a;
      x[s * n + i] = g * Math.sin(phase);
      phase += TAU * f / fs;
    }
  }
  fadeEdges(x, fs, 0.02);
  return stereo(x);
}

/** Log sine sweep from f1 to f2. */
export function sweep(fs, f1, f2, seconds, db = -12) {
  const n = Math.round(seconds * fs);
  const x = new Float64Array(n);
  const a = dbToGain(db);
  const k = Math.log(f2 / f1);
  for (let i = 0; i < n; i++) {
    const t = i / fs;
    x[i] = a * Math.sin(TAU * f1 * seconds / k * (Math.exp(t / seconds * k) - 1));
  }
  fadeEdges(x, fs, 0.05);
  return stereo(x);
}

/** Electronic kick: pitch drop 160→48 Hz, 280 ms body, small click. */
export function kickSample(fs, db = -6, seed = 7) {
  const n = Math.round(0.6 * fs);
  const x = new Float64Array(n);
  const r = rng(seed);
  let phase = 0;
  const a = dbToGain(db);
  let lp = 0;
  for (let i = 0; i < n; i++) {
    const t = i / fs;
    const f = 48 + 112 * Math.exp(-t / 0.025);
    phase += TAU * f / fs;
    const env = Math.min(1, t / 0.0015) * Math.exp(-t / 0.28);
    lp += 0.25 * (r() - lp);
    const click = (r() - lp) * Math.exp(-t / 0.004) * 0.35;
    x[i] = a * (env * Math.sin(phase) + click);
  }
  return x;
}

function addAt(dst, src, at, gain = 1) {
  for (let i = 0; i < src.length && at + i < dst.length; i++) dst[at + i] += src[i] * gain;
}

/** Kick drums alone every `interval` seconds. */
export function kicks(fs, seconds, interval = 0.5, db = -6) {
  const x = new Float64Array(Math.round(seconds * fs));
  const k = kickSample(fs, db);
  for (let t = 0.1; t < seconds - 0.1; t += interval) addAt(x, k, Math.round(t * fs));
  return stereo(x);
}

/** Bass note with its own decaying harmonics (like a plucked/synth bass). */
function bassNote(fs, f, seconds, db) {
  const n = Math.round(seconds * fs);
  const x = new Float64Array(n);
  const a = dbToGain(db);
  for (let i = 0; i < n; i++) {
    const t = i / fs;
    const env = Math.min(1, t / 0.006) * (0.55 + 0.45 * Math.exp(-t / 0.18)) * Math.min(1, (seconds - t) / 0.03);
    let s = 0;
    for (let k = 1; k <= 6; k++) s += Math.sin(TAU * k * f * t + 0.3 * k) / (k * k);
    x[i] = a * env * s;
  }
  return x;
}

/**
 * A short groove: bass line (E1 A1 D2 G1), kicks on the beat, hi-hat
 * noise, and a steady 1 kHz probe tone at −24 dBFS that should never move
 * in level (anything that does is pumping).
 */
export function groove(fs, seconds = 8, { bassDB = -10, kickDB = -6, probe = true } = {}) {
  const n = Math.round(seconds * fs);
  const L = new Float64Array(n);
  const beat = 0.5;
  const notes = [41.2, 41.2, 55, 55, 73.4, 73.4, 49, 49];
  for (let b = 0, t = 0; t < seconds - beat; b++, t += beat) {
    addAt(L, bassNote(fs, notes[b % notes.length], beat * 0.92, bassDB), Math.round(t * fs));
  }
  const k = kickSample(fs, kickDB);
  for (let t = 0; t < seconds - 0.6; t += beat) addAt(L, k, Math.round(t * fs));
  const r = rng(3);
  let hp = 0;
  for (let t = beat / 2; t < seconds - 0.1; t += beat) {
    const at = Math.round(t * fs);
    for (let i = 0; i < 0.05 * fs && at + i < n; i++) {
      const v = r();
      const h = v - hp; hp = v;
      L[at + i] += 0.05 * h * Math.exp(-i / fs / 0.012);
    }
  }
  const R = Float64Array.from(L);
  if (probe) {
    const a = dbToGain(-24);
    for (let i = 0; i < n; i++) {
      const s = a * Math.sin(TAU * 1000 * i / fs);
      L[i] += s; R[i] += s;
    }
  }
  fadeEdges(L, fs, 0.01);
  fadeEdges(R, fs, 0.01);
  return { L, R };
}

/** Steady quiet bass note with loud kicks every second (tests post-kick ducking). */
export function bassUnderKicks(fs, seconds = 6, { f = 55, bassDB = -26, kickDB = -4 } = {}) {
  const n = Math.round(seconds * fs);
  const x = new Float64Array(n);
  const a = dbToGain(bassDB);
  for (let i = 0; i < n; i++) x[i] = a * Math.sin(TAU * f * i / fs);
  const k = kickSample(fs, kickDB);
  for (let t = 2; t < seconds - 0.7; t += 1) addAt(x, k, Math.round(t * fs));
  fadeEdges(x, fs, 0.02);
  return stereo(x);
}

/** Abrupt bass tone bursts that start at a random phase (onset pops). */
export function bursts(fs, f = 50, seconds = 4, db = -10) {
  const n = Math.round(seconds * fs);
  const x = new Float64Array(n);
  const a = dbToGain(db);
  for (let t = 0.2; t < seconds - 0.4; t += 0.5) {
    const at = Math.round(t * fs);
    const len = Math.round(0.25 * fs);
    const ph = (t * 7.3) % TAU;
    for (let i = 0; i < len; i++) x[at + i] += a * Math.sin(TAU * f * i / fs + ph);
  }
  return stereo(x);
}

export function fadeEdges(x, fs, seconds) {
  const n = Math.min(Math.round(seconds * fs), x.length >> 1);
  for (let i = 0; i < n; i++) {
    const g = 0.5 - 0.5 * Math.cos(Math.PI * i / n);
    x[i] *= g;
    x[x.length - 1 - i] *= g;
  }
}

export const LIBRARY = {
  groove: { label: '律动测试片段 (低音贝斯、底鼓、踩镲、1 kHz 探测音)', make: (fs) => groove(fs, 16) },
  kicks: { label: '纯底鼓冲击测试 (Kick drums)', make: (fs) => kicks(fs, 8) },
  sweep: { label: '对数正弦扫频 20–200 Hz', make: (fs) => sweep(fs, 20, 200, 12) },
  steps: { label: '50 Hz 电平阶梯测试 (−40 → −3 dBFS)', make: (fs) => levelSteps(fs, 50, [-40, -30, -20, -12, -6, -3], 1.5) },
  twoTone: { label: '双音混合 41 + 55 Hz (互调测试)', make: (fs) => twoTone(fs, 41.2, 55, 8) },
  bassUnderKicks: { label: '强底鼓下的弱低音 (防避让衰减测试)', make: (fs) => bassUnderKicks(fs, 10) },
  bursts: { label: '低频突发脉冲 (起音爆音测试)', make: (fs) => bursts(fs, 50, 8) },
};
