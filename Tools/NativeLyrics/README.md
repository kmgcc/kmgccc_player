# Native Lyrics

`NativeLyrics` is the isolated AppKit/Core Text/Core Animation implementation used to compare AMLL behavior before any production renderer switch.

The public surface is intentionally small:

- `LyricsView.load(ttml:)` accepts AMLL TTML data directly;
- `LyricsView.synchronize(time:playing:seek:)` receives host media state;
- `LyricsView.onSeek` returns the source click target;
- `LyricsConfiguration` selects the current-player/upstream timing profile, typography, language layers, emphasis, cover-blur channels, compositing opacity/blend mode, raster scale, frame-rate cap, and interaction behavior.
- Resize reflow is separately tunable through `configuration.motion.resizeSpring`; the interlude indicator uses a centered transform anchor and its diameter is controlled by `configuration.interludeDotScale`.

The APP-only adapter switches are represented as semantic configuration instead
of leaking DOM details: `coverBlurProfile`, `coverBlurRenderLayer`,
`coverBlurHideActiveMainLine`, `coverBlurSuppressEmphasisGlow`,
`coverBlurGenericMode`, `fullscreenAppleStyleMode`,
`fullscreenLyricDodgeMode`, `preserveCompletedHighlight`, and the separate
visual/click timing offsets are all available before a production adapter is
introduced. Artwork blur and ThemeStore color derivation stay with the host.

The package contains a deterministic `LyricsProbe`, an AppKit `NativeLyricsDemo`, AMLL TTML fixtures, and the [validation record](VALIDATION.md). The demo's `Sample` menu switches between the fixed library song, a motion laboratory, a long-vowel Glow showcase, a duet/Ruby example, and a chorus/background timing example. A Glow radius slider (0.5×–3×) and an interlude-dot size slider (0.5×–2.5×) make those effects easy to compare without changing the default profile. The Demo previews the first timed word on launch; if the optional local library fixture is unavailable or invalid, it starts on the Glow sample so the initial paused window contains visible lyric content instead of only blurred future rows. Passing `--start 0` restores an exact zero-time preview.

The Demo also exposes a `Library songs` menu. It scans the registered player-library `Tracks` folders and offers validated lyric files (up to 48 entries) with their sidecar title/artist/album and adjacent audio when available. The importer passes the stored bytes directly to the AMLL decoder; compact `mm:ss`, bare decimal seconds, absolute descendant times, namespace shadows, metadata, and sidecars are handled in the decoder without rewriting the XML. LRC and other lyric formats remain outside this package.

```sh
swift test --package-path Tools/NativeLyrics --quiet
bash Tools/NativeLyrics/script/build_and_run.sh
```

The behavior regressions and validation suite are documented in [VALIDATION.md](VALIDATION.md) and [BEHAVIOR-REGRESSIONS.md](BEHAVIOR-REGRESSIONS.md).
