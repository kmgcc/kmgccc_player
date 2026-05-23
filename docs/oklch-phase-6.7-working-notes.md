# Phase 6.7 Working Notes

## Already Fixed (Do Not Touch)
- Track-change default color flash (Phase 6.6)
- MiniPlayer foreground strategy (Phase 6.4)
- Daytime Artistic background brightening (Phase 6.4)
- nearMono warm residual → cool neutral rotation (Phase 6.6)
- lowSatColorCover fgB/dotB boost gated to isDark (Phase 6.6)

## Fixed 4 Issues (Phase 6.7 Complete)
A. nearMono Art Shapes still pink — fixed with preset palette
B. Light Artistic BK1/BK2 still dims on UltraDark cover — fixed
C. Light Artistic inactive lyrics need slightly brighter — fixed
D. Paused vs playing fullscreen color identity differs — fixed

## Audit Plan
1. nearMono shape hue source in BKColorEngine
2. BK1/BK2 brightness source in day path
3. Light inactive lyrics ladder source
4. Paused/playing fullscreen color path divergence

## Modified Files (this phase)
- `myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift`
  - Fix D: removed `deferredPaletteUpdate` / `shouldFreezeVisualUpdates` gate from `updatePalette`
  - Fix B: gated `ultraDarkOverlay` to `harmonized.isDark`
- `myPlayer2/Views/NowPlaying/BKColorEngine.swift`
  - Fix A: added `nearMonoShapePreset` with pale cyan-blue, yellow, mint, sky
  - Fix A: `neutraliseShapes` path now uses preset for `shapePoolOut`
- `myPlayer2/Utilities/ColorSystemTokens.swift`
  - Fix C: bumped light inactive lyrics L by +0.030

## Verification Status
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`：PASS
- `COLOR_SYSTEM_SELF_CHECK=1`：`Result: ALL PASS`
- 退出状态（2026-05-23）：Phase 6.7 全部修复完成，build + self-check 通过。最终验收仍以真实封面手测矩阵为准。
