# Virtual bass: diagnosis, research and the prototype algorithm

Status: prototype, third round. Nothing in the app has been changed. The
first prototype (phase-locked synthesis) failed in listening; section 3
explains why, and section 4 describes its replacement. The second round
improved things, but its two generators still broke up at higher settings
and at cutoffs above 60 Hz; section 5 explains why, and describes the
per-partial generator that is now the default. Everything here is
validated by measurement only. The next step is listening in the demo.

## Summary

- **The app's Classic kernel does not run the algorithm its doc comment
  describes.** The comment describes a level-normalized analytic harmonic
  series. The `process` path instead runs a static waveshaper,
  `sqrt(x² + ε²) − ε` plus `tanh(1.6·x)`, directly on the unnormalized bass
  band. The phase-splitting network, envelope and attack/release fields are
  computed and never used. Most of the reported symptoms follow from that.
- **Both current kernels make the whole track about 2 dB quieter** (whole-band
  `dryDucking`), then soft-clip every sample against the ceiling.
- **The first prototype also buzzed and added little bass**, for four
  reasons found in round two: a pulse-train timbre, a pitch tracker that
  glides on every note, harmonics set 10–20 dB too quiet by an
  equal-loudness rule, and a crossover that removed bass the speaker could
  still play.
- **The replacement, the analytic power series**, raises the analytic
  signal of the bass to integer powers, normalized by a level follower. It
  needs no pitch tracking and cannot overshoot the bass level. It creates
  sum tones only, so it makes no thump or sub-bass beating. Its timbre is
  dominated by the lowest harmonic the speaker plays, like the
  Apple-style mode that sounded closest in listening, but without that
  mode's attack clicks and post-kick dropouts.
- **Round three: the remaining breakup is the generator, not its
  settings.** A waveshaper or power series applied to a band that holds
  several partials makes intermodulation products, and its harmonics are
  all in cosine phase, which unresolved harmonics hear as a pulse train
  (buzz). Every parameter that adds orders (drive, upper-limit multiple,
  order slope) and every higher cutoff (more partials in the band) makes
  both worse. Settings only trade a clean single octave-up harmonic, heard
  as ordinary low-mids, against a rich series that buzzes.
- **The per-partial generator (`spectral`)** measures every partial of the
  bass in short-time spectra and synthesizes each partial's own harmonics,
  with spread phases. No partial multiplies another, so there is no
  intermodulation by construction, and the spread phases keep the envelope
  flat. On five tracks its harmonics are 1.6–4.5× smoother (auditory
  roughness) than the music's own content in the same band at the same
  level, and barely change with cutoff: at 150 Hz they are about 3–5×
  smoother than the Apple-style mode and about 10× smoother than the
  analytic mode.
- Remaining limits: about 60 ms of latency (105 ms in high resolution),
  partials closer than about 25 Hz merge in standard resolution, and
  virtual bass in general does not equal real bass: the best published
  system scores 47/100 against the full-range reference.

## 1. What goes wrong today

Code read: `DSPClassicBassKernel.swift`, `DSPHybridBassKernel.swift`,
`DSPBassPeakControl` (in `DSPEffectKernel.swift`), and
`Tools/VirtualBassLab/…/FixedClassicBass.swift` and `FixedHybridBass.swift`.
The Classic kernel and the Lab "FixedHybrid" are ported exactly in
`dsp/legacy.js` and measured with the same harness. The STFT Hybrid kernel is
assessed from the code only.

