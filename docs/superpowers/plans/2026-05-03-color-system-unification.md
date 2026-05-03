# 全局取色与语义角色色统一改造 / Color System Unification Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把当前散落在 ArtworkColorExtractor / ThemeStore / BKColorEngine / 各 View 里的取色逻辑收敛到一套"封面分析 → 语义角色色"双层结构；统一所有模块的颜色输入源，但保留各自最终视觉风格。同时修正深色 accent 偏暗、重要图标 opacity 不为 1、浅色歌词缺少色相、异常封面取色（黑白封面出粉、偏黄出蓝）、BKArt 饱和度被洗灰等具体问题。

**Architecture:** 引入 `ArtworkColorAnalysis`（封面统计：HSL/HSB 维度的均值、方差、colorfulness、isMonochrome、dominantHueConfidence）+ `SemanticPalette`（按 role 命名的 NSColor 集合：globalAccent / readableTextOnArtwork / ambientSurface / artBackgroundPrimary / fullscreenLyricActive 等）。所有派生层（accent 优化、歌词色、BKArt 背景、Home Hero、CoverGradientBlur、Toolbar 图标）都从同一个 analysis 派生，不再各自从 NSImage 重新跑算法。`ThemeStore` 退化为状态分发器 + 持有 cache，不再做 HSL 计算。

**Tech Stack:** Swift 6, AppKit (NSColor / CGImage), SwiftUI, SwiftData, AVAudioEngine. macOS 26+. 已有 `ArtworkColorExtractor` 的像素采样代码保留复用；新增的是更高层的 `ArtworkColorAnalysis` / `SemanticPaletteFactory`。

**Risk control:** 改造分 12 个 phase，每个 phase 单独 build & 视觉检查可通过；高风险模块（fullscreen lyrics override、BKColorEngine、AMLL palette 时序）放在最后；玻璃材质/Liquid Glass 观感、布局、动画严格不动。

---

## File Structure / 文件分布

### 新增文件 (Create)
- `myPlayer2/Utilities/ArtworkColorAnalysis.swift` — 统计型分析结构 + 计算入口
- `myPlayer2/Utilities/SemanticPalette.swift` — 语义角色色结构 + factory
- `myPlayer2/Utilities/ColorMath.swift` — HSL/HSB/contrast 共享算子（去重 ThemeStore + ArtworkColorExtractor 里的重复 helper）

### 修改文件 (Modify)
- `myPlayer2/Utilities/ArtworkColorExtractor.swift` — 暴露 analysis 入口、修正 dominant 选择策略、调整 light-mode adjustedAccent
- `myPlayer2/Services/Theme/ThemeStore.swift` — 改为持有 `ArtworkColorAnalysis` + `SemanticPalette`，删除 `optimizeAccentColor`/`enforceMinimumLightnessForDarkMode`（迁到 SemanticPalette）
- `myPlayer2/Views/Controls/GlassToolbarControls.swift` — 重要图标 opacity 改 1.0
- `myPlayer2/Views/Lyrics/LyricsPanelView.swift` — 浅色歌词读 SemanticPalette 的 windowLyricActive/Inactive
- `myPlayer2/Views/Home/HomeHeroView.swift` — 改读 SemanticPalette.coverSurface 子集
- `myPlayer2/Views/Home/HomeAmbientShapesBackground.swift` — sourceColor 改读 SemanticPalette.ambientSurface
- `myPlayer2/Skins/NowPlaying/CoverGradientBlurBackgroundView.swift` — dominantColor 改读 SemanticPalette.coverGradientDominant
- `myPlayer2/Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift` — palette 输入改读统一 surface
- `myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift` — initialPalette / extracted palette 改读 analysis
- `myPlayer2/Views/NowPlaying/BKColorEngine.swift` — 接受 analysis，按 colorfulness/isMonochrome 决定饱和带宽
- `myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift` — `resolveFullscreenLyricsBaseColor` / `resolveFullscreenLyricsInactiveBaseColor` 改读 SemanticPalette；HSL 调色管道**完全保留**

### 不动文件 (Preserve as-is)
- `myPlayer2/Views/Library/BlurredArtworkBackgroundView.swift` — 直接拿封面图 blur，无取色环节
- `myPlayer2/Views/Library/LibraryDetailHeaderView.swift` — Library Halo，封面驱动，不受 accent 影响
- `myPlayer2/Utilities/GlassPillView.swift` / `GlassStyleTokens.swift` — 玻璃 token 不动
- `myPlayer2/Resources/AMLL/*` — Web 资源不动
- `myPlayer2/Services/Lyrics/LyricsWebViewStore.swift` — palette CSS 透传层不动（仅核对一致性）
- AMLL palette override 时序不动（Phase 11 只换输入源）

---

## 核心数据结构 (Reference) / Core Data Types

下面是 plan 中各 phase 引用的目标结构。具体步骤里会重复给出实际代码，不要从这里 copy。

```swift
// Utilities/ArtworkColorAnalysis.swift
struct ArtworkColorAnalysis: Equatable, Sendable {
    // Aggregate HSB/HSL stats
    let avgHue: CGFloat               // [0,1) circular
    let dominantHue: CGFloat
    let dominantHueConfidence: CGFloat // 主 hue bucket 占比 [0,1]
    let avgSaturation: CGFloat
    let avgBrightness: CGFloat        // HSB
    let avgHslLightness: CGFloat      // HSL
    let saturationVariance: CGFloat
    let lightnessVariance: CGFloat

    // Derived properties
    let colorfulness: CGFloat         // 0..1, vivid 区域加权占比
    let isMonochrome: Bool            // colorfulness < 0.04 && avgSaturation < 0.10
    let hasStrongAccentRegion: Bool   // 存在 area >= 0.18 && saturation >= 0.50 的 hue bucket
    let usesDarkForeground: Bool      // = avgHslLightness >= 0.58 (沿用现有 textPalette 判定)

    // Raw artwork-derived colors (still in cover space, NOT yet adjusted for UI)
    let dominantColor: NSColor        // 主 hue bucket 的中心 RGB
    let averageColor: NSColor         // 全图加权平均
    let topPalette: [NSColor]         // 去重后 3-4 个主色（uiThemePalette 输出）
    let richPalette: [NSColor]        // 5-8 个艺术色（uiThemePaletteRich 输出）
    let bestTextSourceColor: NSColor  // textSourceColor() 输出（最具色相的文字基色）
}

// Utilities/SemanticPalette.swift
struct SemanticPalette: Equatable, Sendable {
    let scheme: ColorScheme
    let analysis: ArtworkColorAnalysis

    // UI tint
    let globalAccent: NSColor             // 唯一 ThemeStore 对外暴露的 accent
    let uiAccentOnDark: NSColor           // hue 沿用，L 提到 0.66–0.78
    let uiAccentOnLight: NSColor          // hue 沿用，L 压到 0.28–0.50

    // Surface
    let ambientSurface: NSColor           // Home shapes, neutral with mild tint
    let artBackgroundPrimary: NSColor     // BKArt 主背景（受 colorfulness 调制）
    let artBackgroundSecondary: NSColor   // BKArt 次背景

    // Text on artwork
    let readableTextOnArtwork: NSColor    // 主文本 (Home Hero / Cover Gradient Blur 上的文字)
    let secondaryTextOnArtwork: NSColor

    // Window-mode lyrics (LyricsPanelView)
    let windowLyricActive: NSColor        // dark: near-white tinted；light: tinted dark ink (L 0.18–0.28)
    let windowLyricInactive: NSColor

    // Fullscreen lyrics (only used as input to FullscreenPlayerView's HSL pipeline)
    let fullscreenLyricBase: NSColor      // 喂给 resolveFullscreenLyricsBaseColor 的 hue/sat 来源
    let fullscreenLyricInactiveBase: NSColor

    // Cover-driven gradients
    let coverGradientDominant: NSColor    // CoverGradientBlur overlay tint
    let coverGradientText: NSColor        // 全屏 cover blur skin 上的文字色
}
```

