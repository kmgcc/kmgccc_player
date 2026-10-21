// FFT and spectral measurements for the analysis harness.

export function fft(re, im) {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j], re[i]];
      [im[i], im[j]] = [im[j], im[i]];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = -2 * Math.PI / len;
    const wr = Math.cos(ang), wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1, ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const ar = re[i + k + len / 2] * cr - im[i + k + len / 2] * ci;
        const ai = re[i + k + len / 2] * ci + im[i + k + len / 2] * cr;
        re[i + k + len / 2] = re[i + k] - ar;
        im[i + k + len / 2] = im[i + k] - ai;
        re[i + k] += ar;
        im[i + k] += ai;
        const t = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = t;
      }
    }
  }
}

/** Power spectrum (|X|², Blackman–Harris window) of x[start .. start+N). */
export function powerSpectrum(x, start, N) {
  const re = new Float64Array(N);
  const im = new Float64Array(N);
  for (let i = 0; i < N; i++) {
    const t = (2 * Math.PI * i) / (N - 1);
    const w = 0.35875 - 0.48829 * Math.cos(t) + 0.14128 * Math.cos(2 * t) - 0.01168 * Math.cos(3 * t);
    re[i] = (x[start + i] || 0) * w;
  }
  fft(re, im);
  const p = new Float64Array(N / 2);
  for (let i = 0; i < N / 2; i++) p[i] = re[i] * re[i] + im[i] * im[i];
  return p;
}

export const db10 = (v) => 10 * Math.log10(Math.max(v, 1e-30));
export const db20 = (v) => 20 * Math.log10(Math.max(v, 1e-15));

export function rms(x, start = 0, end = x.length) {
  let s = 0;
  for (let i = start; i < end; i++) s += x[i] * x[i];
  return Math.sqrt(s / Math.max(1, end - start));
}

export function peak(x, start = 0, end = x.length) {
  let m = 0;
  for (let i = start; i < end; i++) m = Math.max(m, Math.abs(x[i]));
  return m;
}

/**
 * Splits spectral power into: harmonic (within ±tol Hz of k·f for any f in
 * fundamentals), below `lowHz`, above `highHz`, and the rest (inharmonic).
 */
export function classify(p, fs, N, fundamentals, { tol = 4, lowHz = 0, highHz = Infinity } = {}) {
  const binHz = fs / N;
  let harmonic = 0, low = 0, high = 0, other = 0, total = 0;
  for (let i = 1; i < p.length; i++) {
    const f = i * binHz;
    total += p[i];
    if (f < lowHz) { low += p[i]; continue; }
    if (f > highHz) { high += p[i]; continue; }
    let isH = false;
    for (const f0 of fundamentals) {
      const k = Math.round(f / f0);
      if (k >= 1 && Math.abs(f - k * f0) <= tol) { isH = true; break; }
    }
    if (isH) harmonic += p[i]; else other += p[i];
  }
  return { harmonic, low, high, other, total };
}

/** Welch long-term power spectrum (N-point frames, 50 % overlap). */
export function welch(x, N = 8192, start = 0) {
  const acc = new Float64Array(N / 2);
  for (let s = start; s + N <= x.length; s += N / 2) {
    const p = powerSpectrum(x, s, N);
    for (let i = 0; i < acc.length; i++) acc[i] += p[i];
  }
  return acc;
}

/** Energy above `f` relative to total, from a Welch spectrum (dB). */
export function energyAbove(x, fs, f, start = 0, N = 8192) {
  const p = welch(x, N, start);
  let hi = 0, all = 0;
  for (let i = 1; i < p.length; i++) {
    all += p[i];
    if (i * fs / N >= f) hi += p[i];
  }
  return db10(hi / Math.max(all, 1e-30));
}

/** Energy below `f` relative to total, from a Welch spectrum (dB). */
export function energyBelow(x, fs, f, start = 0, N = 8192) {
  const p = welch(x, N, start);
  let lo = 0, all = 0;
  for (let i = 1; i < p.length; i++) {
    all += p[i];
    if (i * fs / N < f) lo += p[i];
  }
  return db10(lo / Math.max(all, 1e-30));
}

/** Power within ±tol Hz of frequency f. */
export function bandPower(p, fs, N, f, tol = 4) {
  const binHz = fs / N;
  let s = 0;
  const lo = Math.max(1, Math.floor((f - tol) / binHz));
  const hi = Math.min(p.length - 1, Math.ceil((f + tol) / binHz));
  for (let i = lo; i <= hi; i++) s += p[i];
  return s;
}
