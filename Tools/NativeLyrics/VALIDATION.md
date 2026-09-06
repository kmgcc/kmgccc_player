# Native Lyrics Demo validation

This package is an isolated macOS AppKit demo. It does not modify the production WKWebView AMLL surface.

## Reproducible checks

From the repository root:

```sh
swift test --package-path Tools/NativeLyrics --quiet
swift run --package-path Tools/NativeLyrics --quiet LyricsProbe \
  Tools/NativeLyrics/.local/song.ttml \
  Tools/NativeLyrics/output/compare 10 760 720 --paused
bash Tools/NativeLyrics/script/build_and_run.sh
```

The current run passes **46 XCTest cases**. The fixed-song probe loads 80 groups and 549 timed spans after the fixture preparation step; the latest 3-second ProMotion replay reports about 118.7 Hz callbacks, 0.47 ms median render time, 0.65 ms P95, and 1.32 ms maximum while keeping glyph cache usage bounded by the configured budget.

The fixture preparation script is deliberately outside the renderer. It converts the library's legacy absolute-time resource into standard parent-relative TTML, while the public `TTMLDecoder` rejects unnamespaced timed input and accepts only the standard TTML contract.

The Demo's `Library songs` menu uses the same boundary for real player-library files. Its adapter recognizes compact `mm:ss` clocks, bare decimal-second attributes, repeated absolute `begin`/`end` values on `div → p → span`, and explicit empty namespace declarations on timed nodes. It serializes the repaired document with explicit seconds, then runs the strict decoder. A batch pass over the available library material validated **396 of 397** files; the remaining file is truncated XML and is reported as invalid instead of being guessed into a different lyric order. Sidecar metadata supplies the visible track title, while `amll:meta musicName` is used when no sidecar title exists.

## APP reference comparison

`Tools/NativeLyrics/product-reference.html` loads the existing APP `index.html` and `bridge.js` unchanged in a browser reference. At 760pt × 720pt, 38pt main text, 28.5pt translation, and paused time 10s, the first nine visible groups were measured against the native trace:

- group height error: approximately 0.1pt maximum;
- group position error: approximately 0.3pt maximum;
- active line, translation, background voice, blur distance, and duet alignment are visible in both captures.

The browser capture is an oracle for geometry and state only. It is not linked into `NativeLyrics` or the demo executable.

## Manual Demo paths exercised

- launch at time 0 with the fixed TTML/audio fixture;
- play/pause and media clock progression;
- seek slider and ±5s controls;
- follow after manual scroll;
- smooth words, discrete words, and line-timing-only modes;
- Emphasis, Glow, Translation, Ruby, and Blur toggles;
- Sample menu: fixed library song, motion laboratory, long-vowel Glow showcase, duet/Ruby, and chorus/background fixtures;
- Glow radius sweep from 0.5× through 3×; the halo follows the per-character glyph alpha, uses the padded glyph tile as its bounded expansion area, and never fills the tile as a rectangle;
- interlude dots aligned to the same horizontal inset as the following lyric row, with a centered scale anchor and a configurable `interludeDotScale`;
- resize reflow of wrapped half-lines using a critically damped, zero-initial-velocity track;
- seek while paused, playback-stall highlight smoothing, and exit-time highlight catch-up;
- public cover-blur configuration remains available for host integration (`coverBlurProfile`, `coverBlurRenderLayer`, `coverBlurHideActiveMainLine`, `coverBlurSuppressEmphasisGlow`, `coverBlurGenericMode`, and `fullscreenLyricDodgeMode`); the Demo only exposes controls with a visible, verified effect;
- explicit blend opacity/mode, raster scale, and display-link cap are exposed in `LyricsConfiguration` for host-side stress runs;
- native resize and window occlusion lifecycle;
- native lyric click and context-menu copy path.
- the `Library songs` menu, including selecting a real absolute-time library export, title/metadata display, and an adjacent audio file when present;
- a batch `--dump-import` check over player-library `lyrics.ttml` files, including one-line absolute timing and namespace-shadow cases;
- prompt smooth-mask tracking during normal playback samples; paused and seeked samples still snap exactly to the requested media time.
- launch without the optional local fixture, where the Demo falls back to the visible Glow sample instead of opening on an all-future blurred Motion lead-in.

## Remaining acceptance boundary

Cover artwork blur, ThemeStore color extraction, and final fullscreen skin composition remain host responsibilities. The native lyric surface exposes the same semantic channels and timing states, but production integration still needs a separate adapter and real-window parity pass for every main/fullscreen/MiniPlayer host. No production renderer switch has been made on this branch.