---

## Phase 0 — Foundation: shared color math
**风险等级:** 极低（纯重构，无行为变化）

去重 `ArtworkColorExtractor.swift:53-61` 与 `ThemeStore.swift:536-545` 的 FNV-1a checksum，以及 HSL ↔ RGB 转换。

### Task 0.1 — Create `ColorMath.swift`

**Files:**
- Create: `myPlayer2/Utilities/ColorMath.swift`

- [ ] **Step 1: 创建 ColorMath.swift**

```swift
//
//  ColorMath.swift
//  myPlayer2
//
//  Shared HSL/HSB/contrast helpers used by ArtworkColorExtractor,
//  ThemeStore, SemanticPaletteFactory, and BKColorEngine.
//

import AppKit

enum ColorMath {
    static func fnv1a(_ data: Data) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        data.withUnsafeBytes { rawBuffer in
            for byte in rawBuffer {
                hash ^= UInt64(byte)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }

    static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(hi, Swift.max(lo, v))
    }

    static func normalizedHue(_ value: CGFloat) -> CGFloat {
        var h = value.truncatingRemainder(dividingBy: 1)
        if h < 0 { h += 1 }
        return h
    }

    static func circularHueDistance(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
        let d = abs(a - b)
        return Swift.min(d, 1 - d)
    }

    /// Convert NSColor (deviceRGB) to HSL components (h in [0,1)).
    static func hsl(of color: NSColor) -> (h: CGFloat, s: CGFloat, l: CGFloat) {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = rgb.redComponent, g = rgb.greenComponent, b = rgb.blueComponent
        let maxV = max(r, max(g, b))
        let minV = min(r, min(g, b))
        let l = (maxV + minV) * 0.5
        let delta = maxV - minV
        if delta < 0.000_001 { return (0, 0, l) }
        let s = l > 0.5 ? delta / (2 - maxV - minV) : delta / (maxV + minV)
        var h: CGFloat
        if maxV == r {
            h = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            h = ((b - r) / delta) + 2
        } else {
            h = ((r - g) / delta) + 4
        }
        h /= 6
        if h < 0 { h += 1 }
        return (h, s, l)
    }

    /// HSL → NSColor (deviceRGB).
    static func color(h: CGFloat, s: CGFloat, l: CGFloat, alpha: CGFloat = 1) -> NSColor {
        let c = (1 - abs(2 * l - 1)) * s
        let hPrime = h * 6
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2) - 1))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        switch hPrime {
        case 0..<1: r = c; g = x
        case 1..<2: r = x; g = c
        case 2..<3: g = c; b = x
        case 3..<4: g = x; b = c
        case 4..<5: r = x; b = c
        default:    r = c; b = x
        }
        let m = l - c * 0.5
        return NSColor(
            calibratedRed: clamp(r + m, 0, 1),
            green: clamp(g + m, 0, 1),
            blue: clamp(b + m, 0, 1),
            alpha: alpha
        )
    }

    /// Returns the NSColor with its HSL lightness clamped to [lo, hi], hue and saturation preserved.
    static func clampLightness(_ color: NSColor, lo: CGFloat, hi: CGFloat) -> NSColor {
        let comp = hsl(of: color)
        let target = clamp(comp.l, lo, hi)
        if abs(target - comp.l) < 0.001 { return color }
        return self.color(h: comp.h, s: comp.s, l: target)
    }

    /// Returns the NSColor with HSL saturation clamped, hue and lightness preserved.
    static func clampSaturation(_ color: NSColor, lo: CGFloat, hi: CGFloat) -> NSColor {
        let comp = hsl(of: color)
        let target = clamp(comp.s, lo, hi)
        if abs(target - comp.s) < 0.001 { return color }
        return self.color(h: comp.h, s: target, l: comp.l)
    }

    static func relativeLuminance(of color: NSColor) -> CGFloat {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        func lin(_ c: CGFloat) -> CGFloat {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(rgb.redComponent)
             + 0.7152 * lin(rgb.greenComponent)
             + 0.0722 * lin(rgb.blueComponent)
    }
}
```

- [ ] **Step 2: Build to confirm new file compiles**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
    -configuration Debug -destination 'platform=macOS' build \
    2>&1 | tail -40
```

Expected: BUILD SUCCEEDED, no warnings about ColorMath.

- [ ] **Step 3: Commit**

```bash
git add myPlayer2/Utilities/ColorMath.swift
git commit -m "refactor(color): extract shared HSL/HSB/contrast helpers"
```

### Task 0.2 — Replace duplicated checksum / HSL helpers

**Files:**
- Modify: `myPlayer2/Utilities/ArtworkColorExtractor.swift:53-61, 694-697, 799-803, 805-811`
- Modify: `myPlayer2/Services/Theme/ThemeStore.swift:472-545, 558-560`

- [ ] **Step 1: ArtworkColorExtractor — replace `computeChecksum` body with `ColorMath.fnv1a`**

In `ArtworkColorExtractor.swift:53-61`, replace body of `computeChecksum` to call `ColorMath.fnv1a`:

```swift
private nonisolated static func computeChecksum(_ data: Data) -> UInt64 {
    ColorMath.fnv1a(data)
}
```

- [ ] **Step 2: ArtworkColorExtractor — replace `circularHueDistance`, `normalizedHue`, `clamp`, `relativeLuminance(of:)`**

Delete the bodies at lines 694-697, 799-803, 805-811, and `relativeLuminance(of:)` at 777-784. Replace each call site within the file with `ColorMath.<fn>`.

(Keep the `relativeLuminance(red:green:blue:)` overload at lines 786-797 — it has a different signature and is still used by `textPalette` line 454.)

- [ ] **Step 3: ThemeStore — replace `computeChecksum`, `clamp`, `enforceMinimumLightnessForDarkMode`**

In `ThemeStore.swift`:
- Lines 536-545: replace body with `ColorMath.fnv1a(data)`.
- Lines 558-560 (file-private clamp): delete; use `ColorMath.clamp` at all call sites in this file.
- Lines 472-534 (`enforceMinimumLightnessForDarkMode`): replace whole body with `ColorMath.clampLightness(color, lo: Self.darkModeMinimumThemeLightness, hi: 1.0)`.

- [ ] **Step 4: Build & spot-check**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
    -configuration Debug build 2>&1 | tail -40
```

Run the app, switch tracks, confirm accent colors look unchanged (this is a pure refactor).

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "refactor(color): consolidate duplicated HSL/checksum helpers into ColorMath"
```

---

## Phase 1 — `ArtworkColorAnalysis`: rich statistical profile
**风险等级:** 低（新增结构，无消费者）

把现有 `uiThemePalette` 内部计算的统计量（avgSaturation / avgBrightness / vividness / dominantHue 等）提取并扩充为可复用的 `ArtworkColorAnalysis`。这是后续所有派生层的唯一输入源。

### Task 1.1 — Create `ArtworkColorAnalysis.swift`

**Files:**
- Create: `myPlayer2/Utilities/ArtworkColorAnalysis.swift`

- [ ] **Step 1: 创建结构与 factory**

```swift
//
//  ArtworkColorAnalysis.swift
//  myPlayer2
//
//  Single statistical analysis over an artwork. All semantic role colors
//  (ThemeStore accent, BKArt background, lyrics colors, Home Hero text)
//  derive from this structure rather than re-running pixel sampling.
//

import AppKit

struct ArtworkColorAnalysis: Equatable, Sendable {
    let avgHue: CGFloat
    let dominantHue: CGFloat
    let dominantHueConfidence: CGFloat
    let avgSaturation: CGFloat
    let avgBrightness: CGFloat
    let avgHslLightness: CGFloat
    let saturationVariance: CGFloat
    let lightnessVariance: CGFloat
    let colorfulness: CGFloat
    let isMonochrome: Bool
    let hasStrongAccentRegion: Bool
    let usesDarkForeground: Bool

