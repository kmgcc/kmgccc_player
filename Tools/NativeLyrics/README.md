# Native Lyrics

`NativeLyrics` is the isolated AppKit/Core Text/Core Animation implementation used to compare AMLL behavior before any production renderer switch.

The public surface is intentionally small:

- `LyricsView.load(ttml:)` accepts standard TTML data only;
- `LyricsView.synchronize(time:playing:seek:)` receives host media state;
- `LyricsView.onSeek` returns the source click target;
- `LyricsConfiguration` selects the current-player/upstream timing profile, typography, language layers, emphasis, cover-blur channels, compositing opacity/blend mode, raster scale, frame-rate cap, and interaction behavior.

The APP-only adapter switches are represented as semantic configuration instead
of leaking DOM details: `coverBlurProfile`, `coverBlurRenderLayer`,
`coverBlurHideActiveMainLine`, `coverBlurSuppressEmphasisGlow`,
`coverBlurGenericMode`, `fullscreenAppleStyleMode`,
`fullscreenLyricDodgeMode`, `preserveCompletedHighlight`, and the separate
visual/click timing offsets are all available before a production adapter is
introduced. Artwork blur and ThemeStore color derivation stay with the host.

The package contains a deterministic `LyricsProbe`, an AppKit `NativeLyricsDemo`, standard TTML fixtures, and the [validation record](VALIDATION.md). The demo's `Sample` menu switches between the fixed library song, a motion laboratory, a long-vowel Glow showcase, a duet/Ruby example, and a chorus/background timing example. A Glow radius slider (0.5×–3×) makes the emphasis halo easy to compare without changing the default profile.

```sh
swift test --package-path Tools/NativeLyrics --quiet
bash Tools/NativeLyrics/script/build_and_run.sh
```

The package is not part of the Xcode application target yet. The migration route and the complete AMLL/fork behavior matrix are documented in [Native Lyrics / AMLL Parity Investigation](../../docs/native-lyrics-amll-parity-investigation.md).