| Symptom | Cause | Evidence (harness) |
| --- | --- | --- |
| Thumping | `sqrt(x²+ε²)−ε` is a full-wave rectifier. Its DC follows the bass envelope, so every note or kick onset becomes a low-frequency pulse. A 5 Hz DC blocker and an HPF at 0.8×cutoff cannot remove 20–80 Hz pulses. `tanh(1.6x)` also passes the fundamental itself. | For a 40 Hz tone, 79 % of the "harmonic" output lies below the cutoff. Kick thump: −10 dB (app), −15 dB (lab), vs −65 dB new. |
| Popping, farting | The waveshaper works on the raw level, so harmonic content explodes with loudness. A waveshaper on several notes (kick + bass) produces inharmonic sum/difference products. Then `0.32·tanh(wet/0.32)`, `DSPBassPeakControl.mix` and the Lab's `safeLimit` waveshape the sum again on loud passages. | Timbre change between −30 and −3 dBFS: 48.8 dB (app), 13.7 dB (lab), 0.0 dB (new). |
| Volume pumping, track sounds weaker | `dryDucking = 1/(1+0.45·wetGain)` multiplies the **entire** dry signal. The Lab Hybrid also modulates harmonic gain with a 5 ms/80 ms envelope ratio. | Everything above 300 Hz drops 2.1 dB (app) and 2.6 dB (lab). |
| Little or no extra bass on small speakers | Speaker profile cutoff 60 Hz: the harmonics start at 48 Hz, so the 2nd harmonics of 30–60 Hz fall at 60–120 Hz, still below what laptop and phone speakers reproduce (about 150–250 Hz). The +3 dB shelf boosts exactly the range the speaker cannot play and only eats headroom. | |
| Phase cancellation | Dry path: 2nd-order HPF at 0.8×cutoff, then a shelf, plus per-channel harmonics of arbitrary phase. STFT Hybrid: each frame writes one partial with its own phase estimate, and eight frames overlap (hop N/8). Phase errors between frames cancel. | |
| Clipping | No headroom budget. Shelf boost and added harmonics are "protected" by per-sample soft clipping (distortion) rather than a look-ahead limiter. | |

STFT Hybrid kernel (from the code): the transient branch reuses the same
rectifier and tanh waveshaper. The tonal branch tracks one f0 per frame, so
it cannot handle two notes. It gates partials on and off with a coherence
test (audible blips). It boosts "existing harmonics" by up to 12 dB in a
region that also holds vocals and guitars, so other instruments get
modulated. Its output passes through `tanh` again. Latency is about 220 ms.

## 2. What the research says

- **Missing fundamental.** Pitch is inferred from two or more consecutive
  harmonics. A lone 2nd harmonic is heard an octave up. The harmonics must
  fall where the speaker actually plays (Moliner et al. 2020).
- **Resolved and unresolved harmonics.** Below about 50 Hz, neighbouring
  harmonics are closer together than the ear's filters at 100–300 Hz are
  wide, so they are not heard separately. The ear follows their combined
  envelope instead. Several equal harmonics in phase, without the
  fundamental, make that envelope a pulse train at the note's rate, which
  is heard as a buzz.
- **Loudness.** Equal-loudness contours are steep and compressed in the
  bass. A 40 Hz tone at 85 dB SPL is only about 43 phon; harmonics at
  100–200 Hz reach that loudness 15–20 dB lower. Matching that strictly
  makes the effect nearly inaudible in a mix.