    let dominantColor: NSColor
    let averageColor: NSColor
    let topPalette: [NSColor]
    let richPalette: [NSColor]
    let bestTextSourceColor: NSColor

    static let neutralFallback = ArtworkColorAnalysis(
        avgHue: 0.10,
        dominantHue: 0.10,
        dominantHueConfidence: 0,
        avgSaturation: 0.18,
        avgBrightness: 0.62,
        avgHslLightness: 0.62,
        saturationVariance: 0,
        lightnessVariance: 0,
        colorfulness: 0,
        isMonochrome: true,
        hasStrongAccentRegion: false,
        usesDarkForeground: true,
        dominantColor: NSColor(calibratedRed: 1.0, green: 200/255, blue: 120/255, alpha: 1),
        averageColor: NSColor(calibratedRed: 1.0, green: 200/255, blue: 120/255, alpha: 1),
        topPalette: [],
        richPalette: [],
        bestTextSourceColor: NSColor(calibratedRed: 0.20, green: 0.20, blue: 0.22, alpha: 1)
    )
}

extension ArtworkColorExtractor {
    /// Single full analysis pass. Reuses the cached pixel buffer from `sampledBitmap`.
    public nonisolated static func analyze(from data: Data) -> ArtworkColorAnalysis? {
        guard let sample = sampledBitmap(from: data, side: 64) else { return nil }
        return analyzeInternal(sample: sample, data: data)
    }
}
```

- [ ] **Step 2: Implement `analyzeInternal(sample:data:)` in same file**

Add a fileprivate function that walks `sample.pixels` once, accumulates:
- 48-bucket hue histogram (alpha-weighted, with sat<0.04 ⇒ weight×0.82, identical weighting as `uiThemePalette` lines 240-261 so we don't change extractor behaviour here)
- weighted sums for: hue (circular mean via sin/cos), saturation, brightness, HSL lightness, vividWeight
- `M2` accumulator for variance: per-pixel `(s - runningMean)² × weight`
- Per-bucket confidence = `bucket.weight / totalWeight`

Then derive:
```swift
let totalWeight = ...
let avgSat = satSum / totalWeight
let avgBri = briSum / totalWeight
let avgHslL = hslSum / totalWeight
let satVar = m2Sat / max(totalWeight, 1e-6)
let lightVar = m2L / max(totalWeight, 1e-6)
let colorfulness = ColorMath.clamp(vividWeight / totalWeight, 0, 1)
let isMono = colorfulness < 0.04 && avgSat < 0.10
let hasStrong = (largestBucket.weight / totalWeight) >= 0.18
              && saturationOf(largestBucket.color) >= 0.50
let domHueConf = sortedBuckets[0].weight / totalWeight
let dominantHue = sortedBuckets[0].centerHue
let avgHueAngle = atan2(hueSinSum, hueCosSum) / (2 * .pi)
let avgHue = ColorMath.normalizedHue(avgHueAngle)
let usesDark = avgHslL >= 0.58
```

Re-use the existing `uiThemePalette(from: sample, targetCount:)` and `uiThemePaletteRich(from: sample, targetCount:)` for `topPalette` / `richPalette` (no need to re-bucket).

```swift
let topPalette = uiThemePalette(from: sample, targetCount: 4)
let richPalette = uiThemePaletteRich(from: sample, targetCount: 8)
let bestText = textSourceColor(from: hueBuckets, fallback: averageColor(from: sample) ?? .gray)
```

`dominantColor` = top hue bucket's RGB centre (not yet tuned — this is the **raw** dominant, the SemanticPalette will tune it).

- [ ] **Step 3: Build**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
    -configuration Debug build 2>&1 | tail -40
```

- [ ] **Step 4: Commit**

```bash
git add myPlayer2/Utilities/ArtworkColorAnalysis.swift
git commit -m "feat(color): introduce ArtworkColorAnalysis with hue/sat/lightness statistics"
```

---

## Phase 2 — `SemanticPalette` factory + ThemeStore wiring (passive)
**风险等级:** 低（factory 行为完全等价于现有 ThemeStore.optimizeAccentColor / adjustedAccent，consumer 还没切换）

ThemeStore 改成持有 analysis + palette，但对外的 `accentColor` / `palette` 行为保持等价。这是后续 phase 切换 consumer 的接入点。

### Task 2.1 — Create `SemanticPalette.swift`

**Files:**
- Create: `myPlayer2/Utilities/SemanticPalette.swift`

- [ ] **Step 1: 结构定义**

```swift
import AppKit
import SwiftUI

struct SemanticPalette: Equatable, Sendable {
    let scheme: ColorScheme
    let analysis: ArtworkColorAnalysis

    // UI tint
    let globalAccent: NSColor
    let uiAccentOnDark: NSColor
    let uiAccentOnLight: NSColor

    // Surfaces
    let ambientSurface: NSColor
    let artBackgroundPrimary: NSColor
    let artBackgroundSecondary: NSColor

    // Text on artwork
    let readableTextOnArtwork: NSColor
    let secondaryTextOnArtwork: NSColor

    // Window-mode lyrics
    let windowLyricActive: NSColor
    let windowLyricInactive: NSColor

    // Fullscreen lyrics input (HSL pipeline downstream stays untouched)
    let fullscreenLyricBase: NSColor
    let fullscreenLyricInactiveBase: NSColor

    // Cover-driven
    let coverGradientDominant: NSColor
    let coverGradientText: NSColor
}

enum SemanticPaletteFactory {
    static func make(
        from analysis: ArtworkColorAnalysis,
        scheme: ColorScheme,
        userFallbackAccent: NSColor,
        useArtworkTint: Bool
    ) -> SemanticPalette {
        let isDark = scheme == .dark
        let globalAccent: NSColor
        if useArtworkTint {
            globalAccent = isDark
                ? Self.optimizedAccent(for: .dark, analysis: analysis)
                : Self.optimizedAccent(for: .light, analysis: analysis)
        } else {
            globalAccent = isDark
                ? ColorMath.clampLightness(userFallbackAccent, lo: 0.66, hi: 0.82)
                : ColorMath.clampLightness(userFallbackAccent, lo: 0.30, hi: 0.50)
        }

        return SemanticPalette(
            scheme: scheme,
            analysis: analysis,
            globalAccent: globalAccent,
            uiAccentOnDark: Self.optimizedAccent(for: .dark, analysis: analysis),
            uiAccentOnLight: Self.optimizedAccent(for: .light, analysis: analysis),
            ambientSurface: Self.ambientSurface(analysis: analysis, isDark: isDark),
            artBackgroundPrimary: Self.artBackgroundPrimary(analysis: analysis, isDark: isDark),
            artBackgroundSecondary: Self.artBackgroundSecondary(analysis: analysis, isDark: isDark),
            readableTextOnArtwork: Self.readableTextOnArtwork(analysis: analysis),
            secondaryTextOnArtwork: Self.secondaryTextOnArtwork(analysis: analysis),
            windowLyricActive: Self.windowLyricActive(analysis: analysis, isDark: isDark),
            windowLyricInactive: Self.windowLyricInactive(analysis: analysis, isDark: isDark),
            fullscreenLyricBase: Self.fullscreenLyricBase(analysis: analysis),
            fullscreenLyricInactiveBase: Self.fullscreenLyricInactiveBase(analysis: analysis),
            coverGradientDominant: Self.coverGradientDominant(analysis: analysis, isDark: isDark),
            coverGradientText: Self.coverGradientText(analysis: analysis)
        )
    }
}
```

- [ ] **Step 2: 角色色派生函数 — 当前 phase 仅复刻现有 ThemeStore 行为**

In this phase, derive each role to match existing behaviour exactly (we tighten clamps in Phase 3+):

