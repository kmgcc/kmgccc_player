// Biquad filters (transposed direct form II) and RBJ-cookbook designs.
// Plain per-sample code with explicit state so it ports line-for-line to Swift or C.

export const SQRT1_2 = Math.SQRT1_2;
/** Section Qs of a fourth-order Butterworth response. */
export const BW4_Q = [0.5411961001461970, 1.3065629648763766];

export const IDENTITY = Object.freeze({ b0: 1, b1: 0, b2: 0, a1: 0, a2: 0 });

export class Biquad {
  constructor(c = IDENTITY) {
    this.b0 = 1; this.b1 = 0; this.b2 = 0; this.a1 = 0; this.a2 = 0;
    this.z1 = 0; this.z2 = 0;
    this.set(c);
  }

  set(c) {
    this.b0 = c.b0; this.b1 = c.b1; this.b2 = c.b2; this.a1 = c.a1; this.a2 = c.a2;
    this.c = c;
  }

  process(x) {
    const y = this.b0 * x + this.z1;
    this.z1 = this.b1 * x - this.a1 * y + this.z2;
    this.z2 = this.b2 * x - this.a2 * y;
    return y;
  }

  reset() { this.z1 = 0; this.z2 = 0; }
}

/** A chain of biquads processed in series. */
export class Cascade {
  constructor(coeffs = []) {
    this.sections = coeffs.map((c) => new Biquad(c));
  }

  set(coeffs) {
    if (coeffs.length !== this.sections.length) {
      this.sections = coeffs.map((c) => new Biquad(c));
      return;
    }
    for (let i = 0; i < coeffs.length; i++) this.sections[i].set(coeffs[i]);
  }

  process(x) {
    const s = this.sections;
    for (let i = 0; i < s.length; i++) x = s[i].process(x);
    return x;
  }

  get coeffs() { return this.sections.map((s) => s.c); }

  reset() { for (const s of this.sections) s.reset(); }
}

function normalize(b0, b1, b2, a0, a1, a2) {
  return { b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0 };
}

/**
 * RBJ cookbook section.
 * type: 'lowpass' | 'highpass' | 'bandpass' (0 dB peak) | 'allpass' | 'lowshelf' | 'highshelf' | 'peak'
 * For shelves, q is the shelf slope S (1 = steepest without overshoot).
 */
export function design(type, f, fs, q = SQRT1_2, gainDB = 0) {
  const freq = Math.min(Math.max(f, 1), fs * 0.45);
  const w = 2 * Math.PI * freq / fs;
  const cw = Math.cos(w);
  const sw = Math.sin(w);
  const A = Math.pow(10, gainDB / 40);
  switch (type) {
    case 'lowpass': {
      const al = sw / (2 * q);
      return normalize((1 - cw) / 2, 1 - cw, (1 - cw) / 2, 1 + al, -2 * cw, 1 - al);
    }
    case 'highpass': {
      const al = sw / (2 * q);
      return normalize((1 + cw) / 2, -(1 + cw), (1 + cw) / 2, 1 + al, -2 * cw, 1 - al);
    }
    case 'bandpass': {
      const al = sw / (2 * q);
      return normalize(al, 0, -al, 1 + al, -2 * cw, 1 - al);
    }
    case 'allpass': {
      const al = sw / (2 * q);
      return normalize(1 - al, -2 * cw, 1 + al, 1 + al, -2 * cw, 1 - al);
    }
    case 'peak': {
      const al = sw / (2 * q);
      return normalize(1 + al * A, -2 * cw, 1 - al * A, 1 + al / A, -2 * cw, 1 - al / A);
    }
    case 'lowshelf':
    case 'highshelf': {
      if (Math.abs(gainDB) < 1e-9) return IDENTITY;
      const al = sw / 2 * Math.sqrt((A + 1 / A) * (1 / q - 1) + 2);
      const beta = 2 * Math.sqrt(A) * al;
      if (type === 'lowshelf') {
        return normalize(
          A * ((A + 1) - (A - 1) * cw + beta),
          2 * A * ((A - 1) - (A + 1) * cw),
          A * ((A + 1) - (A - 1) * cw - beta),
          (A + 1) + (A - 1) * cw + beta,
          -2 * ((A - 1) + (A + 1) * cw),
          (A + 1) + (A - 1) * cw - beta,
        );
      }
      return normalize(
        A * ((A + 1) + (A - 1) * cw + beta),
        -2 * A * ((A - 1) + (A + 1) * cw),
        A * ((A + 1) + (A - 1) * cw - beta),
        (A + 1) - (A - 1) * cw + beta,
        2 * ((A - 1) - (A + 1) * cw),
        (A + 1) - (A - 1) * cw - beta,
      );
    }
    default:
      throw new Error(`unknown filter type ${type}`);
  }
}

