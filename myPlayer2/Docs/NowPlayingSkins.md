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
- Fullscreen mode reuses the classic fullscreen layout, but its AMLL lyrics config enables `fullscreenAppleStyleMode`: bright theme-derived colors plus opacity tiers, without cover blur's light/dark profile switching.
- Shared settings:
  - `skin.appleStyle.dynamicBackgroundEnabled`: pauses the renderer and releases the Apple background audio consumer when off.
  - `skin.appleStyle.flowSpeed`: `gentle`, `standard`, or `active`.
- Background parameters:
  - `gentle`: `flowSpeed 0.18`, `30 FPS`.
  - `standard`: `flowSpeed 0.32`, `30 FPS`.
  - `active`: `flowSpeed 0.55`, `60 FPS`.
  - render scale is fixed at `0.6`; do not add a clarity slider unless the skin design is revisited.
- Audio sampling is an independent consumer of `AudioVisualizationService.shared`. It may share the underlying analysis hub with LED/spectrum, but must not depend on their toggles and must remove only its own consumer when hidden, disabled, or disposed.
