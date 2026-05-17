# Now Playing Skins (Developer Guide)

## Goals
- Skins control only visuals: full-window background + artwork/overlay inside the middle content bounds.
- Lyrics are hosted by the app and never rendered by skins.
- Adding a new skin should be: create a file + register one line in `SkinRegistry`.

## Architecture
- `SkinContext` is read-only data passed to skins.
- `NowPlayingSkin` protocol defines three layers:
  - `makeBackground(context)` → full window background.
  - `makeArtwork(context)` → artwork in middle content bounds.
  - `makeOverlay(context)` → optional decoration in middle content bounds.
- `SkinRegistry` holds all available skins and the default ID.
- `SkinManager` persists the selected skin via `AppStorage` and exposes the active skin.
- `NowPlayingHostView` renders:
  1) background full-window
  2) artwork + overlay clipped to content bounds (middle area)
  3) lyrics panel (hosted outside skin)
  4) mini player (hosted outside skin)

## Content Bounds
- `contentBounds` excludes the lyrics panel and the mini player height.
- Skins should align artwork/decoration inside `contentBounds` and avoid drawing outside.

## Add a New Skin
1) Create a new file in `myPlayer2/Skins/NowPlaying/` (e.g. `MySkin.swift`).
2) Implement `NowPlayingSkin`.
3) Register in `SkinRegistry.skins` by adding one line.

Example:
```swift
struct MySkin: NowPlayingSkin {
    let id = "mySkin"
    let name = "My Skin"
    let detail = "Custom visuals"
    let systemImage = "sparkles"

    func makeBackground(context: SkinContext) -> AnyView {
        AnyView(Color.black.ignoresSafeArea())
    }

    func makeArtwork(context: SkinContext) -> AnyView {
        AnyView(Text("Artwork"))
    }
}
```

## Audio Metrics
Skins can access `context.audio`:
- `rms`, `peak`, `db`
- `bands`, `smoothedBands`
- `smoothedLevel`, `bassEnergy`
- `waveform`

## Notes
- Do not render lyrics in skins.
- Do not drive playback from skins.
- Keep animations respectful of Reduce Motion.

## Apple Style Skin
- `AppleStyleSkin` is the AMLL Mesh Gradient skin. It is registered for both window now playing and fullscreen now playing with the display name `Apple 风格`.
- The skin background is hosted by `AMLLMeshGradientBackgroundView`, which loads `Resources/AMLL/background.html` and the independent `amll-background.js` bundle. Do not add Mesh Gradient imports to the lyric `amll-core.js` bundle.
- The skin foreground reuses the classic cover/LED/spectrum artwork view. Window mode does not change lyrics styling.
- Fullscreen mode keeps the classic fullscreen placement/layout, but its AMLL lyric rendering path must reuse the mature fullscreen cover blur generic lyric system with a fixed `lighter` profile. Apple style does not maintain separate opacity, interlude dot, catch-up, or exit-fade CSS.
- Fullscreen Apple lyrics use `plus-lighter` compositing and theme-derived bright colors. They do not use cover blur's light/dark auto switching, `plus-darker`, or the cover blur background.
- Shared settings:
  - `skin.appleStyle.dynamicBackgroundEnabled`: pauses the renderer and releases the Apple background audio consumer when off.
  - `skin.appleStyle.flowSpeed`: `gentle`, `standard`, or `active`.
- Background parameters:
  - `gentle`: `flowSpeed 0.18`, `30 FPS`.
  - `standard`: `flowSpeed 0.32`, `30 FPS`.
  - `active`: `flowSpeed 0.55`, `60 FPS`.
  - render scale is fixed at `0.6`; do not add a clarity slider unless the skin design is revisited.
- Audio sampling is an independent consumer of `AudioVisualizationService.shared`. It may share the underlying analysis hub with LED/spectrum, but must not depend on their toggles and must remove only its own consumer when hidden, disabled, or disposed.

### Apple Style Debugging and Visual Constraints
- `AMLLMeshGradientBackgroundView` must treat the `backgroundReady` script message as the only renderer-ready signal. `WKNavigationDelegate.didFinish` only proves `background.html` loaded; it does not prove the module import, renderer construction, fallback album, or canvas insertion succeeded.
- The background WKWebView must allow file URL access to the local `AMLL` resource directory so `background.html` can import `amll-background.js`.
- `background.html` owns a non-black CSS fallback and a generated fallback album image. Missing artwork should still produce a visible Mesh Gradient-like field instead of a pure black surface.
- The host view should keep a Swift fallback behind the WebView, not a solid black background. A black fallback makes import or renderer failures indistinguishable from a valid but dark frame.
- Fullscreen Apple lyrics intentionally differ from the classic fullscreen skin by reusing cover blur's tested generic lyric path: `coverBlurFullscreenGenericMode=true`, `coverBlurFullscreenGenericProfile=lighter`, and `plus-lighter` at the WebView layer. Do not add Apple-only opacity selector patches; they previously caused stale interlude dots and diverged exit/catch-up behavior.
- Skin changes that alter fullscreen lyric semantics must force-reapply the fullscreen lyrics config/theme immediately. The quick settings skin picker and the full settings page must both land on the same `LyricsWebViewStore` config refresh path.
- The Apple skin preview card must stay consistent with other skin cards: single-color line/fill treatment, simplified geometry, and no colorful mesh-poster artwork. It should symbolize fluid motion with abstract curves plus the classic cover shape.
