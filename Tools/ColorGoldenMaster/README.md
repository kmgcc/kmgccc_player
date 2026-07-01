# Color Golden Master

This tool is the first Golden Master guard for the color-system refactor. It
captures current behavior; it does not claim the current visual result is
ideal.

## What It Builds

`run.sh` builds a standalone Debug CLI with the current production color source
files:

- `OKColor`
- `ColorMath`
- `ColorSystemTokens`
- `ArtworkColorAnalysis`
- `ArtworkColorExtractor`
- `SemanticPaletteFactory`
- `LEDColorResolver`
- `BKColorEngine`

The CLI uses a local no-op logging shim. No production source file is modified
by this tool.

## Samples

The snapshot is split into three stable sections:

- Golden Gate: 19 fixed real-cover samples from
  `docs/oklch-color-system-refactor-findings.md`.
- Extended Corpus: 130 frozen real covers from the local track library,
  selected by a fixed seed and stored in
  `Tools/ColorGoldenMaster/Fixtures/extended-corpus-manifest.json`.
- Synthetic: 7 deterministic samples for nearMono, UltraDark, black
  micro-accent, warm paper, high saturation, and single-hue tonal depth.

Real artwork is read in place:

```text
/Users/kmg/Music/kmgccc_player Library/Tracks/<TRACK_ID>/artwork.jpg
```

The tool never copies cover images into the repo. Extended corpus entries store
the artwork path and FNV-1a hash; if a local cover changes, `verify` fails with
an artwork hash mismatch.

The extended corpus uses seed:

```text
color-golden-master-extended-v1-2026-06-26
```

Current scan summary:

- source artwork files: 277
- Golden Gate files excluded from extended corpus: 19
- decoded/analyzed files: 258
- stable candidate files after rank-tie screening: 161
- selected extended samples: 130
- decode failures: 0

The stability screen excludes extended-corpus covers whose production
`surfacePalette`/salient ranking shows same-share or low-share cutoff risk. This
only chooses which real covers enter the frozen corpus; it does not sort,
canonicalize, or alter production color output.

## Commands

Run from the repo root.

Generate and approve the current baseline:

```sh
Tools/ColorGoldenMaster/run.sh generate
```

Verify the current system against the approved baseline:

```sh
Tools/ColorGoldenMaster/run.sh verify
```

On mismatch, the current output is written to:

```text
Tools/ColorGoldenMaster/.generated/color-golden-master.current.txt
```

Then inspect:

```sh
diff -u Tools/ColorGoldenMaster/Baselines/color-golden-master.txt \
  Tools/ColorGoldenMaster/.generated/color-golden-master.current.txt
```

Print a snapshot without writing the approved baseline:

```sh
Tools/ColorGoldenMaster/run.sh snapshot
```

Write the Stage 3 controlled accent parity report:

```sh
Tools/ColorGoldenMaster/run.sh accent-parity
```

Generate the interactive local Accent Parity Review page:

```sh
Tools/ColorGoldenMaster/run.sh accent-review
```

The page is written to:

```text
Tools/ColorGoldenMaster/.generated/accent-parity-review.html
```

It is a static, double-clickable review artifact. It embeds a representative
queue of about 100 items from the real parity output, shows legacy HSL vs
candidate OKLCH in UI-like accent and MiniPlayer contexts, and renders both
Display P3 CSS and adapter-derived sRGB fallback swatches. The page stores
in-progress decisions in browser local storage and can download/import a review
session JSON.

Export a downloaded review session into follow-up files:

```sh
Tools/ColorGoldenMaster/run.sh accent-review-export \
  Tools/ColorGoldenMaster/ReviewSessions/accent-review-session.json
```

The export command writes an ignored directory under
`Tools/ColorGoldenMaster/ReviewSessions/` containing:

- `accent-approved-deltas.candidate.json`
- `needs-tuning.md`
- `legacy-better.md`
- `candidate-better.md`
- `both-acceptable.md`
- `undecided.md`
- `summary.md`

Refresh the extended real-cover corpus. This is intentionally explicit and must
not be run as part of ordinary verification:

```sh
Tools/ColorGoldenMaster/run.sh refresh-extended-corpus \
  --seed color-golden-master-extended-v1-2026-06-26 \
  --target 130
```

## Authenticity Matrix