```swift
extension SemanticPaletteFactory {
    fileprivate static func optimizedAccent(
        for scheme: ColorScheme,
        analysis: ArtworkColorAnalysis
    ) -> NSColor {
        // Equivalent to ThemeStore.optimizeAccentColor pre-refactor.
        let raw = analysis.dominantColor
        guard let rgb = raw.usingColorSpace(.deviceRGB) else { return raw }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        rgb.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        s = max(s, 0.24)
        b = max(b, 0.22)
        if scheme == .dark {
            s = min(max(s * 1.06, 0.30), 0.90)
            b = min(max(b * 1.10, 0.62), 0.88)
            let pre = NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1)
            return ColorMath.clampLightness(pre, lo: 0.56, hi: 1.0)
        } else {
            s = min(max(s * 1.02, 0.28), 0.78)
            b = min(max(b * 0.88, 0.28), 0.68)
            return NSColor(calibratedHue: h, saturation: s, brightness: b, alpha: 1)
        }
    }

    // For Phase 2 these are placeholders that just reuse existing colours.
    // Phases 6/8/10 replace them with proper hue/colorfulness-aware derivations.
    fileprivate static func ambientSurface(analysis: ArtworkColorAnalysis, isDark: Bool) -> NSColor {
        analysis.averageColor
    }
    fileprivate static func artBackgroundPrimary(analysis: ArtworkColorAnalysis, isDark: Bool) -> NSColor {
        analysis.topPalette.first ?? analysis.dominantColor
    }
    fileprivate static func artBackgroundSecondary(analysis: ArtworkColorAnalysis, isDark: Bool) -> NSColor {
        analysis.topPalette.dropFirst().first ?? analysis.dominantColor
    }
    fileprivate static func readableTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
        // Equivalent to existing TextPalette.primary derivation (kept in extractor).
        analysis.bestTextSourceColor
    }
    fileprivate static func secondaryTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor.withAlphaComponent(0.86)
    }
    fileprivate static func windowLyricActive(analysis: ArtworkColorAnalysis, isDark: Bool) -> NSColor {
        // Equivalent to ArtworkColorExtractor.adjustedAccent pre-refactor.
        ArtworkColorExtractor.adjustedAccent(from: analysis.averageColor, isDarkMode: isDark)
    }
    fileprivate static func windowLyricInactive(analysis: ArtworkColorAnalysis, isDark: Bool) -> NSColor {
        windowLyricActive(analysis: analysis, isDark: isDark).withAlphaComponent(0.35)
    }
    fileprivate static func fullscreenLyricBase(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor
    }
    fileprivate static func fullscreenLyricInactiveBase(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor
    }
    fileprivate static func coverGradientDominant(analysis: ArtworkColorAnalysis, isDark: Bool) -> NSColor {
        analysis.dominantColor
    }
    fileprivate static func coverGradientText(analysis: ArtworkColorAnalysis) -> NSColor {
        analysis.bestTextSourceColor
    }
}
```

- [ ] **Step 3: Build**

Run `xcodebuild ... build`. Confirm no warnings.

- [ ] **Step 4: Commit**

```bash
git add myPlayer2/Utilities/SemanticPalette.swift
git commit -m "feat(color): add SemanticPalette + factory shadowing existing ThemeStore behaviour"
```

### Task 2.2 — Wire ThemeStore through SemanticPaletteFactory (no consumer change)

**Files:**
- Modify: `myPlayer2/Services/Theme/ThemeStore.swift`

- [ ] **Step 1: Add `analysis` + `semanticPalette` published properties**

In `ThemeStore` after line 47 (`usesFallbackThemeColor`):

```swift
@Published private(set) var analysis: ArtworkColorAnalysis = .neutralFallback
@Published private(set) var semanticPalette: SemanticPalette
```

Initialise in `init()` after line 82:

```swift
self.semanticPalette = SemanticPaletteFactory.make(
    from: .neutralFallback,
    scheme: .dark,
    userFallbackAccent: fallback,
    useArtworkTint: AppSettings.shared.globalArtworkTintEnabled
)
```

- [ ] **Step 2: 在 extractDominantColor 阶段计算 analysis**

Replace `extractDominantColor(from:)` body (line 280-289) with one that returns `ArtworkColorAnalysis`:

```swift
private func extractAnalysis(from data: Data) async -> ArtworkColorAnalysis? {
    await withCheckedContinuation { continuation in
        extractionQueue.async {
            continuation.resume(returning: ArtworkColorExtractor.analyze(from: data))
        }
    }
}
```

In `updateThemeFromArtworkData` (line 240-278), after the existing `extractedColor`, also compute:

```swift
let extractedAnalysis: ArtworkColorAnalysis?
if let snapshotAnalysis = artworkSnapshot?.colorAnalysis {  // see Task 2.3 for snapshot field
    extractedAnalysis = snapshotAnalysis
} else {
    extractedAnalysis = await extractAnalysis(from: data)
}
```

Set `self.analysis = extractedAnalysis ?? .neutralFallback` before calling `refreshPalette`.

- [ ] **Step 3: refreshPalette derives via SemanticPaletteFactory**

Replace lines 322-333 (the `optimizedArtworkAccent` block):

```swift
let semantic = SemanticPaletteFactory.make(
    from: analysis,
    scheme: colorScheme,
    userFallbackAccent: NSColor(AppSettings.shared.accentColor),
    useArtworkTint: AppSettings.shared.globalArtworkTintEnabled && hasArtworkThemeColor
)
let resolvedAccentNS = semantic.globalAccent
let fillAlpha = colorScheme == .dark ? 0.20 : 0.14
withAnimation(.easeInOut(duration: 0.20)) {
    baseColor = Color(nsColor: rawDominantColor)
    accentColor = Color(nsColor: resolvedAccentNS)
    accentNSColor = resolvedAccentNS
    artworkBaseNSColor = rawDominantColor
    selectionFill = Color(nsColor: resolvedAccentNS).opacity(fillAlpha)
    semanticPalette = semantic
}
```

Delete `optimizeAccentColor` (lines 437-470). Keep `enforceMinimumLightnessForDarkMode` only if any external caller references it (grep first; if zero refs, delete).

- [ ] **Step 4: Build & 视觉对比 — 此 phase 必须无变化**

