// 90° phase-splitting network: two chains of first-order allpasses whose
// outputs stay in quadrature over the bass range. Together they form an
// analytic signal z = re + j·im with only positive frequencies, so
// |z| is the instantaneous amplitude and arg z the instantaneous phase.
//
// Corner frequencies are the app's minimax fit (about 0.55° from
// quadrature over 12–300 Hz). The test harness re-measures the error.

const LAGGING = [1.423, 7.784, 43.842, 209.892, 990.936];
const LEADING = [3.485, 19.237, 96.719, 480.311, 2382.655];

function coefficient(corner, fs) {
  const t = Math.PI * corner / fs;
  return (t - 1) / (t + 1);
}

export class QuadratureNetwork {
  constructor(fs) {
    this.lag = LAGGING.map((c) => coefficient(c, fs));
    this.lead = LEADING.map((c) => coefficient(c, fs));
    const n = LAGGING.length;
    this.lagX = new Float64Array(n);
    this.lagY = new Float64Array(n);
    this.leadX = new Float64Array(n);
    this.leadY = new Float64Array(n);
    this.re = 0;
    this.im = 0;
  }

  /** Feeds one sample; the analytic pair is left in this.re / this.im. */
  process(x) {
    let a = x;
    let b = x;
    const n = this.lag.length;
    for (let i = 0; i < n; i++) {
      // H(z) = (c + z⁻¹) / (1 + c·z⁻¹)
      const c = this.lag[i];
      const y = c * a + this.lagX[i] - c * this.lagY[i];
      this.lagX[i] = a;
      this.lagY[i] = y;
      a = y;
    }
    for (let i = 0; i < n; i++) {
      const c = this.lead[i];
      const y = c * b + this.leadX[i] - c * this.leadY[i];
      this.leadX[i] = b;
      this.leadY[i] = y;
      b = y;
    }
    // The leading branch is the lagging one advanced by 90°:
    // lag = cos θ, lead = cos(θ + 90°) = −sin θ, so z = lag − j·lead.
    this.re = a;
    this.im = -b;
  }

  /** Allpass phase (radians) of the real branch at f, for delay estimates. */
  realBranchPhase(f, fs) {
    const w = 2 * Math.PI * f / fs;
    let phase = 0;
    for (const c of this.lag) {
      // (c + e^{-jw}) / (1 + c e^{-jw})
      const nr = c + Math.cos(w), ni = -Math.sin(w);
      const dr = 1 + c * Math.cos(w), di = -c * Math.sin(w);
      phase += Math.atan2(ni, nr) - Math.atan2(di, dr);
    }
    return phase;
  }

  /** Group delay (s) of the real branch at f. */
  groupDelay(f, fs) {
    const df = Math.max(0.01, f * 1e-4);
    let d = this.realBranchPhase(f + df, fs) - this.realBranchPhase(f - df, fs);
    while (d > Math.PI) d -= 2 * Math.PI;
    while (d < -Math.PI) d += 2 * Math.PI;
    return -d / (2 * Math.PI * 2 * df);
  }

  reset() {
    this.lagX.fill(0); this.lagY.fill(0); this.leadX.fill(0); this.leadY.fill(0);
    this.re = 0; this.im = 0;
  }
}
