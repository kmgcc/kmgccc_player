# Virtual Bass Prototype

A standalone test bench for virtual bass (psychoacoustic bass extension).
It has a real-time browser demo and an offline measurement and render
harness, both running the same DSP code in `dsp/`. It does not touch the app.

Findings, design and measurements: [NOTES.md](NOTES.md).

Requirements: Node 18+ and a Chromium-based browser or Safari. The offline
tools also need `ffmpeg` to decode compressed audio. No packages to install.

## Real-time demo

```bash
node Tools/VirtualBassPrototype/serve.mjs --media ~/Music
```

Open http://localhost:8723. `--media` is optional: it lists a folder of
audio files under **Library**. You can also open or drop any file, or pick
a built-in test signal.

- **Processed / Original** (`B`): A/B with matched delay and level.
- **Modes**:
  - *Spectral* (分音谐波): proposed, see NOTES.md section 5. Gives every
    bass partial its own harmonics, so it does not intermodulate.
  - *Analytic* (解析谐波): the second round's proposal, section 4.
  - *Level-normalized NLD*: modelled on Apple's US10382857B1.
  - *App Classic*: exact port of the current app kernel.
  - *Lab Hybrid*: the previous fix attempt.
- **Presets**: *Small speaker (simulated)* and *Laptop (simulated)* remove
  the bass a small speaker cannot play and high-pass the output, so
  headphones sound like that speaker. *Headphones* keeps the real bass and
  adds harmonics only.
- **Listen to** (`H`): the generated harmonics alone, or the bass the
  speaker loses. `S` toggles the speaker simulation.
- **Normalize to −14 LUFS**: on by default, as in the app.
- The spectrum shows input, output and generated harmonics; the dashed
  line is the cutoff. Double-click a slider to reset it. Settings persist
  in the browser.

## Measurements

```bash
node Tools/VirtualBassPrototype/tools/analyze.mjs
node Tools/VirtualBassPrototype/tools/analyze.mjs --cutoff 150 --music-only track1.m4a track2.mp3
node Tools/VirtualBassPrototype/tools/analyze.mjs --modes spectral --params '{"resolution":"standard"}'
```

This runs self-checks (quadrature accuracy, ISO 226, limiter ceiling) and
per-mode metrics: inharmonic and sub-cutoff energy, harmonic level, crest
factor (buzz), intermodulation, level linearity, timbre stability, thump,
splatter, post-kick ducking, onset timing and pumping. Music excerpts are
measured at −14 LUFS (`--raw` to disable).

`tools/psycho.mjs` holds the auditory measures used in NOTES.md section 5
(roughness, summary-autocorrelation pitch); import it from a script to
compare settings on your own tracks.

## Spectrograms

```bash
node Tools/VirtualBassPrototype/tools/spectrogram.mjs track.m4a --start 60 --duration 8 --modes spectral,apple --show harm,out --sim
```

Writes a PNG (default `renders/spectrogram.png`) with the input on top and,
per mode, the generated harmonics and/or the output below it, latency-aligned
on one log-frequency, dBFS scale. The bright row is the cutoff. Pitch glides,
clicks (vertical lines) and noise between notes are easy to see here.

## Offline renders

```bash
node Tools/VirtualBassPrototype/tools/render.mjs track.m4a --start 60 --duration 30 --params '{"cutoff":150}' --sim
```

Writes `renders/<track>.original.wav` and one WAV per mode, normalized and
latency-aligned, so they can be compared in any player or editor.
`renders/` is git-ignored.

## Layout

| Path | Contents |
| --- | --- |
| `dsp/engine.js` | Engine, modes, parameters and defaults |
| `dsp/spectral.js`, `dsp/fft.js` | Per-partial harmonic generator, radix-2 FFT |
| `dsp/filters.js` | Biquads, Butterworth and Linkwitz–Riley designs, group delay |
| `dsp/hilbert.js` | 90° phase-splitting network (analytic signal) |
| `dsp/dynamics.js` | Peak-hold follower, envelopes, look-ahead limiter |
| `dsp/loudness.js`, `dsp/lufs.js` | ISO 226 contours, BS.1770 loudness |
| `dsp/legacy.js` | Ports of the current app and lab kernels |
| `dsp/signals.js` | Test signals |
| `index.html`, `app.js`, `worklet.js`, `serve.mjs` | Demo |
| `tools/` | Measurement, auditory model (`psycho.mjs`), render, spectrogram (`png.mjs` writes the PNG) and audio I/O |

All DSP is plain code with explicit state (per sample, or per frame in
`spectral.js`), to port to Swift or C once the sound is signed off.
