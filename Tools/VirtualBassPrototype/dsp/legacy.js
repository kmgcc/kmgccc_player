// Faithful ports of the bass algorithms that exist today, for A/B listening
// and for measuring their artifacts with the same harness.
//
//  - LegacyAppClassic: kmgccc_player/Services/Audio/DSP/DSPClassicBassKernel.swift
//    (process path; the analytic network described in its doc comment is not
//    used by that code — it runs a |x| + tanh waveshaper on the raw band).
//  - LegacyLabHybrid: Tools/VirtualBassLab/.../FixedHybridBass.swift
//    (the previous "fixed" attempt).
// Neither has latency, so the bypass path needs no delay for them.

import { Biquad, design, SQRT1_2, BW4_Q } from './filters.js';

/** DSPBassPeakControl.mix: per-sample soft clip of the added signal. */
function peakControlMix(original, enhanced, ceiling) {
  if (ceiling === null) return enhanced;
  const added = enhanced - original;
  const direction = added < 0 ? -1 : 1;
  const available = Math.max(0, ceiling - direction * original);
  const knee = available * 0.75;
  const amount = Math.abs(added);
  if (amount <= knee) return enhanced;
  const span = available - knee;
  if (span <= 0) return original;
  return original + direction * (knee + span * Math.tanh((amount - knee) / span));
}

const PROFILE_SPEAKERS = { round: [0.65, 0.45], tight: [0.4, 0.65], intensityScale: 1.2 };
const PROFILE_HEADPHONES = { round: [0.75, 0.40], tight: [0.45, 0.65], intensityScale: 1.0 };

export class LegacyAppClassic {
  constructor(fs, {
    cutoff = 60, floor = 25, intensity = 0.5, bassGainDB = 3, character = 'round',
    profile = 'speakers', tighten = false, ceilingDB = -1, outputTrimDB = 0,
  } = {}) {
    const prof = profile === 'headphones' ? PROFILE_HEADPHONES : PROFILE_SPEAKERS;
    const sourceCutoff = Math.min(cutoff, 250);
    const wetCorner = Math.max(30, sourceCutoff * 0.8);
    const wetTop = Math.min(800, Math.max(280, 4 * sourceCutoff));
    const floorHz = Math.max(20, floor);
    const mk = () => ({
      floorHP: new Biquad(design('highpass', floorHz, fs, SQRT1_2)),
      lp1: new Biquad(design('lowpass', sourceCutoff, fs, BW4_Q[0])),
      lp2: new Biquad(design('lowpass', sourceCutoff, fs, BW4_Q[1])),
      wetHP1: new Biquad(design('highpass', wetCorner, fs, BW4_Q[0])),
      wetHP2: new Biquad(design('highpass', wetCorner, fs, BW4_Q[1])),
      wetLP1: new Biquad(design('lowpass', wetTop, fs, BW4_Q[0])),
      wetLP2: new Biquad(design('lowpass', wetTop, fs, BW4_Q[1])),
      dryHP: new Biquad(design('highpass', cutoff * 0.8, fs, SQRT1_2)),
      shelf: new Biquad(design('lowshelf', cutoff, fs, 1, bassGainDB)),
      dcIn: 0, dcOut: 0,
    });
    this.ch = [mk(), mk()];
    const weights = character === 'tight' ? prof.tight : prof.round;
    this.w2 = weights[0];
    this.w3 = weights[1];
    this.wetGain = floorHz < sourceCutoff ? intensity * prof.intensityScale : 0;
    this.tighten = tighten;
    this.outputGain = Math.pow(10, outputTrimDB / 20);
    this.peakCeiling = ceilingDB === null ? null : Math.pow(10, ceilingDB / 20) / this.outputGain;
    this.dcAlpha = Math.exp(-2 * Math.PI * 5 / fs);
    this.dryDucking = tighten ? 0.68 : 1 / (1 + 0.45 * Math.min(this.wetGain, 2));
    this.shelfActive = Math.abs(bassGainDB) > 1e-12;
    this.latency = 0;
    this.harm = 0;
    this.removed = 0;
  }

  processChannel(s, sample) {
    const band = s.lp2.process(s.lp1.process(s.floorHP.process(sample)));
    const eps = 0.005;
    const even = Math.sqrt(band * band + eps * eps) - eps;
    const odd = Math.tanh(1.6 * band);
    const raw = this.w2 * even + this.w3 * odd;
    const dcBlocked = raw - s.dcIn + this.dcAlpha * s.dcOut;
    s.dcIn = raw;
    s.dcOut = dcBlocked;
    const hp = s.wetHP2.process(s.wetHP1.process(dcBlocked));
    const wet = s.wetLP2.process(s.wetLP1.process(hp));
    const scaledWet = 0.32 * Math.tanh(wet * this.wetGain / 0.32);
    const dry = this.tighten ? s.dryHP.process(sample) : sample;
    const dryWithShelf = this.shelfActive ? s.shelf.process(dry) : dry;
    const enhanced = dryWithShelf * this.dryDucking + scaledWet;
    this.harm = scaledWet;
    return peakControlMix(dry, enhanced, this.peakCeiling) * this.outputGain;
  }