- **Nonlinear devices.** Their problems are level dependence and
  intermodulation (Oo, Gan & Hawksford, JAES 2011). The better ones are
  smooth and asymmetric (EXP2, ATSR). Piecewise-linear devices
  intermodulate strongly (Apple's patent says the same).
- **Phase vocoder and hybrids.** These give better tonal quality but smear
  transients. In a listening test, the best hybrid scored 47/100 vs 29/100
  for a nonlinear device; the full-range reference scored about 99.
- **Apple, US10382857B1** ("Automatic level control for psychoacoustic bass
  enhancement"): sum to mono and split with a Linkwitz–Riley crossover.
  A peak follower (instant attack, 0.5 s hold, 0.5 s release, smoothing)
  normalizes the bass before a continuous nonlinearity (tanh or
  exponential). The harmonics are band-passed (about 100–400 Hz), and a
  second follower scales them to the bass level (G1/G2). Allpass
  compensation avoids nulls; a low-end blend gain and a harmonics
  compressor follow. Marketing material for HomePod and Studio Display adds
  real-time woofer modelling and dynamic bass EQ, so a large share of that
  sound is physical bass, managed carefully.
- **Others.** Bankstown (Asahi Linux, MacBook speakers): a static tanh
  saturator on a 20–200 Hz band. Dirac (US12254863): amplitude-proportional
  ABS/SIGN harmonics, multiband to limit intermodulation. MaxxBass
  (Waves): envelope-proportional harmonics from a nonlinearity.

## 3. Round two: why the first prototype failed by ear

Listening report: the phase-locked mode and both legacy modes sounded like
farting or popping and added no bass. The Apple-style mode was the closest,
but raising its drive made it worse. Spectrograms
(`tools/spectrogram.mjs`) and new measurements explain all four points.

1. **Pulse-train timbre.** Phase-locked synthesis gave four or five
   harmonics of nearly equal level (6 dB/oct), all in cosine phase, with no
   fundamental. For notes below about 50 Hz that is a pulse train at the
   note rate: a buzz. Apple's EXP2 at drive 1 is almost a pure 2nd harmonic
   (3rd at −16 dB below it), so it sounds clean but an octave up. Raising
   drive clips the normalized input into a square wave, which brings back
   many strong harmonics, and with them the buzz. Its output is
   level-normalized, so drive never made it louder.
2. **Pitch tracker glides.** The loop relocked on every 808 note and kick.
   Each harmonic multiplies the phase error by its order, so every note
   began with a visible downward glide of all harmonics, and lock losses
   between notes smeared into broadband noise.
3. **Too quiet.** Loudness match 0.6 at 85 dB SPL put the harmonics 10–20 dB
   below the bass they replaced. The user's preferred Apple-style setting
   (+3.5 dB on its 0.707 output scale) is about equal power.
4. **Crossover at the cutoff.** Removing the real bass with an LR4 at the
   speaker cutoff, then rolling off again in the speaker, removed upper bass
   the speaker could play. Through the simulated 90 Hz speaker, the
   Apple-style output at +3.5 dB had 0.0–1.5 dB *less* energy in 80–300 Hz
   than the unprocessed track.

The Apple-style mode also clicks on attacks. Its follower has an instant
attack, so in the first cycle of a note the normalized input sits at ±1,
which the nonlinearity turns into a square edge (treble splatter −63 dB vs
−108 dB for the new mode, visible as thin vertical lines in spectrograms).
Its 0.5 s hold leaves a quiet note after a loud kick 29 dB short of
harmonics for about a second.

## 4. The prototype algorithm: analytic power series

```
L,R ─┬─ LR4 @ 0.7×cutoff ── high ───────────────────────────────┐
     │          └─ low ── ×keep (physical bass) ────────────────┤ delay D ─┐
     ├─ LR4 low-pass @ cutoff, BW4 @ 1.25×cutoff, BW4 floor HPF            │
     │    └─ low shelves (fixed per setting) ─ 90° network ─ z             │
     │         g = peak follower of |z| (instant attack, 60 ms release)    │
     │         u = z / g                     (|u| ≤ 1 always)              │
     │         h = g · Σ_k ρ^(k−2) · Re(u^k),  k = 2…K                     │
     │         HPF 0.9×cutoff, LPF topMult×cutoff, × amount ───────────────┤
     └── (keep = 0 dB: dry path is the untouched input, only delayed)      │
                                                         look-ahead limiter ┴─ out
```

Why each part, and the failure it avoids:

1. **Powers of the analytic signal.** For one note z = a·e^{jθ}, so
   g·Re(u^k) = (a^k / g^(k−1))·cos kθ is an exact k-th harmonic. For two
   notes, z^k expands binomially into k·f1, (k−1)·f1 + f2, …, k·f2: sum
   tones only, all within the k-th harmonic region. A real polynomial
   (x², x³, rectifiers) also makes difference tones, which is where thumps
   and sub-bass beating come from. Taking the phase alone (the first
   prototype) spreads every note's phase error into unlimited sidebands
   instead.
2. **Level follower.** Instant attack keeps |u| ≤ 1, so the output can never
   exceed g·Σρ^(k−2), and there is no clipping to protect against. The
   release bridges beating between notes, so the follower behaves like a
   slow gain and the generator stays a polynomial. At 60 ms, a quiet note
   after a loud kick is down 5 dB, against 29 dB in the Apple-style mode.
   Output level follows input exactly (slope 1.00) with constant timbre.
3. **Geometric orders, −8 dB per order.** The lowest harmonic the speaker
   plays carries the note, the next adds some pitch definition, and higher
   ones fade. That gives the sound of a gently driven amplifier rather than
   a pulse train. `slopeDB` trades cleanliness (−16, close to the
   Apple-style sound) against richness (−3).
4. **Level per note by a fixed EQ.** The harmonic band-pass removes the
   orders below the cutoff, so lower notes keep fewer and weaker orders. The
   generator is homogeneous (output scales exactly with input), so a linear
   low-shelf EQ before it sets each note's harmonic level. The shelves are
   fitted when the parameters change, to the target: harmonics with the same
   power as the note (`loudnessMatch` 0), optionally moved toward ISO 226.
   Nothing moves in time, so nothing pumps; the demo prints the fitted
   level for each fundamental.
5. **Dry crossover at 0.7×cutoff.** It removes only what the speaker barely
   plays (−12 dB and below), so the harmonics add bass instead of replacing
   it. With the physical bass kept, the dry path is the untouched input
   (bit-identical apart from the harmonics).
6. **Source filters.** An extra BW4 above the cutoff keeps mid-range content
   that leaks through the crossover out of the sum tones.
7. **Output.** A 5 ms look-ahead limiter is a safety net; at the app's
   −14 LUFS normalization it does at most about 1 dB. Gains are smoothed and
   structural changes crossfade over 50 ms.

Tried and dropped: splitting the source into 2–3 in-phase LR4 bands before
the generator. A single note gives the same output, but notes less than an
octave apart still share bands. It reduced intermodulation by at most
1.3 dB for 9–17 ms more delay.

## 5. Round three: why both generators still break up, and the per-partial generator

Listening report: better than before. The Apple-style mode breaks up above
drive 0.75 or an upper-limit multiple above 4; the analytic mode above an
order slope of about −12 dB, and it sounds like ordinary low-mids rather
than low bass. Both get worse, with more popping, once the cutoff goes
above 60 Hz.

### Method

`tools/psycho.mjs` adds three auditory measures, applied to the harmonics
alone (in the full mix the music dominates and hides the differences):

- **Roughness** (asper): gammatone filter bank, envelope band-pass per
  channel around the most rough modulation rate, level gate, cross-channel
  correlation, after Daniel & Weber. Popping, buzz and intermodulation all
  show up as roughness.
- **Pitch**: summary autocorrelation (Meddis & Hewitt). The *f0 margin* is
  its value at the note's period minus its value at half that period: near
  0, the pitch is heard an octave up; near 1, at the note.
- An intermodulation share by harmonic masks; on music it proved too coarse
  and is not used below.

The model reproduces the reported thresholds. Harmonics roughness on four
tracks at −14 LUFS, physical bass removed (min–max over tracks):

| Setting (cutoff 60 Hz) | Roughness |
| --- | --- |
| Apple-style, drive 0.5 / 0.75 / 1 / 1.5 | 0.023–0.038 / 0.029–0.042 / 0.035–0.051 / 0.038–0.154 |
| Apple-style, drive 0.7, upper limit ×3 / ×4 / ×6 | 0.025–0.039 / 0.028–0.041 / 0.032–0.045 |
| Analytic, slope −16 / −12 / −8 / −4 dB | 0.015–0.038 / 0.027–0.071 / 0.050–0.130 / 0.077–0.206 |

| Cutoff | Apple-style, drive 0.7 | Analytic, −8 dB | Spectral (standard) | Spectral (high, default) |
| --- | --- | --- | --- | --- |
| 60 Hz | 0.028–0.041 | 0.050–0.130 | 0.041–0.082 | 0.031–0.043 |
| 100 Hz | 0.118–0.175 | 0.238–0.473 | 0.045–0.072 | 0.033–0.066 |
| 150 Hz | 0.194–0.347 | 0.703–0.884 | 0.063–0.073 | 0.045–0.058 |

(Spectral columns: five tracks, default 6 orders at −3 dB. Its harmonics
are about 4 dB louder than the Apple-style mode's at these settings.)

For reference, the music's own content between the cutoff and 8× the
cutoff, scaled to the same level as the harmonics, measures 0.10–0.31 at
100 and 150 Hz cutoffs.

### Causes

1. **Intermodulation.** Any nonlinearity applied to a band holding two
   partials makes products at combinations of both. For two equal partials,
   the inharmonic share of order k grows quickly: +3 dB re the harmonic
   content for z², +9.5 dB for z³, +15 dB for z⁴. Drive, the upper-limit
   multiple and the order slope all add orders. A higher cutoff puts more
   partials in the band at once (the bass note's own 2nd and 3rd harmonics,
   a kick under the bass), so the products multiply. This is the dominant
   cause on music, and no setting of a waveshaper or power series avoids
   it.
2. **Pulse-train phase.** A memoryless nonlinearity, or z^k, puts all
   harmonics in cosine phase. Where neighbouring harmonics fall in one
   auditory filter (notes below about 60 Hz), the ear hears their envelope:
   a pulse at the note rate. That is a buzz even for a single clean note.
3. **Octave-up percept.** When one 2nd harmonic dominates (low drive, steep
   slope), the pitch is heard an octave up; f0 margin 0.32–0.59 for the
   analytic mode at −16 dB. That is the "ordinary low-mids" impression.
   Pitch at the note needs two or more consecutive orders of similar level,
   which a nonlinearity cannot deliver without causes 1 and 2.

### The per-partial generator

```
L,R ─┬─ crossover and dry path as in section 4 ───────────── delay D ─┐
     └─ bass band ─ 90° network ─ analytic signal z                    │
          STFT (Hann Na, hop H = 512): find peaks = partials           │
          per partial: frequency (phase vocoder), amplitude, phase φ   │
          onset check: same frame through a window that ends just      │
            after the output span; much weaker there = not started     │
          per partial, order k: amplitude a·g_k(f), phase k·φ + ψ_k    │
          place each harmonic at its exact frequency (Hann Ns = 1024), │
          inverse FFT, overlap-add ─ × amount ─────────────────────────┤
                                                    look-ahead limiter ┴─ out
```

1. **No intermodulation by construction.** Each partial gets only its own
   harmonics at exact multiples of its own frequency. Two notes give two
   harmonic series, nothing between them. Partials are separated when they
   are at least about 12 Hz apart (high resolution, Na = 8192 at 48 kHz) or
   25 Hz (standard, Na = 4096).
2. **Spread phases.** Order k gets ψ_k = π·k(k−1)/M (Schroeder), so a rich
   series has a flat envelope instead of a pulse train. Turning this off
   raises roughness on music 4–6×.
3. **Recipe.** Orders start at the first one the speaker plays
   (0.95×cutoff, with a smooth rise from 0.75×cutoff), M orders with a
   fixed step per order, then a taper. Levels are set so that the
   harmonics, after the speaker's roll-off, carry the same power as the note
   (`loudnessMatch` 0), or follow ISO 226. The demo prints the orders and
   levels for each fundamental.
4. **Defaults: 6 orders, −3 dB per order.** This gives the note's own pitch
   (f0 margin 0.79–0.87 at 60–150 Hz cutoffs, against 0.61 for 5 orders at
   −4 dB at 60 Hz) at near-minimum roughness. Roughness on single tones is
   lowest at 4–6 orders; 2 orders are rougher (two harmonics beat at the
   note rate), and above 6 orders, or at 0 dB per order, harmonics of
   different partials start to beat (music roughness 0.14–0.20 at 8 orders).
5. **Onsets.** The long analysis window sees a note before it starts. The
   onset check scales each partial by how much of it the shortened window
   still sees, so a new note's harmonics do not start early, while a bass
   sustained under a kick keeps its level (the earlier broadband version
   dipped it by 9 dB before each kick).
6. **Kernel accuracy.** The synthesis kernel spans ±8 bins; inharmonic
   residue −63 dB on single tones.

Cost in the browser: 2–4 % of one core at 48 kHz (high resolution and
8 orders included).

## 6. Measurements

`node tools/analyze.mjs --cutoff 90` (synthetic signals, physical bass
removed, amount 0 dB). Round-two modes:

| Metric (ideal) | Analytic | Apple-style | App Classic | Lab Hybrid |
| --- | --- | --- | --- | --- |
| Inharmonic energy, single tones (lower better) | −88 dB | −89 dB | −89 dB | −88 dB |
| Energy below the cutoff, 40–63 Hz tones (lower better) | **−60 dB or less** | −3 to −9 dB | −3 to −12 dB | −13 to −21 dB |
| Same, 30 Hz tone (its 2nd harmonic at 60 Hz) | −4.3 dB | −0.8 dB | −1.0 dB | −1.4 dB |
| Harmonic power re the note, 30 / 50 / 80 Hz (target 0) | −1.5 / −0.5 / −5.5 | −8.0 / −6.6 / −8.2 | −23.5 / −14.9 / −9.8 | −6.1 / +0.2 / −0.7 |
| Crest factor above the cutoff, 30–50 Hz tones (sine 3.0) | 6.9 dB | 6.5 dB | 5.0 dB | 4.9 dB |
| Level tracking slope (1.00) | **1.00** | 1.00 | 1.03 | 1.24 |
| Timbre change −30 → −3 dBFS (0) | **0.0 dB** | 0.1 dB | 48.8 dB | 13.7 dB |
| Kick thump below 0.6×cutoff (lower better) | **−65 dB** | −8.5 dB | −9.6 dB | −15 dB |
| Kick treble splatter >1.5 kHz (lower better) | **−108 dB** | −63 dB | −100 dB | −80 dB |
| Quiet note after a loud kick (0) | −5.4 dB | −29 dB | −1.2 dB | +0.2 dB |
| IMD, 55 Hz + 41 Hz at −10 dB (lower better) | −3.9 dB | −5.2 dB | −7.4 dB | −6.6 dB |
| IMD, 43 Hz + 61 Hz at −10 dB (lower better) | −7.9 dB | −5.0 dB | −5.7 dB | −5.8 dB |
| IMD, 43 + 61 Hz equal level (lower better) | −1.3 dB | −1.6 dB | −0.8 dB | −0.9 dB |
| Harmonic onset after dry, 50 Hz burst | +4.5 ms | +2.1 ms | +13.5 ms | +11.5 ms |
| Dry-path latency | 23 ms | 12 ms | 0 | 0 |

At 80 Hz part of the note stays in the dry path (the dry crossover is at
63 Hz), so less harmonic power is needed there. The crest factor of a few
harmonics is necessarily above a sine's; what matters for buzz is that the
lowest order dominates, which the spectrograms confirm.

The first prototype scored better on the IMD rows (−10.7 and −10.4 dB),
because its pitch tracker ignored the weaker note. That came with the
glides and lock losses heard as farting, so the IMD rows alone do not
predict the sound.

Real music at −14 LUFS through the simulated 90 Hz speaker (30 s of each of
five tracks: hip-hop, electronic pop, rock, bass music, pop). Change in
80–300 Hz energy vs the unprocessed track through the same speaker:

| Mode | Change in 80–300 Hz | Limiter, worst |
| --- | --- | --- |
| Analytic, 0 dB | +1.2 to +2.7 dB (one track −0.2) | 1.3 dB |
| Analytic, −3 dB | +0.4 to +1.4 dB (one track −0.2) | 0.9 dB |
| Apple-style, +3.5 dB | 0.0 to +0.9 dB | 1.7 dB |

The track that gains nothing carries its bass mostly above 90 Hz, where the
speaker already plays it.

Round three, same harness at a 90 Hz cutoff, per-partial generator with
default settings:

| Metric (ideal) | Spectral, high (default) | Spectral, standard | Analytic | Apple-style |
| --- | --- | --- | --- | --- |
| IMD, 43 + 61 Hz equal level (lower better) | **−25.9 dB** | −4.5 dB | −1.3 dB | −1.6 dB |
| IMD, 43 Hz + 61 Hz at −10 dB | **−26.2 dB** | −11.1 dB | −7.9 dB | −5.0 dB |
| IMD, 55 Hz + 41 Hz at −10 dB | **−18.6 dB** | −17.3 dB | −3.9 dB | −5.2 dB |
| Crest factor above the cutoff, 30–50 Hz tones (sine 3.0) | 5.4 dB | 5.4 dB | 6.9 dB | 6.5 dB |
| Energy below the cutoff, worst tone | −75 dB | −75 dB | −4.3 dB | −0.8 dB |
| Inharmonic energy, single tones | −63 dB | −63 dB | −88 dB | −89 dB |
| Harmonic power re the note, 30 / 50 / 80 Hz (target 0) | 0.4 / −0.1 / −4.2 | same | −1.5 / −0.5 / −5.5 | −8.0 / −6.6 / −8.2 |
| Kick thump below 0.6×cutoff | −39 dB | −40 dB | −65 dB | −8.5 dB |
| Quiet note after a loud kick (0) | −5.0 dB | −3.6 dB | −5.4 dB | −29 dB |
| Harmonic onset after dry, 50 Hz burst | +9.6 ms | +5.2 ms | +6.0 ms | +2.1 ms |
| Harmonic rise 10→90 % | 30 ms | 15 ms | 12 ms | 11 ms |
| Dry-path latency | 105 ms | 63 ms | 23 ms | 12 ms |
| Synthetic groove at 0 dBFS: limiter, worst | 0.9 dB | 2.0 dB | 2.1 dB | 0.3 dB |

The 55 + 41 Hz pair is 14 Hz apart, near the resolution limit of both
settings. "Energy below the cutoff" was −4 dB for the analytic mode
because a 30 Hz note's 2nd harmonic (60 Hz) sits below a 90 Hz cutoff; the
per-partial recipe starts at the first order the speaker plays.

Music through the simulated 100 Hz speaker (30 s, −14 LUFS, files in
`renders/round3/`): 80–300 Hz energy re the unprocessed track, +5.9 and
+3.6 dB (spectral), +4.1 and +2.5 dB (analytic), +0.2 and +0.1 dB
(Apple-style at 0 dB; it needs about +3.5 dB to reach equal power).

## 7. Known limits

Per-partial generator (default):

- **Latency.** 105 ms in high resolution, 63 ms in standard, plus 5 ms for
  the limiter. A music player can report this as output latency; it rules
  the mode out for live monitoring.
- **Attack.** In high resolution harmonics rise over about 30 ms and their
  50 % point is about 10 ms after the dry attack; kicks may feel softer.
  Standard halves both, at the cost of merging partials closer than about
  25 Hz (measured roughness 25–45 % higher on music).
- **Note ends.** The onset check handles starts only. After a note stops,
  its harmonics take about 32 ms to fall by 20 dB (14 ms in standard;
  7–12 ms for the round-two modes), so short staccato notes ring slightly
  longer than the dry signal.
- **Close partials.** Partials less than about 12 Hz apart (25 Hz in
  standard) merge into one peak whose harmonics carry the beating; on the
  55 + 41 Hz pair this leaves −18 dB of products.
- **Hot input without normalization.** On the synthetic 0 dBFS groove the
  limiter reduces up to 0.9 dB (2.0 dB in standard). With normalization
  off, lower the harmonic gain.
- **Notes near the floor** fade out below about 1.2× the floor, so rumble
  does not grow harmonics.

Round-two modes: the analytic and Apple-style generators intermodulate as
described in section 5, increasingly with orders and cutoff; their dry
delays are 23 and 12 ms at a 90 Hz cutoff.

**Not verified by listening.** Every number above is an objective proxy.

## 8. Listening checklist

1. Your speaker setting (speaker simulation on, cutoff 100 or 150 Hz),
   *分音谐波* mode: A/B with `B`. Bass lines and kicks should come back as
   low notes, louder than the original through the same speaker, without
   popping or buzz, at any cutoff.
2. `H` (harmonics only): a bass line whose pitch follows the original notes,
   not an octave up. No noise between notes, no echo before kicks.
3. *泛音数量* and *每阶衰减*: 2–3 orders sound thinner and more octave-up;
   4–6 should sound fullest; 8 orders at 0 dB should start to roughen.
4. *频率分辨率*: on tracks with kicks over sustained 808s, compare high
   (cleaner) with standard (punchier).
5. *泛音增益*: raise it until the bass feels right, then check that the
   limiter meter stays near 0.
6. Compare with the analytic and Apple-style modes at the settings where
   they broke up before.

## 9. Porting notes (after listening sign-off)

- Per-partial generator: per hop of 512 samples (1024 at 96 kHz), two
  forward FFTs of 8192 (4096 in standard), one inverse FFT of 1024, peak
  picking over about 50 bins and at most 24 partials × M orders × 17 kernel
  bins. In the browser this costs 2–4 % of one core; vDSP will be cheaper.
  Port `dsp/spectral.js`, `fft.js` (or use vDSP), `SpectralCore` and
  `spectralGains` in `dsp/engine.js`, and `hilbert.js`.
- The per-sample work is the crossover, the 90° network, the overlap-add
  read and the limiter. Frame work runs every 512 samples; in the app it
  should run on the render thread only if its worst case fits the I/O
  buffer, otherwise on a worker with a matching latency.
- In the app: report the dry-path delay as kernel latency. Keep the chain
  limiter and loudness normalization. Remove kernel-level ducking and
  per-sample clipping. Map output kind to presets (headphones: cutoff about
  60 Hz with bass kept; speakers: the device's real cutoff with bass
  removed below 0.7× cutoff).

## References

- Moliner, Rämö, Välimäki, "Virtual bass system with fuzzy separation of
  tones and transients", DAFx-20 (CC BY 3.0).
  https://www.dafx.de/paper-archive/2020/proceedings/papers/DAFx2020_paper_40.pdf
- Khanal, Breitschaedel, Iyengar (Apple), US10382857B1.
  https://patents.google.com/patent/US10382857B1/en
- Oo, Gan, Hawksford, "Perceptually-motivated objective grading of
  nonlinear processing in virtual-bass systems", JAES 59(11), 2011.
- Larsen, Aarts, "Reproducing low-pitched signals through small
  loudspeakers", JAES 50(3), 2002; *Audio Bandwidth Extension*, Wiley.
- Bai, Lin, "Synthesis and implementation of virtual bass system with a
  phase-vocoder approach", JAES 54(11), 2006.
- Dirac Research, US12254863B2. https://patents.google.com/patent/US12254863B2/en
- Yuli You (Guoguang), US9794689B2. https://patents.google.com/patent/US9794689B2/en
- Bankstown (Asahi Linux). https://github.com/chadmed/bankstown
- ISO 226:2003 equal-loudness contours; ITU-R BS.1770-4 loudness.