/** Fourth-order Butterworth low/high-pass as two sections. */
export function butterworth4(type, f, fs) {
  return BW4_Q.map((q) => design(type, f, fs, q));
}

/** Second-order Butterworth as one section. */
export function butterworth2(type, f, fs) {
  return [design(type, f, fs, SQRT1_2)];
}

/**
 * Fourth-order Linkwitz–Riley: a squared second-order Butterworth.
 * LP and HP outputs are in phase at every frequency and sum to an allpass.
 */
export function linkwitzRiley4(type, f, fs) {
  const c = design(type, f, fs, SQRT1_2);
  return [c, c];
}

/** Second-order allpass with exactly the phase of an LR4 crossover at f. */
export function linkwitzRileyAllpass(f, fs) {
  return [design('allpass', f, fs, SQRT1_2)];
}

/** Eighth-order Linkwitz–Riley: a squared fourth-order Butterworth. */
export function linkwitzRiley8(type, f, fs) {
  const c = butterworth4(type, f, fs);
  return [...c, ...c];
}

/** Fourth-order allpass with exactly the phase of an LR8 crossover at f. */
export function linkwitzRiley8Allpass(f, fs) {
  return BW4_Q.map((q) => design('allpass', f, fs, q));
}

/** Complex response of a section list at frequency f. Returns [re, im]. */
export function response(coeffs, f, fs) {
  const w = 2 * Math.PI * f / fs;
  const c1 = Math.cos(w), s1 = -Math.sin(w);
  const c2 = Math.cos(2 * w), s2 = -Math.sin(2 * w);
  let re = 1, im = 0;
  for (const c of coeffs) {
    const nr = c.b0 + c.b1 * c1 + c.b2 * c2;
    const ni = c.b1 * s1 + c.b2 * s2;
    const dr = 1 + c.a1 * c1 + c.a2 * c2;
    const di = c.a1 * s1 + c.a2 * s2;
    const den = dr * dr + di * di;
    const hr = (nr * dr + ni * di) / den;
    const hi = (ni * dr - nr * di) / den;
    const r = re * hr - im * hi;
    im = re * hi + im * hr;
    re = r;
  }
  return [re, im];
}

export function magnitude(coeffs, f, fs) {
  const [re, im] = response(coeffs, f, fs);
  return Math.hypot(re, im);
}

/** Group delay in seconds at f, from the unwrapped phase derivative. */
export function groupDelay(coeffs, f, fs) {
  const df = Math.max(0.01, f * 1e-4);
  const [r1, i1] = response(coeffs, f - df, fs);
  const [r2, i2] = response(coeffs, f + df, fs);
  let dphi = Math.atan2(i2, r2) - Math.atan2(i1, r1);
  while (dphi > Math.PI) dphi -= 2 * Math.PI;
  while (dphi < -Math.PI) dphi += 2 * Math.PI;
  return -dphi / (2 * Math.PI * 2 * df);
}

/** One-pole smoothing coefficient for a time constant in seconds. */
export function onePole(seconds, fs) {
  if (seconds <= 0) return 1;
  return 1 - Math.exp(-1 / (seconds * fs));
}

/** Integer-sample delay line. */
export class Delay {
  constructor(maxSamples) {
    this.buf = new Float64Array(Math.max(1, maxSamples + 1));
    this.pos = 0;
    this.d = 0;
  }

  setDelay(samples) {
    this.d = Math.max(0, Math.min(this.buf.length - 1, Math.round(samples)));
  }

  process(x) {
    const n = this.buf.length;
    this.buf[this.pos] = x;
    let r = this.pos - this.d;
    if (r < 0) r += n;
    const y = this.buf[r];
    this.pos = this.pos + 1 === n ? 0 : this.pos + 1;
    return y;
  }

  reset() { this.buf.fill(0); this.pos = 0; }
}
