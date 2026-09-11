# NativeLyrics Production Integration Plan

Date: 2026-09-09

## Goal

Make `NativeLyrics` the complete production lyric renderer for the player. The
result must follow the audible playback clock, preserve the existing player
timing and seek contracts, work in every lyric host, and no longer rely on a
`LyricsWebViewStore` as the state adapter for native rendering.

The legacy AMLL WebView implementation remains available only as rollback code
until the native path passes the runtime acceptance matrix below. Generated
AMLL resources and the AMLL submodule are outside this change.

## Confirmed baseline before this repair

- Production selects `LyricsRendererBackend.native`.
- `NativeLyrics` package tests pass (75 tests after the timing, parallel-focus,
  font-face and scroll corrections; the initial checkout had 48 tests after
  clearing a stale SwiftPM module cache).
- The package owns TTML parsing, timing, layout, focus, scroll, karaoke masks,
  emphasis, glow, background vocals, duet, translation, romanization, ruby,
  interludes, resize reflow, pause/resume, and seek behavior.
- App integration still routes native state through `LyricsWebViewStore`, and
  the visible hosts have no App-level proof that playback drives continuous
  native frames.
- The persisted spring defaults in `AppSettings` (`0.40`, `0.75`) disagree with
  the documented settled default (`0.65`, `0.25`) and are mapped through a
  separate, more oscillatory native conversion.

## Work plan

1. Reproduce and instrument the real App path.
   - Build and launch the branch App from an isolated DerivedData directory.
   - Bind evidence to that exact process and inspect lyric lifecycle logs.
   - Verify whether content, playback time, playing state, view attachment, and
     display ticks all reach the visible native surface.

2. Replace the compatibility bridge with a native App adapter.
   - Give `LyricsSurfaceManager` one native playback/config snapshot owner.
   - Apply content atomically, then synchronize clock and playing state.
   - Keep every role's playback snapshot current while allowing frame delivery
     only for visible/active roles.
   - Preserve explicit seek discontinuities, click-to-seek cascade, pause,
     resume, replay, and track/source changes.
   - Remove production native calls from `LyricsWebViewStore`; keep that type
     only for the AMLL rollback backend.

3. Make hosting and lifecycle deterministic.
   - Ensure main AppKit, SwiftUI fallback, fullscreen, Cover Blur layers, and
     batch preview each own one role-specific `LyricsView`.
   - Add explicit attach/detach/visibility hooks so display updates wake when a
     view becomes visible and stop when it cannot render.
   - Prevent the same `NSView` from being simultaneously mounted by competing
     hosts or transient SwiftUI branches.

4. Complete configuration parity.
   - Preserve track offset/global advance vs. click seek offset semantics.
   - Map fonts, weights, translation, romanization, ruby, highlight
     mode, blur, glow, render quality, alignment, overscan, palettes, channel
     blend, Cover Blur, and Apple-style surfaces without stale state leakage.
   - Replace the old AMLL-named settings bridge with renderer-neutral naming
     where it can be done without breaking stored preferences.

5. Retune spring behavior.
   - Use the documented calm default (`duration = 0.65`, `bounce = 0.25`).
   - Preserve genuinely customized user values; migrate only the legacy exact
     default when no intentional customization can be inferred.
   - Use one tested duration/bounce conversion for window and fullscreen roles.

6. Add regression coverage and validate.
   - Package tests for clock anchoring, pause/resume, repeated synchronization,
     spring mapping, and lifecycle wake behavior where deterministic.
   - App adapter tests for snapshot replay, role activation, config mapping,
     offsets, track replacement, invalid TTML preservation, and seek routing.
   - Incremental macOS Debug build.
   - Runtime acceptance on the exact built App: play, pause/resume, seek, track
     switch, panel hide/show, resize, fullscreen enter/exit, Cover Blur, and
     external playback when available.

## Acceptance matrix

| Area | Required result |
| --- | --- |
| Playback | Karaoke masks and focus advance continuously while audio plays. |
| Pause/resume | Pausing freezes media time exactly; resume continues without a jump. |
| Seek/click | Scrub is immediate; lyric click seeks once and returns with cascade motion. |
| Track/source | New valid TTML replaces atomically; invalid TTML preserves the last valid document and reports an error. |
| Main panel | Initial show, hide/show, queue overlay, and resize retain current time and follow mode. |
| Fullscreen | System fullscreen, embedded fullscreen, and normal return use the correct role and current snapshot. |
| Skins | Standard, Cover Blur base/highlight, and Apple-style colors/blending do not leak between modes. |
| Content | Line/word timing, BG, duet, translation, romanization, ruby, emphasis/glow, interlude, and plain line-timed TTML render. |
| Motion | Default position motion is controlled and less bouncy; resize is gentle and seek never inherits stale spring velocity. |
| Resources | Hidden/detached surfaces stop display work; visible surfaces wake reliably; no production lyric WebView/WebContent process is created. |

## Delivery record

### Root causes closed

- The production native path was still routed through `LyricsWebViewStore`.
  `LyricsViewModel` published the same document and playback state through both
  the manager and store, so forced refreshes could install the lyric twice and
  reset native motion.
- Main and fullscreen configuration was delivered after lyric content. The
  entrance/layout animation could therefore start with defaults and then jump
  to its final timing, font, alignment and spring values.
