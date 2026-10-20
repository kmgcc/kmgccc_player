// ITU-R BS.1770-4 integrated loudness (K-weighting, 400 ms blocks with
// 75 % overlap, absolute −70 LUFS and relative −10 LU gates). Used to play
// tracks at the app's normalized level (−14 LUFS by default), so that A/B
// listening and limiter figures reflect real playback headroom.

function kWeighting(fs) {
  // Pre-filter (high shelf) and RLB high-pass, as parametrized in pyloudnorm.
  const shelf = (() => {
    const G = 3.99984385397, Q = 0.7071752369554193, fc = 1681.9744509555319;
    const A = Math.pow(10, G / 40), w0 = 2 * Math.PI * fc / fs, al = Math.sin(w0) / (2 * Q), c = Math.cos(w0);
    const a0 = (A + 1) - (A - 1) * c + 2 * Math.sqrt(A) * al;
    return {
      b0: A * ((A + 1) + (A - 1) * c + 2 * Math.sqrt(A) * al) / a0,
      b1: -2 * A * ((A - 1) + (A + 1) * c) / a0,
      b2: A * ((A + 1) + (A - 1) * c - 2 * Math.sqrt(A) * al) / a0,
      a1: 2 * ((A - 1) - (A + 1) * c) / a0,
      a2: ((A + 1) - (A - 1) * c - 2 * Math.sqrt(A) * al) / a0,
    };
  })();
  const hp = (() => {
    const Q = 0.5003270373253953, fc = 38.13547087613982;
    const w0 = 2 * Math.PI * fc / fs, al = Math.sin(w0) / (2 * Q), c = Math.cos(w0), a0 = 1 + al;
    return { b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0, a1: -2 * c / a0, a2: (1 - al) / a0 };
  })();
  return [shelf, hp];
}

function filter(x, sections) {
  const y = new Float64Array(x.length);
  y.set(x);
  for (const s of sections) {
    let z1 = 0, z2 = 0;
    for (let i = 0; i < y.length; i++) {
      const v = y[i];
      const o = s.b0 * v + z1;
      z1 = s.b1 * v - s.a1 * o + z2;
      z2 = s.b2 * v - s.a2 * o;
      y[i] = o;
    }
  }
  return y;
}

/** Integrated loudness (LUFS) of planar channels at sample rate fs. */
export function integratedLoudness(channels, fs) {
  const k = kWeighting(fs);
  const weighted = channels.map((c) => filter(c, k));
  const block = Math.round(0.4 * fs);
  const hop = Math.round(0.1 * fs);
  const n = channels[0].length;
  const z = [];
  for (let s = 0; s + block <= n; s += hop) {
    let sum = 0;
    for (const w of weighted) {
      let ms = 0;
      for (let i = s; i < s + block; i++) ms += w[i] * w[i];
      sum += ms / block;
    }
    z.push(sum);
  }
  const lk = (v) => -0.691 + 10 * Math.log10(v);
  const abs = z.filter((v) => lk(v) > -70);
  if (!abs.length) return -Infinity;
  const rel = lk(abs.reduce((a, b) => a + b, 0) / abs.length) - 10;
  const gated = abs.filter((v) => lk(v) > rel);
  return lk(gated.reduce((a, b) => a + b, 0) / gated.length);
}

export function samplePeakDB(channels) {
  let m = 0;
  for (const c of channels) for (let i = 0; i < c.length; i++) m = Math.max(m, Math.abs(c[i]));
  return 20 * Math.log10(m + 1e-12);
}

/**
 * Gain that brings a track to `target` LUFS, never raising its own peak
 * above −1 dBFS (so the unprocessed reference never needs limiting).
 */
export function normalizationGainDB(channels, fs, target = -14) {
  const L = integratedLoudness(channels, fs);
  if (!Number.isFinite(L)) return { gainDB: 0, lufs: L, peakDB: -Infinity };
  const peakDB = samplePeakDB(channels);
  return { gainDB: Math.min(target - L, -1 - peakDB), lufs: L, peakDB };
}
