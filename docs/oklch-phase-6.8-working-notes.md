# Phase 6.8 Working Notes

## Context
Continuing Phase 6 OKLCH color system fixes on branch `refactor/oklch-color-system`.

## Step 1 Audit — Root Cause of Near-Mono Pink Leak (COMPLETE)

### Finding A: `grayscaleTrue` early return bypasses `neutraliseShapes`
- In `BKColorEngine.make(extracted:fallback:isDark:analysis:)` lines 141-159, when `stats.coverKind == .grayscaleTrue`, the method returns `makeGrayscalePalette(...)` immediately.
- The `neutraliseShapes` block (lines 346-371) is never reached.
- `makeGrayscalePalette` uses `safeHueBase: 215` (blue) for shapes, which is better than pink, but the downstream `BKArtBackgroundView.applyStyle` / `retintShapes` calls `makeShapeSwatches`, which can still pick pink from extracted pixels.

### Finding B: `makeShapeSwatches` has zero nearMono awareness
- `makeShapeSwatches(seed:extracted:fallback:isDark:)` ranks raw extracted colors by saliency (`pow(color.s, 1.25) * (0.55 + 0.45 * midBBoost)`).
- For near-mono covers, residual magenta/pink pixels in the extracted set can outrank others purely by saliency, and get elevated into the shape pool.
- `BKArtBackgroundView.applyStyle` (lines 1048-1054) and `retintShapes` (lines 1324-1330) both call `makeShapeSwatches` and override `harmonized.shapePool` with its result unconditionally when `swatchResult.colors` is non-empty.
- `analysis` is passed into `applyResolvedPalette` but is NOT persisted as a `@State` property on the view, so it cannot be forwarded to `makeShapeSwatches`.

### Answer to User Question
> "用户看到粉色时，nearMono 到底有没有触发；如果触发了，粉色是哪条 shape 颜色路径带进去的。"

When the user sees pink on a near-mono cover, nearMono **does** trigger in `BKColorEngine.make()` (the `neutraliseShapes` flag becomes true), but the preset palette is **subsequently overwritten** by `makeShapeSwatches` in `BKArtBackgroundView.applyStyle` / `retintShapes`. The pink comes from residual magenta pixels in the raw extracted palette that `makeShapeSwatches` elevates via saliency scoring.

For `grayscaleTrue` covers, `neutraliseShapes` is never reached at all, so `makeGrayscalePalette`'s blue shapes are used, but `makeShapeSwatches` can still reintroduce pink downstream.

## Fix Strategy (Steps 2-5) — COMPLETE

### Step 2: Fix Near Mono shape preset palette — DONE
- `BKColorEngine.makeShapeSwatches` now accepts `analysis: ArtworkColorAnalysis? = nil`.
- Early return yields `nearMonoShapePreset` directly when `analysis?.isNearMonochrome == true`, bypassing saliency scoring.
- `BKArtBackgroundView` stores `currentAnalysis` and passes it through `BKArtBackgroundRepresentable` → `BKArtBackgroundLayerView` → `BKColorEngine.make` / `makeShapeSwatches`.
- `grayscaleTrue` early return in `BKColorEngine.make()` now reconstructs `HarmonizedPalette` with `nearMonoShapePreset` for `shapePool` and `neutraliseCGColor` for `bgStops`/`dotBase`/`bgVariants` when `neutraliseShapes` is true.

### Step 3: Queue Card foreground strategy — DONE
- Replaced hardcoded skin list in `FullscreenPlayerView.fullscreenQueueUsesBrightTextPalette` with `fullscreenMiniPlayerForegroundProfile.useScreenBlend`.
- Queue card text palette now matches the MiniPlayer's foreground judgment.

### Step 4: Brighten Cover Blur / Cover Gradient MiniPlayer light profile — DONE
- Added `coverBlurLightProfile(role:palette:enforceBrightProgressForeground:)` in `FullscreenMiniPlayerForegroundStrategy`.
- Uses `palette.coverGradientText` (lightness ~0.94) instead of `palette.miniPlayerControl.primary`.
- `.appleFixedLight`, `.artisticNightLightForeground`, and `.chromeLightForeground` continue to use the original `lightProfile`.

### Step 5: Slightly reduce light Artistic ArtBK brightness — DONE
- Light mode `lumaTarget` max reduced from `0.985` → `0.975`.
- Light `bgB` upper bound reduced from `1.000` → `0.995`.
- Dark mode untouched.

## Verification Checklist
- [x] Build: `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build` → **SUCCEEDED**
- [x] Self-check: `COLOR_SYSTEM_SELF_CHECK=1` → **Result: ALL PASS**
- [ ] Manual: near-mono cover shows preset cyan-blue/yellow/mint/sky shapes, no pink
- [ ] Manual: queue card text color matches MiniPlayer foreground decision
- [ ] Manual: cover blur MiniPlayer light profile is brighter than Apple light profile
- [ ] Manual: light Artistic background is slightly less blinding on bright covers