  process(xl, xr) {
    this.outL = this.processChannel(this.ch[0], xl);
    const hl = this.harm;
    this.outR = this.processChannel(this.ch[1], xr);
    this.harmBus = 0.5 * (hl + this.harm);
  }
}

export class LegacyLabHybrid {
  constructor(fs, {
    cutoff = 100, intensity = 1, transient = 1, bassGainDB = 0, tighten = false, character = 0.7,
  } = {}) {
    const sourceCutoff = Math.min(cutoff, 130);
    const postHpFreq = Math.max(55, sourceCutoff * 0.85);
    const mk = () => ({
      preLp1: new Biquad(design('lowpass', sourceCutoff, fs, SQRT1_2)),
      preLp2: new Biquad(design('lowpass', sourceCutoff, fs, SQRT1_2)),
      postHp1: new Biquad(design('highpass', postHpFreq, fs, SQRT1_2)),
      postHp2: new Biquad(design('highpass', postHpFreq, fs, SQRT1_2)),
      postLp: new Biquad(design('lowpass', 380, fs, SQRT1_2)),
      dryHP: new Biquad(design('highpass', cutoff * 0.85, fs, SQRT1_2)),
      shelf: new Biquad(design('lowshelf', cutoff, fs, 1, bassGainDB)),
      fast: 0, slow: 0, dcIn: 0, dcOut: 0,
    });
    this.ch = [mk(), mk()];
    this.wetGain = 1.25 * intensity;
    this.transientGain = Math.max(0, transient);
    this.tighten = tighten;
    this.round = Math.max(0, Math.min(1, character));
    this.dcAlpha = Math.exp(-2 * Math.PI * 15 / fs);
    const a = (t) => 1 - Math.exp(-1 / (t * fs));
    this.fastA = a(0.005); this.fastR = a(0.080); this.slowA = a(0.040); this.slowR = a(0.300);
    this.shelfActive = Math.abs(bassGainDB) > 1e-12;
    this.latency = 0;
  }

  processChannel(s, sample) {
    const band = s.preLp2.process(s.preLp1.process(sample));
    const ab = Math.abs(band);
    s.fast += (ab > s.fast ? this.fastA : this.fastR) * (ab - s.fast);
    s.slow += (ab > s.slow ? this.slowA : this.slowR) * (ab - s.slow);
    const delta = Math.max(0, s.fast - s.slow);
    const tr = Math.min(1, 2.5 * (delta / (s.slow + 0.010)));
    const driven = band * 2.2;
    const dk = 0.08;
    const h2 = (Math.sqrt(driven * driven + dk * dk) - dk) * 2.2;
    const h3 = Math.tanh(1.5 * driven);
    const baseW3 = 0.55 - 0.35 * this.round;
    const w3 = Math.min(0.75, baseW3 + 0.30 * tr * Math.min(1.6, this.transientGain));
    const raw = (1 - w3) * h2 + w3 * h3;
    const dcBlocked = raw - s.dcIn + this.dcAlpha * s.dcOut;
    s.dcIn = raw;
    s.dcOut = dcBlocked;
    const hp = s.postHp2.process(s.postHp1.process(dcBlocked));
    const wf = s.postLp.process(hp);
    const drive = 1 + 0.35 * tr * Math.min(1.6, this.transientGain);
    const wet = 0.45 * Math.tanh(wf * this.wetGain * drive / 0.45);
    let dry = sample;
    if (this.tighten) dry = s.dryHP.process(dry);
    if (this.shelfActive) dry = s.shelf.process(dry);
    const duck = this.tighten ? 0.75 : 1 / (1 + 0.28 * Math.min(this.wetGain, 2.5));
    const combined = dry * duck + wet;
    // DSPSafeSaturation.safeLimit(combined, ceiling 0.98, knee 0.85)
    const ax = Math.abs(combined);
    let limited = combined;
    if (ax > 0.85) {
      const span = 0.98 - 0.85;
      const c = 0.85 + span * Math.tanh((ax - 0.85) / span);
      limited = combined < 0 ? -c : c;
    }
    this.harm = wet;
    return limited;
  }

  process(xl, xr) {
    this.outL = this.processChannel(this.ch[0], xl);
    const hl = this.harm;
    this.outR = this.processChannel(this.ch[1], xr);
    this.harmBus = 0.5 * (hl + this.harm);
  }
}
