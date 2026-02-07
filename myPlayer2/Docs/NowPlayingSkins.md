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
