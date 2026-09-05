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

The current run passes **26 XCTest cases**. The fixed-song probe loads 80 groups and 549 timed spans after the fixture preparation step; the 120 Hz paused replay reports a render p95 of about 0.67 ms/frame and keeps glyph cache usage bounded by the configured budget.

The fixture preparation script is deliberately outside the renderer. It converts the library's legacy absolute-time resource into standard parent-relative TTML, while the public `TTMLDecoder` rejects unnamespaced timed input and accepts only the standard TTML contract.

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
- Lighter/Darker cover profile;
- Full/Base/Highlight cover render layers;
- Hide active, Suppress glow, Generic cover, and Lyric dodge flags;
- explicit blend opacity/mode, raster scale, and display-link cap are exposed in `LyricsConfiguration` for host-side stress runs;
- native resize and window occlusion lifecycle;
- native lyric click and context-menu copy path.

## Remaining acceptance boundary

Cover artwork blur, ThemeStore color extraction, and final fullscreen skin composition remain host responsibilities. The native lyric surface exposes the same semantic channels and timing states, but production integration still needs a separate adapter and real-window parity pass for every main/fullscreen/MiniPlayer host. No production renderer switch has been made on this branch.