Run app, switch through 4-5 tracks (含黑白封面、彩色封面、低饱和封面），对比 toolbar accent / 歌词 active 色 / Home Hero 文字色 — 应与 phase 0 完全一致。

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
    -configuration Debug build 2>&1 | tail -40
```

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "refactor(theme): route ThemeStore accent through SemanticPaletteFactory (behaviour-equivalent)"
```

### Task 2.3 — (optional) extend `ArtworkAssetSnapshot` to carry analysis cache

**Files:**
- Modify: `myPlayer2/Models/ArtworkAssetSnapshot.swift`
- Modify: `myPlayer2/Services/Artwork/ArtworkAssetStore.swift`

- [ ] **Step 1: 仅当后续 phase 性能检查发现重复 analysis 计算耗时时再做**

加一个 `colorAnalysis: ArtworkColorAnalysis?` 字段并在 store snapshot 时持久化。
本 task 默认 **跳过**，先看 Phase 9 的 Instruments 分析是否需要。

---

## Phase 3 — Dark/light accent clamp tightening
**风险等级:** 中（视觉变化：dark mode accent 整体提亮）

修正深色 accent 偏暗（min lightness 当前 0.56 → hue-adaptive 0.66–0.78），浅色 accent 不能压成脏黑。

### Task 3.1 — Tighten dark/light accent in SemanticPaletteFactory

**Files:**
- Modify: `myPlayer2/Utilities/SemanticPalette.swift` (`optimizedAccent(for:analysis:)`)

- [ ] **Step 1: 替换 `optimizedAccent` 为 hue-adaptive 版本**

```swift
fileprivate static func optimizedAccent(
    for scheme: ColorScheme,
    analysis: ArtworkColorAnalysis
) -> NSColor {
    let raw = analysis.dominantColor
    let comp = ColorMath.hsl(of: raw)
    var h = comp.h, s = comp.s, l = comp.l

    // Hue-aware minimum lightness — blue/violet/red need higher L to read on dark surfaces;
    // yellow/orange already glow at lower L.
    let darkMinL: CGFloat = {
        switch h {
        case 0.10..<0.18: return 0.66   // yellow/orange
        case 0.18..<0.42: return 0.70   // green
        case 0.42..<0.72: return 0.74   // cyan/blue
        case 0.72..<0.85: return 0.76   // violet
        default:           return 0.72  // red/magenta/pink
        }
    }()
    let darkMaxL: CGFloat = 0.82

    if scheme == .dark {
        // Saturation: keep colour expressive but cap to avoid neon.
        s = ColorMath.clamp(max(s * 1.06, 0.32), 0.32, 0.86)
        l = ColorMath.clamp(max(l, darkMinL), darkMinL, darkMaxL)
    } else {
        // Light mode: pull toward darker, but keep hue identity.
        s = ColorMath.clamp(max(s * 1.02, 0.30), 0.30, 0.72)
        l = ColorMath.clamp(min(l * 0.78, 0.50), 0.30, 0.50)
    }

    // Monochrome / low-confidence covers should not produce a saturated accent.
    if analysis.isMonochrome {
        s = min(s, scheme == .dark ? 0.18 : 0.14)
    } else if analysis.dominantHueConfidence < 0.18 {
        s = min(s, scheme == .dark ? 0.40 : 0.32)
    }

    return ColorMath.color(h: h, s: s, l: l)
}
```

- [ ] **Step 2: Build, run, visual review**

测试封面：
1. 黑色封面 → accent 不应是高饱和粉/红，应是温和的 tinted gray
2. 偏黄封面 → accent 仍是黄/暖色，不能跳蓝
3. 鲜红/鲜蓝封面 → dark mode 下文字/图标可读
4. 浅色模式 + 暗封面 → accent 不能糊成黑

视觉异常的话调整上面的 hue → minL 表，不是放宽 clamp。

- [ ] **Step 3: Commit**

```bash
git add -u
git commit -m "feat(color): hue-adaptive dark accent floor + monochrome-aware desaturation"
```

---

## Phase 4 — Important glyph opacity → 1.0
**风险等级:** 低（视觉变化：toolbar 图标变实）

### Task 4.1 — GlassToolbarControls

**Files:**
- Modify: `myPlayer2/Views/Controls/GlassToolbarControls.swift:69, 71, 271, 337`

- [ ] **Step 1: 删除主图标的 0.84/0.88/0.94/0.98 opacity 调制**

In `GlassToolbarControls.swift`:

| Line | Before | After |
|---|---|---|
| 69 | `.foregroundStyle(themeStore.accentColor.opacity(dark ? 0.98 : 0.90))` | `.foregroundStyle(themeStore.accentColor)` |
| 71 | `.foregroundStyle(themeStore.accentColor.opacity(dark ? 0.94 : 0.84))` | `.foregroundStyle(themeStore.accentColor.opacity(dark ? 0.88 : 0.80))` *(secondary, retain hierarchy)* |
| 337 | `.foregroundStyle(themeStore.accentColor.opacity(dark ? 0.96 : 0.88))` | `.foregroundStyle(themeStore.accentColor)` |

**保留 / Keep:**
- 多选 active 背景的 0.10 (line 271) — 这是底色 wash，不是图标
- circle bg 的 0.045/0.08/0.11 (lines 91, 95) — 中性 surface, 不属于 accent 重要图标
- divider opacity 0.10 (line 329) — decorative

- [ ] **Step 2: Sidebar / 主播放按钮检查**

```bash
grep -rn "accentColor.opacity\|themeStore.accent.*opacity" --include="*.swift" \
    myPlayer2/Views/Sidebar myPlayer2/Views/Controls myPlayer2/Views/MiniPlayer
```

对每个命中点判断是否"重要图标"。重要的（播放、暂停、上一首、下一首、active 状态指示）改 1.0；次级（disabled、placeholder、装饰）保留。

- [ ] **Step 3: Build, run, visually verify icons remain readable**

特别注意 dark mode 下 toolbar 图标在玻璃背景上是否过亮。如果过亮 → 不是降 opacity，而是回到 Phase 3 提高 darkMinL 上限或调饱和度。

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "feat(theme): primary toolbar/sidebar glyphs use full-opacity accent"
```

---

## Phase 5 — Window-mode lyrics light scheme palette
**风险等级:** 低（仅 light mode 视觉变化）

### Task 5.1 — adjustedAccent → tinted dark ink in light mode

**Files:**
- Modify: `myPlayer2/Utilities/ArtworkColorExtractor.swift:73-97` (`adjustedAccent`)

- [ ] **Step 1: 调整 light mode 分支**

Replace lines 84-93:

```swift
// Keep color soft and readable; preserve hue identity.
if isDarkMode {
    // Near-white tinted: dark mode current behaviour preserved.
    saturation = ColorMath.clamp(saturation, 0.08, 0.22)
    brightness = ColorMath.clamp(max(brightness, 0.98), 0.98, 1.0)
} else {
    // Tinted dark ink — keep hue, raise saturation a notch, target HSL L 0.18–0.28.
    saturation = ColorMath.clamp(saturation, 0.18, 0.38)
    let comp = ColorMath.hsl(of: NSColor(calibratedHue: hue, saturation: saturation, brightness: 0.5, alpha: 1))
    let targetL = ColorMath.clamp(0.22, 0.18, 0.28)
    return ColorMath.color(h: hue, s: saturation, l: targetL)
}
```

- [ ] **Step 2: Update SemanticPaletteFactory.windowLyricActive 沿用此 helper**

(已是; no change needed. Just confirm `windowLyricActive` reads through `adjustedAccent`.)

- [ ] **Step 3: Visual verification**

App 切到 light mode，播放 5 首颜色不同的歌：
- 红封面 → 歌词 active 是红墨黑（不是纯黑）
- 蓝封面 → 歌词 active 是蓝墨黑
- 黑白封面 → 歌词 active 接近中性深灰（saturation 自然低）

inactive 应当比 active 更灰，但仍保留色相（来自同 hue 的 0.35α 衰减）。

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "feat(lyrics): light-mode window lyrics keep cover hue as tinted dark ink"
```

---

## Phase 6 — Robust dominant color selection (异常取色修正)
**风险等级:** 中（核心算法变更，影响所有下游）

修正"黑白封面被取出粉色 / 偏黄出蓝 / tiny noise dominates"。

### Task 6.1 — Tighten `uiThemePalette` candidate selection

**Files:**
- Modify: `myPlayer2/Utilities/ArtworkColorExtractor.swift:210-328` (`uiThemePalette(from:targetCount:)`)

- [ ] **Step 1: 加面积下限与噪点惩罚**

In the candidate loop (lines 276-288), replace the simple `bucket.weight > minimumBucketWeight` check with:

```swift
let totalBucketWeight = buckets.reduce(CGFloat(0)) { $0 + $1.weight }
let minimumBucketWeight = totalBucketWeight * 0.030  // raise from 0.012 → 0.030
let noiseFloor = totalBucketWeight * 0.012
```

For each bucket above `noiseFloor`:

```swift
let inv = 1 / bucket.weight
let bucketColor = NSColor(calibratedRed: bucket.r * inv, green: bucket.g * inv, blue: bucket.b * inv, alpha: 1)
let bucketSat = saturationValue(of: bucketColor)
let areaShare = bucket.weight / totalBucketWeight

// Tiny high-saturation buckets are rejected outright (likely watermark / sticker noise).
if areaShare < 0.030 && bucketSat > 0.55 {
    continue
}

// Score: area-dominated, with mild saturation bonus only for substantial regions.
let satBonus = areaShare >= 0.10 ? bucketSat * 0.30 : bucketSat * 0.10
let tuned = tuneUI(bucketColor, profile: profile)
let score = bucket.weight * (0.85 + satBonus)
candidates.append(PaletteCandidate(color: tuned, hue: hueValue(of: tuned), score: score))
```

- [ ] **Step 2: 反互补色保护**

After candidates are sorted (line 300), but before `selected` loop (line 302):

```swift
// If one hue family clearly dominates (>= 35% area share), reject
// any later candidate whose hue is the rough complementary unless its area
// is also substantial (>= 25%).
let dominantHue = candidates.first.map { hueValue(of: $0.color) }
let dominantArea = candidates.first.map { $0.score / max(1, totalBucketWeight) }
let primaryConfidence = candidates.first.map { $0.score / candidates.dropFirst().reduce(CGFloat(0.0001)) { $0 + $1.score } }
let primaryAreaShare: CGFloat = ... // derive from bucket area, not score

candidates = candidates.filter { cand in
    guard let dh = dominantHue else { return true }
    let candArea = ... // compute from underlying bucket
    let isComplementary = ColorMath.circularHueDistance(hueValue(of: cand.color), dh) > 0.40
    if isComplementary && candArea < 0.25 { return false }
    return true
}
```

(Preserve the candidate's underlying area share by attaching it to `PaletteCandidate` — extend the struct: `let areaShare: CGFloat`.)

- [ ] **Step 3: 黑白封面不合成高饱和**

Before the `while selected.count < targetCount, let base = selected.first` synthesis loop (around line 322), short-circuit:

```swift
if profile.avgSaturation < 0.10 && profile.vividness < 0.04 {
    // Monochrome cover — return at most one tinted-gray candidate;
    // do NOT synthesize variants.
    if selected.isEmpty {
        let fallback = NSColor(
            calibratedRed: fallbackR / fallbackWeight,
            green: fallbackG / fallbackWeight,
            blue: fallbackB / fallbackWeight,
            alpha: 1
        )
        return [tuneUI(fallback, profile: profile)]
    }
    return selected
}
```

- [ ] **Step 4: Build & test**

测试集合（手动，每个一首）:
1. **真黑白封面** — Joy Division "Unknown Pleasures" 类 — accent 应是中性灰偏一点点暖/冷，不是粉
2. **大面积黄底 + 小面积蓝 logo** — accent 应该是黄/橙，不是蓝
3. **小面积高饱和点缀** — 例如背景大面积深灰 + 角落鲜红 logo — accent 应是深灰，不是红
4. **正常彩色封面** — accent 与改前接近（小幅变化可接受）

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "fix(color): area-weighted dominant selection rejects noise / complementary outliers"
```

### Task 6.2 — Update `analyze` to expose `dominantHueConfidence` 与 `colorfulness`

**Files:**
- Modify: `myPlayer2/Utilities/ArtworkColorAnalysis.swift` (analyzeInternal)

- [ ] **Step 1: 在 analyzeInternal 中正确填充新指标**

`dominantHueConfidence = sortedBuckets[0].weight / totalWeight`
`colorfulness = vividWeight / totalWeight`
`isMonochrome = colorfulness < 0.04 && avgSaturation < 0.10`
`hasStrongAccentRegion = sortedBuckets.contains { $0.areaShare >= 0.18 && $0.bucketSaturation >= 0.50 }`

- [ ] **Step 2: Build & smoke-test，确认 ThemeStore.semanticPalette 在测试集上的取值合理**

加临时 `Log.debug(... category: .theme)` 打印 analysis 字段（5 张样本歌曲）。验证完后删掉。

- [ ] **Step 3: Commit**

```bash
git add -u
git commit -m "feat(color): expose dominantHueConfidence/colorfulness/isMonochrome on analysis"
```

---

## Phase 7 — Home Hero & Cover Gradient Blur 共享 surface palette
**风险等级:** 中（两个模块的色卡来源切换）

把 `HomeHeroView` 与 `CoverGradientBlurBackgroundView` / `FullscreenCoverGradientBlurSkin` 的封面色卡收敛到 `SemanticPalette.coverGradientDominant` / `coverGradientText` / `readableTextOnArtwork`。

### Task 7.1 — Implement proper coverSurface derivation in factory

**Files:**
- Modify: `myPlayer2/Utilities/SemanticPalette.swift`

- [ ] **Step 1: 替换 placeholder 为正式实现**

```swift
fileprivate static func coverGradientDominant(analysis: ArtworkColorAnalysis, isDark: Bool) -> NSColor {
    // Drive cover-overlay tint from dominant hue, keep moderate saturation,
    // never go past the cover's own brightness band.
    let hsl = ColorMath.hsl(of: analysis.dominantColor)
    let s = ColorMath.clamp(hsl.s * 0.92, 0.10, 0.62)
    let l = ColorMath.clamp(hsl.l, 0.22, 0.78)
    return ColorMath.color(h: hsl.h, s: s, l: l)
}

fileprivate static func coverGradientText(analysis: ArtworkColorAnalysis) -> NSColor {
    // Same logic as readableTextOnArtwork but with stronger contrast bias
    // — used over blurred cover, not solid surfaces.
    let hsl = ColorMath.hsl(of: analysis.bestTextSourceColor)
    if analysis.usesDarkForeground {
        return ColorMath.color(h: hsl.h, s: ColorMath.clamp(hsl.s, 0.18, 0.36), l: 0.16)
    } else {
        return ColorMath.color(h: hsl.h, s: ColorMath.clamp(hsl.s, 0.06, 0.20), l: 0.94)
    }
}

fileprivate static func readableTextOnArtwork(analysis: ArtworkColorAnalysis) -> NSColor {
    // Reuse extractor's enforceTextContrast pipeline by computing TextPalette on the fly.
    // For Phase 7 we simply read analysis.bestTextSourceColor through ColorMath.clamp{Lightness,Saturation}.
    let hsl = ColorMath.hsl(of: analysis.bestTextSourceColor)
    if analysis.usesDarkForeground {
        return ColorMath.color(h: hsl.h, s: ColorMath.clamp(hsl.s + 0.04, 0.10, 0.34), l: 0.12)
    } else {
        return ColorMath.color(h: hsl.h, s: ColorMath.clamp(hsl.s, 0.04, 0.24), l: 0.92)
    }
}
```

### Task 7.2 — Wire HomeHeroView through SemanticPalette

**Files:**
- Modify: `myPlayer2/Views/Home/HomeHeroView.swift`

- [ ] **Step 1: 删除 `artworkTextPalette` 本地 extraction**

Replace the `@State private var artworkTextPalette: ArtworkColorExtractor.TextPalette?` (line 27) and any `.onChange { ... textPalette(from: data) ... }` with:

```swift
private var artworkTextPrimary: Color {
    Color(nsColor: themeStore.semanticPalette.readableTextOnArtwork)
}
private var artworkTextSecondary: Color {
    Color(nsColor: themeStore.semanticPalette.readableTextOnArtwork.withAlphaComponent(0.78))
}
```

Update title/subtitle bindings to use these.

`artworkDominantColor` (line 26) likewise becomes `themeStore.semanticPalette.coverGradientDominant`.

- [ ] **Step 2: Build & visual check — Home 页 hero 文字**

切 4 首颜色不同的歌进 Home，确认 hero 文字仍清晰、与封面色相协调，没出现颜色延迟。

- [ ] **Step 3: Commit**

```bash
git add -u
git commit -m "refactor(home): HomeHero reads SemanticPalette instead of own extraction"
```

### Task 7.3 — Wire CoverGradientBlur through SemanticPalette

**Files:**
- Modify: `myPlayer2/Skins/NowPlaying/CoverGradientBlurBackgroundView.swift`
- Modify: `myPlayer2/Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift`

- [ ] **Step 1: dominantColor 入参改为 `coverGradientDominant`**

Caller side (`FullscreenCoverGradientBlurSkin.swift`): replace `themeStore.accentNSColor` / `rawDominantColor` / `themeStore.artworkBaseNSColor` reads with `themeStore.semanticPalette.coverGradientDominant`.

- [ ] **Step 2: Visual check — 全屏 cover gradient blur skin**

`Cmd-F` 进全屏 cover gradient blur skin，切 5 首测试歌:
1. 整体观感 vs 改前: dominant 色调、blur 浓度、文字可读性
2. 切歌时颜色不应延迟一拍
3. AMLL reload 动画照常

- [ ] **Step 3: Commit**

```bash
git add -u
git commit -m "refactor(skin): cover gradient blur reads SemanticPalette.coverGradientDominant"
```

### Task 7.4 — Wire HomeAmbientShapes through SemanticPalette

**Files:**
- Modify: `myPlayer2/Views/Home/HomeAmbientShapesBackground.swift`

- [ ] **Step 1: sourceColor 改读 `ambientSurface`**

Caller passes `themeStore.semanticPalette.ambientSurface` instead of `artworkBaseNSColor`. 同时把 `Self.palette(from:)` 内部的 hue 处理简化为读 analysis 直接生成（如果实现复杂，**保留旧 palette 逻辑**，仅换 sourceColor 入口）。

- [ ] **Step 2: Build, visual sanity check**

- [ ] **Step 3: Commit**

```bash
git add -u
git commit -m "refactor(home): ambient shapes reads SemanticPalette.ambientSurface"
```

---

## Phase 8 — BKArt 背景饱和度稳定性
**风险等级:** 中-高（BKColorEngine 是高度调过的引擎，触动需谨慎）

### Task 8.1 — BKColorEngine 接受 ArtworkColorAnalysis

**Files:**
- Modify: `myPlayer2/Views/NowPlaying/BKColorEngine.swift`
- Modify: `myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift:187-220`

- [ ] **Step 1: 扩展 BKColorEngine signature**

Read current `BKColorEngine` API (尚未确认完整 signature；首步先读取并记录现有入参 / 输出)：

```bash
grep -n "func\|init\|struct\|class" myPlayer2/Views/NowPlaying/BKColorEngine.swift | head -30
```

加一个可选 `analysis: ArtworkColorAnalysis?` 入参（默认 `nil` 保持向后兼容）。

- [ ] **Step 2: 用 analysis 调制 bgSRange / fgSRange**

In whatever function emits `bgSRange` / `fgSRange` / `dotSRange` (per Explore report 大约位于 line 107-118)：

```swift
let analysisColorfulness = analysis?.colorfulness ?? 0.5
let analysisIsMono = analysis?.isMonochrome ?? false
let confidenceFactor = (analysis?.dominantHueConfidence ?? 0.5)

// Saturation tier widening is gated by colorfulness; mono covers cap saturation low.
let bgSatCeiling: CGFloat = {
    if analysisIsMono { return 0.10 }
    if analysisColorfulness < 0.20 { return 0.32 }
    if analysisColorfulness < 0.45 { return 0.55 }
    return 0.78
}()
let bgSatFloor: CGFloat = analysisIsMono ? 0.0 : 0.06

bgSRange = bgSatFloor ... min(bgSatCeiling, originalBgSRange.upperBound)

// Low confidence → narrow band to avoid muddy mixes
if confidenceFactor < 0.20 {
    let narrowed = (bgSRange.upperBound - bgSRange.lowerBound) * 0.6
    bgSRange = bgSRange.lowerBound ... bgSRange.lowerBound + narrowed
}
```

- [ ] **Step 3: BKArtBackgroundView passes analysis**

In `BKArtBackgroundView.swift` 替换 `ArtworkColorExtractor.uiThemePalette(from: data, maxColors: 4)` (line 199) 与 `uiThemePaletteRich` (line 200) 调用：

```swift
guard let analysis = ArtworkColorExtractor.analyze(from: data) else { return }
let palette = analysis.topPalette
let rich = analysis.richPalette
// pass `analysis` into BKColorEngine constructor
```

- [ ] **Step 4: Visual: 高饱和封面、低饱和封面、纯黑白封面**

进 NowPlayingView，切：
- 高饱和彩色封面 → BK1/BK2 背景应有色彩
- 低饱和暗色封面 → 不强行变艳，但也不糊成纯灰
- 黑白封面 → 高级灰+冷暖偏，不出现彩色

- [ ] **Step 5: Commit**

```bash
git add -u
git commit -m "feat(skin): BKColorEngine reads ArtworkColorAnalysis for saturation tiering"
```

---

## Phase 9 — Fullscreen lyrics 仅切换颜色输入源
**风险等级:** 高（fullscreen 时序敏感，不能动 HSL 流水线、override 顺序、AMLL reload）

### Task 9.1 — 切 `resolveFullscreenLyricsBaseColor` 输入

**Files:**
- Modify: `myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift:3449-3481`

先看现有 `resolveFullscreenLyricsBaseColor(forTrackID:)` 与 `resolveFullscreenLyricsInactiveBaseColor(forTrackID:)` 实现（grep 找到行号已确认 3449/3460）。它们应该读了 ThemeStore 或 BKArt 的某个 cached color。

- [ ] **Step 1: 阅读两函数现有实现**

```bash
sed -n '3449,3490p' myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift
```

把现有 source（多半是 ThemeStore.artworkBaseNSColor / averageColor）替换为：

```swift
private func resolveFullscreenLyricsBaseColor(forTrackID trackID: UUID?) -> NSColor {
    themeStore.semanticPalette.fullscreenLyricBase
}

private func resolveFullscreenLyricsInactiveBaseColor(forTrackID trackID: UUID?) -> NSColor {
    // BKArt 当前背景仍可作为 inactive 的二次提示 — 保留旧 fallback 链（如有）。
    if let bkColor = bkArtBackgroundController.currentSurfaceBackgroundColor {
        return bkColor
    }
    return themeStore.semanticPalette.fullscreenLyricInactiveBase
}
```

**禁止** 改：
- HSL 计算流水线 (lines 3093-3184)
- `applyFullscreenLyricsTheme` 时序 (lines 2440-2536)
- `setThemePaletteOverride` / `updateThemeOverrideSnapshot` 调用顺序
- `coverBlurLyricsTheme` ready check
- AMLL reload-driven palette flush

- [ ] **Step 2: 切 `fullscreenLyricBase` factory 实现**

In `SemanticPalette.swift` `fullscreenLyricBase` / `fullscreenLyricInactiveBase`:

```swift
fileprivate static func fullscreenLyricBase(analysis: ArtworkColorAnalysis) -> NSColor {
    // 高 colorfulness + 强 hue 主导 → 用 dominant；否则 → bestTextSourceColor。
    if analysis.colorfulness >= 0.20 && analysis.dominantHueConfidence >= 0.20 {
        return analysis.dominantColor
    }
    return analysis.bestTextSourceColor
}

fileprivate static func fullscreenLyricInactiveBase(analysis: ArtworkColorAnalysis) -> NSColor {
    // Inactive 取 average 更稳，避免高饱和 dominant 在 inactive 上闪烁。
    analysis.averageColor
}
```

- [ ] **Step 3: 严格视觉测试**

- 普通 fullscreen skin (强制 dark scheme)：歌词亮色 active / 暗色 inactive 仍如往常
- BKArt skin：inactive 仍受 BKArt 当前 surface 影响
- Cover gradient blur skin lighter profile：高亮歌词不洗白
- Cover gradient blur skin darker profile：暗色封面下高亮歌词仍可见
- 切歌时不出现"上一首颜色残留" — 检查 `currentArtworkTrackID` / `themeIdentity` 一致性

- [ ] **Step 4: Commit**

```bash
git add -u
git commit -m "refactor(fullscreen): lyrics colour input from SemanticPalette, HSL pipeline preserved"
```

---

## Phase 10 — Verification & cleanup
**风险等级:** 极低（清理 + 验证）

### Task 10.1 — Search for stale duplication

- [ ] **Step 1: 找未迁移的旧 extractor 调用**

```bash
grep -rn "ArtworkColorExtractor\.uiThemePalette\|ArtworkColorExtractor\.uiAccentColor\|ArtworkColorExtractor\.averageColor\|ArtworkColorExtractor\.textPalette" \
    --include="*.swift" myPlayer2/
```

每个命中点判断:
- 在 `analyze()` 内部使用 → 保留（属于实现细节）
- 在 SemanticPaletteFactory 派生函数内 → 保留
- 在其他模块直接读 → 应该全部迁到 `themeStore.semanticPalette.<role>`，否则记录为 follow-up

- [ ] **Step 2: 重复 HSL helper 检查**

```bash
grep -rn "calibratedHue:\|getHue(&" --include="*.swift" myPlayer2/ | grep -v "ColorMath\|ArtworkColorExtractor\|ArtworkColorAnalysis\|SemanticPalette\|FullscreenPlayerView"
```

非以上文件中的 HSL/HSB 直接转换，应该都消失或迁移到 ColorMath。

### Task 10.2 — Build & smoke test matrix

- [ ] **Step 1: Release build**

```bash
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
    -configuration Release build 2>&1 | tail -40
```

- [ ] **Step 2: 视觉检查矩阵**

| 场景 | 检查点 |
|---|---|
| Dark mode toolbar | 主图标 opacity=1, 颜色明亮可读 |
| Light mode toolbar | 主图标 opacity=1, 颜色不糊黑 |
| Window 模式歌词 (light) | active 是 tinted dark ink, inactive 仍灰但保留色相 |
| Window 模式歌词 (dark) | 与改前一致 |
| Home Hero | 文字可读，色相与封面协调，切歌无延迟 |
| Cover Gradient Blur skin (lighter profile) | 高亮歌词不洗白 |
| Cover Gradient Blur skin (darker profile) | 暗色封面下高亮可见 |
| BKArt skin | 高饱和封面有色彩，低饱和不强行变艳 |
| 黑白封面 | accent 中性, 无粉/红 |
| 偏黄封面 | accent 黄/橙, 无蓝 |
| 高饱和小区域噪点 | accent 取主区域，不被噪点劫持 |
| AMLL reload (切歌) | 颜色无延迟，无前歌残留 |
| Liquid Glass 玻璃材质 | 仍中性，不被全局 accent 染色 |
| Library halo (album page) | 不变 |

- [ ] **Step 3: Final commit (cleanup, removed dead code)**

```bash
git add -u
git commit -m "chore(color): remove dead extractor call sites + tighten exports"
```

---

## Phase 11 — Documentation & Memory updates

### Task 11.1 — Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 在 "Key Conventions" 节加一条**

```markdown
### Color System
- All color extraction goes through `ArtworkColorExtractor.analyze(from:)` returning `ArtworkColorAnalysis`.
- All UI colors derive from `ThemeStore.semanticPalette` (a `SemanticPalette`), never from the artwork directly.
- Per-role colors: `globalAccent`, `windowLyricActive/Inactive`, `fullscreenLyricBase`, `coverGradientDominant`, `artBackgroundPrimary/Secondary`, `ambientSurface`, `readableTextOnArtwork`.
- HSL/HSB/contrast math lives in `ColorMath` only.
- Glass surfaces stay neutral; only important glyphs receive accent at full opacity.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document semantic color system in CLAUDE.md"
```

### Task 11.2 — Memory note

- [ ] **Step 1: 更新 user memory**

写一条 project memory: "Color refactor lands $(date): central SemanticPalette layer, BKColorEngine reads analysis, fullscreen lyrics HSL pipeline intentionally preserved."

---

## Final Summary Template

完成后按以下结构汇报:

```
改动文件:
- [ ] 新增: ColorMath.swift, ArtworkColorAnalysis.swift, SemanticPalette.swift
- [ ] 修改: ThemeStore.swift, ArtworkColorExtractor.swift, GlassToolbarControls.swift,
         HomeHeroView.swift, HomeAmbientShapesBackground.swift,
         CoverGradientBlurBackgroundView.swift, FullscreenCoverGradientBlurSkin.swift,
         BKArtBackgroundView.swift, BKColorEngine.swift, FullscreenPlayerView.swift,
         CLAUDE.md

每个模块的颜色来源 (after refactor):
- ThemeStore.accentColor          ← SemanticPalette.globalAccent
- GlassToolbarControls (primary)  ← themeStore.accentColor (α=1)
- LyricsPanelView (window)        ← SemanticPalette.windowLyricActive/Inactive
- HomeHeroView                    ← SemanticPalette.readableTextOnArtwork + coverGradientDominant
- HomeAmbientShapes               ← SemanticPalette.ambientSurface
- CoverGradientBlur skin          ← SemanticPalette.coverGradientDominant + coverGradientText
- BKArtBackground / BKColorEngine ← SemanticPalette + ArtworkColorAnalysis
- FullscreenPlayerView lyrics     ← SemanticPalette.fullscreenLyricBase/InactiveBase
                                    (HSL pipeline DOWNSTREAM unchanged)
- BlurredArtworkBackgroundView    ← unchanged (raw artwork blur)
- LibraryDetailHeaderView Halo    ← unchanged

被替换的旧逻辑:
- ThemeStore.optimizeAccentColor / enforceMinimumLightnessForDarkMode → SemanticPaletteFactory.optimizedAccent
- ThemeStore + ArtworkColorExtractor 中的 FNV-1a / HSL helpers → ColorMath
- HomeHeroView 自取 textPalette → 读 SemanticPalette
- BKArtBackgroundView 直接取 uiThemePalette → 通过 analysis 间接拿
- ArtworkColorExtractor.adjustedAccent (light mode) → tinted dark ink

刻意保留:
- BlurredArtworkBackgroundView (Library halo) — 直接 blur 封面图，无取色环节
- LibraryDetailHeaderView — 同上
- FullscreenPlayerView 的 makeFullscreenLyricsColorSet HSL 流水线 — 已经过精细调校
- AMLL palette override 时序与 reload 动画
- GlassPillView / GlassStyleTokens 中的玻璃材质 token — 玻璃保持中性
- 多选 active 背景的 0.10 opacity — 是 surface wash 不是 accent 图标
```

---

## Self-Review Notes

**Spec coverage:**
- 1 (统一底层颜色评估) ✓ Phase 0+1 (ColorMath + ArtworkColorAnalysis)
- 2 (语义角色色) ✓ Phase 2 (SemanticPalette)
- 3 (深色 accent 偏暗) ✓ Phase 3
- 4 (重要图标 opacity = 1) ✓ Phase 4
- 5 (玻璃材质保持中性) ✓ 显式不改 GlassPillView/GlassStyleTokens; Phase 4 review 表
- 6 (浅色窗口歌词色相) ✓ Phase 5
- 7 (全屏歌词谨慎处理) ✓ Phase 9 (only 切输入源, HSL 不动)
- 8 (Home Hero / Cover Gradient Blur 统一) ✓ Phase 7
- 9 (异常取色修正) ✓ Phase 6
- 10 (BKArt 饱和度稳定) ✓ Phase 8
- 11 (保留各模块视觉气质) ✓ 显式不改 Library / Glass / Fullscreen HSL pipeline
- 12 (实现顺序) ✓ phase 顺序与 spec 第 12 条吻合
- 13 (验证) ✓ Phase 10

**已知 placeholder / 待验证项:**
- Task 8.1 step 1 用了 `grep` 先确认 `BKColorEngine` 实际 API 才能填具体类型 — 实施时由执行 agent 完成
- Task 9.1 step 1 类似 — `resolveFullscreenLyricsBaseColor` 实际 body 需先读取再替换
- Task 7.4 `HomeAmbientShapes.palette(from:)` 内部逻辑 — 如果复杂则保留, 仅换 sourceColor 入口

**Type consistency:** ArtworkColorAnalysis / SemanticPalette / SemanticPaletteFactory 字段名在所有 phase 一致。`themeStore.semanticPalette` 路径全文一致。
