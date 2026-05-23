# Phase 6.9 Working Notes — Cover Blur MiniPlayer Gray Controls Investigation

## Context
Continuing Phase 6 OKLCH color system fixes on branch `refactor/oklch-color-system`.

## Step 1 Audit — Root Cause of Cover Blur MiniPlayer Gray/Semi-Transparent Controls (COMPLETE)

### User-Reproduced Symptom
On bright covers with Cover Blur fullscreen skin:
- Title/artist text renders correctly (dark foreground).
- Controls (play/prev/next), order pill, left/right buttons, and volume appear gray/semi-transparent instead of dark.
- Hover during **playback** temporarily restores correct colors.
- Hover during **paused** does NOT restore colors.
- Volume **never** restores correct colors.

---

### Component Profile Mapping

| Component | Profile Source | Blend Mode | `.compositingGroup()` |
|---|---|---|---|
| **Title/Artist** (`FullscreenMiniPlayerLeftSection`) | `lyricsDynamicPrimaryColor` / `lyricsDynamicSecondaryColor` (pre-resolved `Color`) | None (`.normal` implicit) | **No** |
| **Controls** (`controlsView` in `FullscreenMiniPlayerView`) | `resolvedForegroundProfile.primary` → `Color(nsColor:).opacity(0.96)` | `resolvedForegroundProfile.iconBlendMode` | **Yes** |
| **Order Pill** (`PlaybackModeSlider` in `playbackModeView`) | `controlPrimaryColor` for icons; `fullscreenControlPillTintColor` for pill | `pillTintBlendMode: .normal` (pill); `.screen` via `useScreenBlend` | **Yes** (track/knob) |
| **Progress/Spectrum** (`MiniPlayerProgressSpectrumRow`) | `foregroundColor` parameter (passed from parent) | None for progress/time; spectrum is `NSViewRepresentable` | **No** (progress); N/A (spectrum CALayer) |
| **Left/Right Buttons** (`leadingControlsPill` in `FullscreenPlayerView`) | `fullscreenMiniPlayerForegroundProfile.primary` | `fullscreenMiniPlayerIconBlendMode` | **Yes** |
| **Volume** (`ExpandableVolumeControl`) | `foregroundProfile.primary` if passed, else `themeStore.semanticPalette` | `foregroundProfile.iconBlendMode` if passed | **Yes** (icon + slider) |

**Cover Blur bright-cover path:**
- `FullscreenMiniPlayerForegroundStrategy.resolve()` → `shouldUseDarkArtworkForeground(for:)` returns `true` → `darkOnArtworkProfile(...)`
- Profile: `role: .coverBlurDarkForeground`, `primary: palette.readabilityProfile.foregroundPrimary` (L≈0.12 dark charcoal), `iconBlendMode: .normal`, `useScreenBlend: false`

---

### Root Cause Finding: `Color(nsColor:)` + Implicit Animation + `.compositingGroup().blendMode()` = Stuck Gray Intermediate State

**The chain:**

1. **ThemeStore publishes animated palette changes.**  
   `ThemeStore.swift` lines 453–460:
   ```swift
   withAnimation(.easeInOut(duration: 0.20)) {
       semanticPalette = semantic
   }
   ```
   When the track changes and the new cover triggers a palette shift (e.g., from a dark-cover light-foreground profile to a bright-cover dark-foreground profile), this implicit animation propagates down the view tree.

2. **Controls compute `Color` from `NSColor` inside body.**  
   `FullscreenMiniPlayerView.swift` lines 417–418:
   ```swift
   private var controlPrimaryColor: Color {
       Color(nsColor: controlPrimaryNSColor).opacity(0.96)
   }
   ```
   `controlPrimaryNSColor` is an `NSColor` (AppKit). SwiftUI's animation engine cannot interpolate `NSColor` → `Color` transitions correctly. When the `foregroundProfile` struct changes during animation, SwiftUI attempts to animate the view's appearance but cannot smoothly interpolate the underlying color value. This leaves the view in a **stuck intermediate state** where the color appears gray/semi-transparent.

3. **`.compositingGroup().blendMode(...)` compounds the problem.**  
   Controls use `.compositingGroup()` + `.blendMode(...)` (`.screen` in the old profile, `.normal` in the new dark profile). The compositing group creates an offscreen rendering buffer. During the stuck animation, the buffer captures an intermediate blended state that looks gray. The blend mode change (screen → normal) further confuses the rendering pipeline because the offscreen buffer is computed with an inconsistent color+blend combination.

4. **Title/Artist is immune because it receives pre-resolved `Color` and is `Equatable`.**  
   `FullscreenMiniPlayerLeftSection` is passed `lyricsDynamicPrimaryColor` (a `Color`, not `NSColor`) and uses `.equatable()`. SwiftUI treats it as identity-based and skips the problematic interpolation, so it snaps directly to the correct final color.

5. **Progress/Spectrum is immune because it does NOT use `.compositingGroup().blendMode()`.**  
   The progress fill and time colors are applied directly without compositing group isolation, so even if the color transitions, it doesn't get trapped in an offscreen buffer.

