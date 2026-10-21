// ISO 226:2003 equal-loudness contours, used to keep virtual bass from
// sounding louder than the real bass it replaces: a 30 Hz tone needs far
// more SPL than its 150 Hz harmonics for the same loudness.

const F = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800,
  1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500];
const AF = [0.532, 0.506, 0.480, 0.455, 0.432, 0.409, 0.387, 0.367, 0.349, 0.330, 0.315, 0.301,
  0.288, 0.276, 0.267, 0.259, 0.253, 0.250, 0.246, 0.244, 0.243, 0.243, 0.243, 0.242, 0.242,
  0.245, 0.254, 0.271, 0.301];
const LU = [-31.6, -27.2, -23.0, -19.1, -15.9, -13.0, -10.3, -8.1, -6.2, -4.5, -3.1, -2.0, -1.1,
  -0.4, 0.0, 0.3, 0.5, 0.0, -2.7, -4.1, -1.0, 1.7, 2.5, 1.2, -2.1, -7.1, -11.2, -10.7, -3.1];
const TF = [78.5, 68.7, 59.5, 51.1, 44.0, 37.5, 31.5, 26.5, 22.1, 17.9, 14.4, 11.4, 8.6, 6.2, 4.4,
  3.0, 2.2, 2.4, 3.5, 1.7, -1.3, -4.2, -6.0, -5.4, -1.5, 6.0, 12.6, 13.9, 12.3];

function params(f) {
  const x = Math.log(Math.min(Math.max(f, F[0]), F[F.length - 1]));
  let i = 0;
  while (i < F.length - 2 && Math.log(F[i + 1]) < x) i++;
  const t = (x - Math.log(F[i])) / (Math.log(F[i + 1]) - Math.log(F[i]));
  const lerp = (a) => a[i] + (a[i + 1] - a[i]) * t;
  return { af: lerp(AF), lu: lerp(LU), tf: lerp(TF) };
}

/** SPL (dB) of a pure tone at f Hz that has loudness level `phon`. */
export function splForPhon(f, phon) {
  const { af, lu, tf } = params(f);
  const Af = 4.47e-3 * (Math.pow(10, 0.025 * phon) - 1.15)
    + Math.pow(0.4 * Math.pow(10, (tf + lu) / 10 - 9), af);
  return (10 / af) * Math.log10(Af) - lu + 94;
}

/** Loudness level (phon) of a pure tone at f Hz and `spl` dB (inverse by bisection). */
export function phonForSpl(f, spl) {
  let lo = -10, hi = 130;
  for (let i = 0; i < 60; i++) {
    const mid = 0.5 * (lo + hi);
    if (splForPhon(f, mid) < spl) lo = mid; else hi = mid;
  }
  return 0.5 * (lo + hi);
}

/**
 * Level change (dB) that gives a tone moved from f0 to fh the same loudness,
 * for a tone at `spl` dB SPL at f0.
 */
export function equalLoudnessShiftDB(f0, fh, spl) {
  const phon = phonForSpl(f0, spl);
  return splForPhon(fh, phon) - spl;
}