- Native playback snapshots were broadcast to every surface, overwriting the
  batch editor's independent document and clock.
- Native suspend/resume did not actually stop or wake frame delivery, and mode
  switches removed logical roles without consistently deactivating the
  opposite persistent native surface.
- Main, fullscreen, and batch click callbacks were still bound to WebView
  stores in several paths. Fullscreen auto-restore also directly created the
  rollback store.
- Empty TTML was sent to the XML decoder. That failure intentionally preserves
  the old valid document, so a track with no lyrics incorrectly kept showing
  the previous track.
- The player's legacy AMLL/LDDC TTML export repeats absolute `begin`/`end`
  clocks on `div`, `p`, and `span`. Before this repair the default decoder
  resolved child clocks relative to their parent, so nested times accumulated
  and manufactured late lines and false interludes. The decoder now defaults
  to `.amllAbsolute`; parent-relative parsing is explicit and opt-in.
- The persisted default spring pair (`0.40`, `0.75`) was more oscillatory than
  the documented settled pair (`0.65`, `0.25`), and the native mapper replaced
  the package's interval-adaptive spring even when the user had selected the
  default.
- LDDC-to-TTML line exports contain one timed span per LRC line. The native
  renderer treated that span as karaoke word timing, so a line-level clock was
  drawn as a slow/stalling word sweep. Effective timing now requires at least
  two distinct meaningful word ranges per line.
- The native highlight sampler synthesized a forward glide when consecutive
  host samples were equal. That made the mask lead or lag the authoritative
  media clock and was removed; only authored `MaskPath` gap anticipation
  remains.
- Parallel foreground rows were removed as soon as their individual ranges
  expired. Timeline buffering now mirrors AMLL's foreground span and retains
  completed middle rows until the whole parallel group ends; all retained rows
  are exempt from blur.
- Manual scroll was implicitly cancelled by the next focus change. It now
  remains suspended while the pointer is inside the lyric surface and arms the
  five-second return timeout only after pointer exit.
- AppKit's numeric font descriptor weight is ignored by several lyric font
  families. Native layout now selects concrete family faces, including
  UltraLight/Thin/Light/Medium/Semibold/Bold, so light and dark weights are
  independent in practice.
- Generic Apple-style/Cover Gradient fullscreen lyrics use one native surface.
  Their mapper previously selected the `base` render channel, hiding the
  highlight ink; the single-surface path now stays on `full`, reserving
  `highlight` for the dedicated overlay role.

### Implementation

- `NativeLyricsSurfaceManager` is now the single production adapter for
  content, time, playing state, configuration, render scale, palette, seek
  callbacks and role lifecycle. The WebView store remains rollback-only.
- Configuration is stored before lazy surface creation and before the single
  atomic document load. Main, system/embedded fullscreen, Cover Blur
  base/highlight, auto-restore and batch preview all use their explicit native
  role.
- Visible role activation controls `LyricsView.automaticDisplayUpdates`;
  hidden panels and opposite modes stop frame work while their retained
  snapshots remain current.
- `LyricsView.clear` gives empty lyrics a real clear operation while invalid
  non-empty TTML continues to preserve the last valid document and report an
  error.
- `TTMLDecoder` now defaults to the explicit `.amllAbsolute` profile and every
  main/fullscreen/Cover Blur/batch surface receives the stored AMLL TTML bytes
  directly. The opt-in `.w3cRelative` profile remains available for genuine
  parent-relative inputs; neither profile rewrites XML at the surface boundary.
- Batch preview owns an isolated document/clock and direct native seek route.
- Defaults are now `0.65` / `0.25`. Only the exact legacy default pair is
  migrated; custom values remain intact. The default uses NativeLyrics'
  interval-adaptive position spring, while custom values use one tested
  relative duration/bounce conversion across the supported range.
- Line-level LDDC TTML uses the native line lifetime path; true multi-word
  karaoke keeps the mask path and discrete/smooth word modes. Parallel
  highlight retention, pointer-exit browsing timeout, concrete font-face
  selection, and generic fullscreen render-layer selection are covered by
  package/App regression tests.

### Automated validation

- `swift test --package-path Tools/NativeLyrics --quiet`: 69 tests passed.
  Added deterministic coverage for effective LDDC line timing, exact mask
  sampling, three-parameter timing preprocessing, parallel retention, pointer
  exit gating, concrete font weights and generic fullscreen channels.
- Focused App test target: 12 tests passed for preview isolation, activation,
  lazy seek binding, empty clear, invalid-TTML preservation, configuration-
  before-materialization, strict TTML pass-through, legacy absolute timing
  normalization (including line and word ranges), and legacy namespace repair.
- Incremental macOS Debug build completed successfully with isolated DerivedData
  at `/tmp/myPlayer2-native-lyrics-fix`.
- `git diff --check` passed.

### Manual acceptance boundary

Per maintainer direction, no UI automation is part of acceptance. The
maintainer will exercise playback, pause/resume, seek/click, track switch,
panel hide/show, resize, both fullscreen hosts, Cover Blur/Apple-style skins and
external playback on the normal signed App/library environment. Automated
results above intentionally do not claim those visual/user-flow checks.