---

### Why Hover/Playback Restores, Paused Doesn't, Volume Never Does

| Scenario | Explanation |
|---|---|
| **Hover during playback restores** | The `MiniPlayerSpectrumView` (CALayer-based) animates continuously during playback, and `MiniPlayerProgressSpectrumRow` updates every frame from `playbackCoordinator.presentation.currentTime`. These high-frequency forced re-renders cause SwiftUI to re-evaluate `controlPrimaryColor` continuously, effectively "snapping" the color out of the stuck animation state. |
| **Hover during paused does NOT restore** | When paused, the spectrum collapses to `pausedBehavior: .minimalDots` (static). The progress bar stops updating. Without continuous re-renders, the stuck intermediate animation state persists. Hover only triggers layout changes (`isRowHovered`), not color-resolving re-renders. |
| **Volume NEVER restores** | `ExpandableVolumeControl` has no continuous animation or data source that forces re-renders. It only updates when `volume` or `isExpanded` changes. Absent user interaction, it remains stuck in the gray intermediate state indefinitely. |

---

### Summary

The gray/semi-transparent appearance is **not** a profile logic bug (the correct `darkOnArtworkProfile` IS being computed and passed). It is a **SwiftUI rendering/animation artifact** caused by:

1. `withAnimation` on `semanticPalette` changes in `ThemeStore`.
2. Controls computing `Color(nsColor: NSColor)` inside `body`, which SwiftUI cannot interpolate during animation.
3. `.compositingGroup().blendMode(...)` trapping the view in an offscreen buffer with an inconsistent intermediate color+blend state.
4. Views without `.compositingGroup()` (title/artist, progress) or with `.equatable()` isolation (title/artist) are unaffected.

---

## Fix Applied (Step 2)

Implemented a hybrid of **Option A + Option C**:

### Change 1: `ThemeStore.swift` (lines 452–463)
Moved `semanticPalette = semantic` **outside** the `withAnimation(.easeInOut(duration: 0.20))` block.

```swift
withAnimation(.easeInOut(duration: 0.20)) {
    baseColor = Color(nsColor: rawDominantColor)
    accentColor = Color(nsColor: resolvedAccentNS)
    accentNSColor = resolvedAccentNS
    artworkBaseNSColor = rawDominantColor
    selectionFill = Color(nsColor: resolvedAccentNS).opacity(fillAlpha)
}
// Phase 6.9: semanticPalette must snap instantly. Animating it causes
// MiniPlayer controls that compute Color(nsColor:) inside body to get
// trapped in a stuck intermediate state when combined with
// .compositingGroup().blendMode(...).
semanticPalette = semantic
```

**Rationale:** `semanticPalette` is a complex struct consumed by many views. When `ThemeStore` animates its publication, SwiftUI propagates an implicit animation transaction down the view tree. Views that compute `Color(nsColor: NSColor)` inside `body` and use `.compositingGroup().blendMode(...)` cannot correctly interpolate the `NSColor`-derived `Color` during animation, causing a stuck gray intermediate state. Removing the animation on `semanticPalette` makes color updates snap instantly across the app, which is the correct behavior for artwork-driven theming.

The other properties (`baseColor`, `accentColor`, etc.) remain inside the `withAnimation` block because they are native SwiftUI `Color` values that interpolate correctly.

### Change 2: `FullscreenPlayerView.swift` (MiniPlayer + Volume)
Added `.transaction { $0.animation = nil }` to both `FullscreenMiniPlayerView` and `ExpandableVolumeControl`.

```swift
FullscreenMiniPlayerView(...)
    // ... modifiers ...
    .transaction { $0.animation = nil }
    .environment(\.colorScheme, fullscreenControlsGlassStyle.colorScheme)

ExpandableVolumeControl(...)
    // ... modifiers ...
    .transaction { $0.animation = nil }
    .environment(\.colorScheme, fullscreenControlsColorScheme)
```

**Rationale:** Belt-and-suspenders defense. Even if some other ancestor introduces an implicit animation, the MiniPlayer subtree will not participate in it. Explicit layout animations (e.g., `isPlaybackModeExpanded`, `isVolumeExpanded`) are driven by `.animation(_, value:)` on the specific state and are not affected because they create their own scoped transactions.

---

## Verification Checklist
- [x] Build passes (`xcodebuild ... build` → **BUILD SUCCEEDED**).
- [x] Self-check passes (`COLOR_SYSTEM_SELF_CHECK=1` → **Result: ALL PASS**).
- [ ] Manual: Cover Blur bright cover — all controls show dark foreground immediately, no gray intermediate state.
- [ ] Manual: Cover Blur dark cover — controls show light foreground (screen blend) immediately.
- [ ] Manual: Hover expand/collapse animations remain smooth.
- [ ] Manual: Track switch animation feels natural (no jarring color snap).
- [ ] Manual: Volume control correct on both bright and dark covers.