| Snapshot block | Production calls | Tool-side logic |
| --- | --- | --- |
| `classification.*`, `analysis.*` | Real covers call `ArtworkColorExtractor.analyze(from:)`; synthetic calls `ArtworkColorExtractor.analyzeSyntheticSample(...)`; both return production `ArtworkColorAnalysis`. | Only file loading, hash checking, and stable text formatting. |
| `semantic.*` | `SemanticPaletteFactory.make(from:scheme:userFallbackAccent:useArtworkTint:)` with the production analysis. | Fixed fallback accent value and formatting only. |
| `lyrics_surface.*.standard_fullscreen` | `SemanticPaletteFactory.fullscreenLyricsColorSet(... usesArtisticBackground: false)`. | Formatting only. |
| `lyrics_surface.*.art_background_fullscreen` | `SemanticPaletteFactory.fullscreenLyricsColorSet(... usesArtisticBackground: true)`. | Formatting only. |
| `lyrics_surface.*.cover_blur_*` | `SemanticPaletteFactory.coverBlurLyricsColorSet(...)`. | Formatting only. |
| `lyrics_surface.*.artistic_seed` | `SemanticPaletteFactory.artisticLyricsSingleSeed(...)`. | Formatting only. |
| `led.*` | Production `LEDColorResolver` properties and methods: `centerColor`, `edgeColor`, `statusLightColor`, `statusLightStrokeColor`, `volumeLEDColor`, `volumeLEDStrokeColor`. | Formatting only. |
| `bk.base_palette` | Production cache-miss/direct-analysis base palette input. | Records `analysis.topPalette` before selection. |
| `bk.selected_extracted_palette` | Production `BKExtractedPalettePolicy.select(analysis:basePalette:richPalette:fallbackPalette:)`. | Uses `analysis.topPalette` as `basePalette` (cache-miss/direct-analysis path). |
| `bk.*` engine fields | Production `BKColorEngine.make(extracted:fallback:isDark:analysis:)`. | Uses the cache-miss selected extracted palette as input; records returned fields directly. |
| `bk.*.shape_swatches.*` | Production `BKColorEngine.makeShapeSwatches(...)`; diagnostics are the returned production diagnostics. | Uses fixed deterministic seed per sample/scheme. |
| `bk.*.stabilized_shape_jitter_*` | Production `BKColorEngine.stabilize(color:kind:palette:saturationJitter:brightnessJitter:)`. | Fixed jitter values and formatting only. |
| `bk.hit.base_palette` | Production cache-hit/snapshot base palette input. | Records `analysis.displayPalette` when present, otherwise `analysis.topPalette`, matching the snapshot path. |
| `bk.hit.selected_extracted_palette` | Same production `BKExtractedPalettePolicy.select(...)`. | Uses `analysis.displayPalette` as `basePalette` (cache-hit/snapshot path, mirroring `ArtworkAssetStore` snapshot construction). |
| `bk.hit.*` engine fields | Same production `BKColorEngine.make(...)`. | Uses the cache-hit selected extracted palette as input. |
| `bk.hit.*.shape_swatches.*` | Same production `BKColorEngine.makeShapeSwatches(...)`. | Uses fixed deterministic seed (distinct from cache-miss seed). |
| `bk.hit.*.stabilized_shape_jitter_*` | Same production `BKColorEngine.stabilize(...)`. | Fixed jitter values and formatting only. |
| `bk.hit_miss.*_differs` | Same production BK selection, engine, shape swatch, and stabilize calls for both paths. | Boolean comparison fields only; swatch/stabilize comparison uses a shared deterministic seed so randomness cannot create a false path diff. |

Call chain for real artwork:

```text
artwork.jpg
  -> Data(contentsOf:)
  -> ArtworkColorExtractor.analyze(from:)
  -> ArtworkColorAnalysis
  -> SemanticPaletteFactory / LEDColorResolver / BKColorEngine
  -> stable text snapshot
```

BK palette selection, engine output, shape swatches, diagnostics, and stabilize
are real production calls exercised for both cache-hit (`bk.hit.*`) and
cache-miss (`bk.*`) input paths. The SwiftUI/AppKit `BKArtBackgroundView`
lifecycle, layer layout, animation state, and controller side effects are not
covered. The `bk.hit_miss.*_differs` lines are review aids: they make it
explicit whether the two input paths differ at the base palette, selected
palette, engine output, same-seed shape swatch, or same-seed stabilized shape
level.

## Stability Rules

Each command renders the snapshot twice before writing or comparing. If the two
renders differ, the command fails with:

```text
output fields are unstable: two consecutive renders differed
```

The snapshot avoids timestamps, random UUIDs, memory addresses, and temporary
paths. Sample order, field order, numeric precision, color formatting, and seed
values are fixed.

Colors are recorded as:

```text
#RRGGBB a=<alpha> oklch(L=<L> C=<C> H=<H>) hue_reliable=<true|false>
```

Low-chroma hues are still recorded numerically, but `hue_reliable=false` means
future reviewers must not interpret the hue as stable semantic evidence.

## Failure Messages

Expected hard failures include:

- `sample artwork path does not exist`
- `sample artwork could not be read`
- `image decode or color analysis failed`
- `extended corpus artwork hash changed`
- `extended corpus manifest missing`
- `synthetic sample analysis failed`
- `output fields are unstable`
- `golden file missing`

## Coverage

The baseline records:

- `ArtworkColorAnalysis` classification, major statistics, and palettes
- primary hue source and hue-trust state
- `SemanticPaletteFactory.make()` roles for dark and light schemes
- readability, app foreground, mini-player control, and lyrics palettes
- standard fullscreen, artistic fullscreen, and CoverBlur lyric color sets
- LED center/edge/status/volume colors for dark and light schemes
- BK selected extracted palette policy for both cache-hit and cache-miss input
  paths, `BKColorEngine.make`, BK shape swatches, diagnostics, and fixed-jitter
  stabilized shape colors
- BK cache-hit/cache-miss comparison booleans for base palette, selected
  palette, engine output, same-seed shape swatches, and same-seed stabilized
  shape colors

Not covered yet:

- live SwiftUI/AppKit rendering
- animated BK layer state, layout-dependent variants, and NSView lifecycle
  output
- WebView/AMLL CSS variable application
- semantic portrait/illustration/animation classification for the extended
  corpus
- manual visual QA for seek, pause/resume, fullscreen transitions, and cover
  blur

Do not expand this by invading production views. Add a tiny Debug-only bridge
only if a future guard truly cannot be built from stable non-UI APIs.

## Update Discipline

A-class refactors must keep `verify` at zero diff.

B-class visual changes may update `Baselines/color-golden-master.txt`, but the
commit must explain every intended sample delta. Do not mix a baseline update
with behavior-preserving cleanup.
