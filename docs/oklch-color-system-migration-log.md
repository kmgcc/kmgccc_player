# OKLCH Color System Migration Log

本日志用于记录颜色系统重构与 OKLCH 迁移过程中的实际改动、验证结果、决策与后续接力点。\
设计文档：`docs/oklch-migration-color-system-investigation.md`（R1–R4 调查报告）。\
施工计划：`docs/oklch-color-system-execution-plan.md`。

每条记录至少给出：本阶段目标、改动文件清单、决策点、验证结果、对后续阶段的"接力提示"。

---

## Phase 0 — Pre-migration cleanup

**完成日期**：2026-05-19。

### 本阶段目标

把"无消费的契约"和"潜在 B 类 bug"一次性清掉，给 Phase 1（颜色 token 化 / OKLCH 数学层）让出干净的起点。**本阶段不引入新算法、不修改主视觉口径**。

详细执行表见 `oklch-color-system-execution-plan.md` §3。

### 0.1 ArtworkAssetStore 缓存版本号

**结果**：已修复。

**改动**：

- `Utilities/ArtworkColorExtractor.swift`：新增 `public nonisolated static let cacheVersion: String = "semantic-near-mono-v2"`，作为颜色提取算法版本的单一来源。
- `Models/ArtworkAssetSnapshot.swift`：实例 `cacheKey` getter 改为委派给新 `static func cacheKey(trackID:artworkChecksum:)`；后者在 key 前缀加入 `ArtworkColorExtractor.cacheVersion`。
- `Services/Artwork/ArtworkAssetStore.swift`：`get(trackID:artworkChecksum:)` 与 `getOrCreate` 内联 key 构造换成 `ArtworkAssetSnapshot.cacheKey(trackID:artworkChecksum:)`，保证两条读写路径走同一 key 模板。
- `Services/Theme/ThemeStore.swift`：删除私有实例常量 `colorExtractionCacheVersion`；`makeCacheKey` 直接读 `ArtworkColorExtractor.cacheVersion`。

**决策**：

- 选择"key 前缀方案"而非"snapshot 内嵌 cacheVersion 字段"路线。理由：内嵌字段需要每个读者主动校验、容易漏；前缀方案是单点修改，老 entry 在算法版本变更后自动落选，新 entry 在同版本下仍能正常 cache / hit。
- 把版本字符串落在 `ArtworkColorExtractor` 而不是 `ArtworkAssetSnapshot`：因为它语义上属于"提取算法版本"，对其它后续可能加入的提取派生 cache 也是同一个源头。

**风险评估**：

- 不引入新的 race。snapshot in-progress 合并仍按 key 字符串去重，前缀只是把 namespace 拓宽。
- `ThemeStore.dominantColorCache` 仍走自己已经版本化的 key 模板（identity-based，与 ArtworkAssetStore 的 trackID-based 不同 namespace），与本次改动正交。

### 0.2 歌词 Swift → Web 死字段清理

**结果**：已修复（端到端）。

**改动**：

- `Services/Theme/ThemeStore.swift`：从 `ThemePalette` 结构体删除 `accent: String` 与 `shadow: String` 字段；`refreshPalette` 不再计算 `accent` / `shadow` 两个本地 CSS 字符串；palette 签名不再包含它们；`Log.trace` "refreshPalette details" 日志去掉 `accent=` 字段。
- `Services/Lyrics/LyricsWebViewStore.swift`：`applyEffectiveTheme` 的 config 字典移除 `"shadowColor"` 键；CSS 注入 IIFE 删除 `--amll-bg` / `--amll-accent` / `--amll-shadow` 三条 setProperty。保留 `--amll-text` / `--amll-active` / `--amll-inactive`（仍是 live 契约）。
- `ViewModels/LyricsViewModel.swift`：surface config 字典移除 `"shadowColor": "rgba(0,0,0,0)"`（即使值是透明，作为字段名仍属同一死契约）。
- `Views/Fullscreen/FullscreenPlayerView.swift`：两个 `ThemePalette(...)` 构造点（`makeLyricsPalette` / `makeCoverBlurLyricsPalette`）删去 `accent` 与 `shadow` 参数。
- `Resources/AMLL/index.html`：删除 `if (hasOwn("shadowColor"))` 善后分支（在 Swift 不再发送该字段后永远不触发，注释已说明 A/B 1 测试结论）。

**端到端验证**（grep 残留）：

```
grep palette.accent | palette.shadow | palette?.accent | palette?.shadow
  → 无结果

grep var(--amll-shadow | var(--amll-bg | var(--amll-accent
  → 无结果

grep setProperty.*amll-shadow | setProperty.*amll-bg | setProperty.*amll-accent
  → 无结果

grep "shadowColor" 在 Swift / HTML / JS / CSS 活动资源
  → 仅剩 LyricsWebViewStore.swift 注释中说明本次清理的 "--amll-shadow"，以及
     BKArtBackgroundView.swift 一处 CALayer.shadowColor（CALayer 的属性名，与歌词死字段无关）
```

**决策**：

- 不动 `--amll-text` CSS 变量。`grep` 显示 `index.html` 没有 `var(--amll-text, ...)` 读者；但用户明确清理列表未含 `--amll-text`，且 `palette.text` 字段在 Swift 侧仍是活的（`ThemeStore.textColor` 给 SwiftUI 用、AMLL config 用 `palette.text` 作 `textColor`/`--amll-lp-color` 上游）。本轮严格按用户列表执行，避免误删。
- 不动 `palette.background` Swift 字段。`ThemeStore.backgroundColor` getter 仍被 `LyricsPanelView` 消费，是 live 字段。仅清掉 web 侧 `--amll-bg` 注入（无消费者）。
- 不动 `index.html` 中 `--amll-active` / `--amll-inactive` / `--amll-lp-color` 回退链（仍是渲染契约）。

**风险评估**：

- AMLL fork TypeScript 没有任何对死字段的硬依赖（事先 `grep amll-shadow|amll-bg|amll-accent` 命中数为 0）。`index.html` 的 `hasOwn("shadowColor")` 分支是 App adapter 层的善后代码，删除后行为不变（textShadow 在其它任何路径都未被设置过非 none 值）。
- 归回顾：本次符合 `docs/amll-custom-behavior-and-patch-registry.md` 推荐的"先尝试外层 / App adapter / CSS"修改优先级——本次只动 App adapter (`index.html`) 与 App 端 Swift，未触及 fork core。

### 0.3 MiniPlayerSpectrumView fallback 统一

**结果**：已修复。

**改动**：

- `Views/Fullscreen/MiniPlayerSpectrumView.swift`：`resolveStaticAccent` 改为 `@MainActor` 静态函数；fallback 来源切换为 `AppSettings.shared.accentColor`（默认 `#E6C799`，与 `accentColorHex` / `ThemeStore.defaultBlueNS` 同口径）。`NSColor(white: 0.7, alpha: 1.0)` 硬编码已删除。

**决策**：

- 显式传入 accent 的调用路径行为不变（`color` 非 nil 时优先使用传入色）。
- 没有新增 module-level 常量；复用 `AppSettings.shared.accentColor` 作为单一默认 accent 来源。
- 不复用 `ThemeStore.shared.defaultBlue`：`AppSettings.shared.accentColor` 是用户可调主题色的源头，`ThemeStore.defaultBlueNS` 是 ThemeStore 启动时拷贝的 fallback；两者初始值一致，但 `AppSettings.shared.accentColor` 跟随用户偏好。

### 0.4 ClassicLEDSkin 阴影深浅自适应

**结果**：已修复。

**改动**：

- `Skins/NowPlaying/ClassicLEDSkin.swift`：`ClassicCoverArtworkView.body` 内新增 `shadowOpacity` 局部变量，从 `context.theme.colorScheme` 派生（深色 0.35 保留原始厚重感；浅色降到 0.18）。`shadow(color: .black.opacity(0.35), ...)` 改为 `.black.opacity(shadowOpacity)`。

**决策**：

- 用 `context.theme.colorScheme` 而不是新增 `@Environment(\.colorScheme)`：与同文件 `PillSpectrumView` 不同，`ClassicCoverArtworkView` 已经持有 `SkinContext`，复用既有路径不引入第二条 colorScheme 来源。
- radius / x / y 一律保持原值，本轮**只**调 opacity。

### 0.5 FullscreenCoverGradientBlurSkin 占位 icon 自适应

**结果**：已修复。

**改动**：

- `Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift`：`CoverGradientBlurArtwork` 新增 `@Environment(\.colorScheme) private var colorScheme`；占位 `music.note` icon 的 `foregroundStyle` 从硬编码 `.white.opacity(0.5)` 改为新计算属性 `placeholderIconColor`（深色 `.white.opacity(0.5)`、浅色 `.primary.opacity(0.45)`）。

**决策**：

- 报告 C.4 将这一项写作 "FullscreenCoverGradient 箭头"，实际对应的是 placeholder 上的 `music.note` SF Symbol（无 artwork 时显示）。本轮**只**修这一处；用户标注的"箭头"含义即此处。
- 没有为这一处单独造可读性判定，沿用 SwiftUI 语义色 `.primary` 由系统决定前景。
- 不删除 `CoverGradientBlurArtwork` 私有视图。它是 dead code（`makeArtwork` 返回 `EmptyView()`），但 Phase 0 不做范围扩张；登记在"接力提示"里，留给 Phase 7 清理。

### 0.6 colorScheme 响应方式评估

**结果**：本轮**不动**，仅登记。

**结论**：`LedMeterView` 与 `MiniPlayerSpectrumView` 的 colorScheme 响应方式差异**是设计意图，不是 bug**。

- `LedMeterView` 直接 `@Environment(\.colorScheme)`：宿主视图（NowPlaying / 各 Skin）的背景是系统材质，颜色需要随系统 appearance 切换刷新——直接读 env 是正确选择。
- `MiniPlayerSpectrumView` 走父视图传 `usesDarkForeground: Bool`：在 fullscreen Clear miniPlayer 场景下，spectrum 落在 artwork blur 上方，正确的对比由 **artwork luma**（`themeStore.semanticPalette.analysis`）决定，而**不是**由系统 appearance 决定。父级 `FullscreenMiniPlayerView.usesDarkArtworkForegroundForClear` 正是这样计算的（不读 colorScheme，只读 analysis）。如果改成 `@Environment(\.colorScheme)`，反而会破坏"封面亮 → 用暗色频谱""封面暗 → 用亮色频谱"的现有判定。

因此两条路径**不应**强制统一。登记为后续架构一致性项，**不在本轮改动**。

**后续 Phase 4（"交互与可读性语义色"）的关注点**：当 Artwork Readability Profile 统一对外时，`MiniPlayerSpectrumView` 的 `usesDarkForeground: Bool` 参数应被替换成一个语义化的 `readabilityProfile` 输入；届时再统一两条路径的描述方式。

### 构建验证

```
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

**死字段残留 grep**：全部 0 命中（仅剩本次清理的说明性注释）。

**视觉验证**：本轮**只完成代码级修复**。0.4 / 0.5 的视觉对比需在浅色 / 深色 / 多种 artwork luma 下手测确认；尚未做。

### 改动文件清单

```
docs/oklch-color-system-execution-plan.md                          (新增)
docs/oklch-color-system-migration-log.md                            (新增 — 本文件)

myPlayer2/Utilities/ArtworkColorExtractor.swift                     (0.1)
myPlayer2/Models/ArtworkAssetSnapshot.swift                         (0.1)
myPlayer2/Services/Artwork/ArtworkAssetStore.swift                  (0.1)

myPlayer2/Services/Theme/ThemeStore.swift                           (0.1 + 0.2)
myPlayer2/Services/Lyrics/LyricsWebViewStore.swift                  (0.2)
myPlayer2/ViewModels/LyricsViewModel.swift                          (0.2)
myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift               (0.2)
myPlayer2/Resources/AMLL/index.html                                 (0.2)

myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift             (0.3)
myPlayer2/Skins/NowPlaying/ClassicLEDSkin.swift                     (0.4)
myPlayer2/Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift    (0.5)
```

### 接力提示（→ Phase 1）

1. **`ArtworkColorExtractor.cacheVersion` 命名约束**：未来任何对 `analyze` 或 palette 派生算法的非语义修改（例如重命名 helper、Unicode 标准化）**不**需要 bump 版本；只在算法输出**可能**变化时 bump。请在 Phase 2 升级决策引擎时同步 bump 这个常量。
2. **`CoverGradientBlurArtwork`（`FullscreenCoverGradientBlurSkin.swift`）目前是 dead code**（`makeArtwork` 返回 `EmptyView()`）。Phase 7 旧分叉清理时统一删除，本轮不动。
3. **`palette.text` 在歌词侧实际只剩 `textColor` JSON 路径在用**。Phase 5（"歌词颜色体系收敛"）建议进一步评估：是否把这条路径也下沉到 SemanticPalette 的歌词角色，让 LyricsWebViewStore 不再直接读 `ThemePalette`。
4. **`ThemeStore.backgroundColor` 仍由 `LyricsPanelView` 消费**：Phase 5 评估歌词面板背景策略时，可以一起考虑把 `palette.background` 也下沉。
5. **0.6 登记结论**：Phase 4 引入 Artwork Readability Profile 时，`MiniPlayerSpectrumView` 的 `usesDarkForeground` 应替换为语义化输入；那时再统一与 `LedMeterView` 的描述方式。

下一步：进入 Phase 1（颜色规则 token 化 + OKLCH 公共数学层）。

---

## Phase 1 — 颜色规则 token 化 + OKLCH 公共数学层

**完成日期**：2026-05-19。
**分支**：`refactor/oklch-color-system`。

### 本阶段目标

1. 把 `SemanticPaletteFactory` 与 `ArtworkColorAnalysis.isEffectivelyMonochrome` 的颜色决策阈值集中到 `ColorSystemTokens`，给 Phase 2（Ultra Dark / Near Monochrome 拆分、salient highlight palette）留一个**单点调参**的入口。
2. 把 `OKColor.swift` 从"LED-only 工具"提升为整个颜色系统的公共 OKLab/OKLCH 数学层，添加未来阶段会用到的原语（明度/色度钳制、chroma 软肩、hue 旋转、OKLab lerp）。
3. **不改任何决策逻辑、不改任何数值、不改 UI 颜色输出**。Phase 1 是"常量集中"+"数学层提级"，不是规则重写。

### 1.1 OKLCH 公共数学层

**结果**：已完成。

**改动**：

- `Utilities/OKColor.swift`：
  - 头部 docstring 从 "Used ONLY by LEDColorResolver, NOT a global color framework" 改为 "Public OKLab/OKLCH colour math layer ... used by `LEDColorResolver` today and by the wider colour system (Phase 2 onwards)"；明确定位为公共层。
  - `OKLab` / `OKLCH` 加上 `Equatable, Sendable` 一致性（便于 SwiftUI / actor 边界穿越）。
  - 新增 6 个公共原语（保持现有 API 不变）：
    - `normalizedHue(_:)` — 由 `private` 提升为 `static`（原本只在 `okLCHToNSColor` 内消费）。
    - `clampLightness(_:lo:hi:)`、`clampChroma(_:lo:hi:)` — 单维度钳制。
    - `chromaSoftShoulder(_:ceiling:softness:)` — `ColorMath.softShoulder` 的 OKLCH 等价，准备给 Phase 2 派色用。
    - `rotateHue(_:by:)` — OKLCH 内 hue 旋转 + 归一化。
    - `oklabLerp(_:_:t:)` — 通过 OKLab 中间表示插值，避免色相环绕。
- `Utilities/LEDColorResolver.swift`：**未改动**。LED 现有 OKLCH 路径（`baseColorForIndex` 内联的 OKLab lerp、`hueShift` 表、`hueAwareChromaCap` 表）都是 LED 视觉调参，提取的话会引入产品语义到公共层；保留在 LED 内部，等 Phase 6 配合 Tone Ladder 一起重组。

**决策**：

- **不动 LED 内部代码**。`oklabLerp` 已经作为公共原语提供，但 LED 的 `baseColorForIndex` 走的是 "index → t" 的特定计算（不是两点之间的 t），机械替换会引入风险；输出等价性需要单测保证，本轮不做。Phase 6 处理 Tone Ladder 时一起改。
- **不改 OKColor 已有函数签名**。所有现有 LED 调用点零改动。

### 1.2 ColorSystemTokens.swift（新增）

**结果**：已完成。

**新增文件**：`myPlayer2/Utilities/ColorSystemTokens.swift`。

**结构**：顶层 `nonisolated enum ColorSystemTokens`，按语义角色嵌套 enum 命名空间：

| 命名空间 | 内容（决策点） |
| --- | --- |
| `Accent` | `optimizedAccent` 的深/浅模式 L 钳制、hue-aware 明度下限（按 5 个色相段）、hue-aware 饱和度上限（按 9 个色相段）、warm-band hue guard 阈值、3 层低色覆盖的饱和度安全网 |
| `NearMonochrome` | `nearMonochromeAccent` 的 strict-mono 4 项判定门、深/浅模式 sat 上限与 floor、tone-lift 与 tone-drop 参数（base / pivot / range / max / floor / ceiling） |
| `FallbackAccent` | `useArtworkTint == false` 时用户 fallback accent 的深/浅 L 钳制 |
| `ReadableText` | `readableTextOnArtwork` 的深/浅 foreground 饱和度钳制范围与目标 L；`secondaryTextOnArtwork` 的透明度 |
| `CoverGradient` | `coverGradientDominant` 与 `coverGradientText` 的 sat/L 钳制（含强对比偏置） |
| `FullscreenLyric` | 切换"取 dominant 色"还是"取 best-text 源"的 colorfulness / hue confidence 双阈值 |
| `WindowLyric` | inactive 行透明度 |
| `EffectiveMonochrome` | `ArtworkColorAnalysis.isEffectivelyMonochrome` 的 5 个 OR 分支阈值（branch1–5 命名锁住，**便于 Phase 2 拆分 Ultra Dark / Near Monochrome 时单点重排**） |

**消费替换**：

- `Utilities/SemanticPalette.swift`：
  - `make`：fallback accent 分支 → `FallbackAccent.{dark,light}{Min,Max}L`。
  - `optimizedAccent`：warm-band guard、depth-aware L 下限、light-mode sat ceiling、saturation lift / floor / ceiling、light L scale 与钳制、3 层低色 sat 安全网 → 全部走 `Accent.*` token。
  - `nearMonochromeAccent`：average-hue 可用性、neutral hue 选择、strict-mono 4 判定、sat ceiling / floor / scale、dark tone-lift / light tone-drop → 全部走 `NearMonochrome.*`。
  - `readableTextOnArtwork`、`secondaryTextOnArtwork` → 走 `ReadableText.*`。
  - `windowLyricInactive` → 走 `WindowLyric.inactiveAlpha`。
  - `fullscreenLyricBase` → 走 `FullscreenLyric.*`。
  - `coverGradientDominant`、`coverGradientText` → 走 `CoverGradient.*`。
- `Utilities/ArtworkColorAnalysis.swift`：`analyzeInternal` 末尾的 `isMono` / `isExtremeTone` / `highSatIsOnlyTinyNoise` / `isEffectivelyMono` 五分支 OR 表达式、`usesDark` 边界 → 全部走 `EffectiveMonochrome.*`。

**决策**：

- **不动 LED OKLCH 调参**（neutral baseline、hue-aware chroma caps、level-driven L/C 曲线、hue shift 表）。这些是 LED 视觉产品参数，不是通用决策阈值；属 Phase 6 的 Tone Ladder 范畴。
- **不动 ArtworkColorExtractor 内部 palette filtering**（bucket weight、distinctness gap、WCAG contrast 循环、像素 alpha 阈值）。它们是 extractor private 行为，不是 palette 层的角色决策；改动量大且与 Phase 2 决策引擎升级强耦合，Phase 1 强行拆出来会两次返工。
- **保留两个范围常量的语义分离**（`NearMonochrome.darkLiftRange` 与 `darkLiftPivot` 数值相等都是 `0.42`，但语义不同）。原代码用同一字面量 `0.42` 同时充当 pivot 与 range，token 化后把它们分成两个独立常量；Phase 2 若需要打破"pivot=range"的耦合，只改 token 即可，不再需要回到调用点。light 分支同理：`lightDropPivot` (0.52) ≠ `lightDropRange` (0.42)，原代码已经分离。
- **5 个 isEffectivelyMonochrome 分支用 `branch1..5` 命名**。R4 J.2.c 已经标记 branch4 把 lightness 和 saturation 耦合到一个 OR 项里需要在 Phase 2 拆出；命名按位置标号而不是按"语义角色"，正是因为这些分支的语义还没正交化——一旦正交化（branch4 拆为独立的 "UltraDark" + "LowSat"），token 名也会同步改。Phase 1 仅冻结当前结构。

### 1.3 构建与测试

**构建**：

```
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

**单元测试**：未新增。原因：项目当前没有测试 target（参 `CLAUDE.md` "There is no dedicated test target in the project at the moment"），新增 test target + scheme 改动超出 Phase 1 范围（属基础设施工作）。OKLab/OKLCH 数学的等价性目前依赖：

1. LED 现有 OKLCH 路径未改动，视觉输出与 Phase 0 一致；
2. 新增的公共原语（`clampLightness` / `clampChroma` / `chromaSoftShoulder` / `rotateHue` / `oklabLerp`）暂时**无任何调用点**，等 Phase 2 起步时再消费 → 自动产生回归覆盖；
3. token 替换是纯字面量重命名，不重排算法，编译通过即等价。

**视觉等价性**：所有 token 数值与原字面量逐项核对一致（见 `SemanticPalette.swift` / `ArtworkColorAnalysis.swift` diff）。Phase 1 不修改任何决策路径，因此 UI 输出与 Phase 0 完成节点一致。

**残留 magic number 检查**：

- `SemanticPalette.swift` grep 浮点字面量：仅剩 `switch h` 内的 hue 区间端点（`0.10..<0.18` 等），属于决策路径**索引键**而非阈值——保留为字面量是正确的（这些值是色相轮分段，不参与运算）。
- `ArtworkColorAnalysis.swift` grep 浮点字面量：剩余项全部是 extractor 内部像素处理（alpha threshold、weight、bucket 形成、Welford 在线方差），不在 Phase 1 范围。

### 改动文件清单

```
myPlayer2/Utilities/ColorSystemTokens.swift             (新增)
myPlayer2/Utilities/OKColor.swift                       (公共原语扩展)
myPlayer2/Utilities/SemanticPalette.swift               (token 替换)
myPlayer2/Utilities/ArtworkColorAnalysis.swift          (isEffectivelyMonochrome token 替换)
docs/oklch-color-system-migration-log.md                (本节)
```

### 接力提示（→ Phase 2）

1. **branch4 解耦**：R4 J.2.c 已识别 `EffectiveMonochrome.branch4*` 把 `isExtremeTone`（lightness）与 `branch4AvgSaturation` / `branch4Colorfulness`（色彩信号）耦合在同一个 OR 项里。Phase 2 应把"极暗 / 极亮"作为独立的 `UltraDark` 维度从这里拆出来，token 也对应改名。
2. **OKLCH 数学层等价单测**：Phase 2 接入 `Accent.*` 的 OKLCH 等价版本时，需要先有针对 `OKColor.okLCHToNSColor` / `oklabLerp` 等的等价单测，避免颜色输出意外漂移。若 Phase 2 在没有测试 target 的情况下直接切换主派色链路，风险较大；建议优先补一个最小测试 target（哪怕只测颜色数学一个文件）。
3. **`ColorSystemTokens.Accent.darkSaturationLift / lightSaturationLift` 的轻微提升系数**（`1.06` / `1.02`）：R4 报告这两个是经验值，未来调研 OKLCH 等价 chroma lift 时需要保留视觉口径校准点。
4. **`NearMonochrome.darkLiftRange` 与 `darkLiftPivot` 数值相等但语义独立**：Phase 2 若需要让 dim 封面有更陡的 tone-lift 响应，只改 `darkLiftRange`（不动 pivot）即可；本来分离这两个常量就是为这个调参点准备的。
5. **`OKColor.chromaSoftShoulder` 与 `ColorMath.softShoulder` 数学相同但维度不同**：Phase 2 把 `optimizedAccent` 迁到 OKLCH 时，原来 `ColorMath.softShoulder(saturation, ...)` 应该改为 `OKColor.chromaSoftShoulder(lch, ceiling: ..., softness: ...)`。token 已经准备好（`Accent.lightSatShoulderSoftness`），切换时数值不变即可。
6. **`FallbackAccent.*L`** 是 HSL 钳制（走 `ColorMath.clampLightness`），不是 OKLCH。Phase 2 决定是否把 user fallback accent 也走 OKLCH 时，token 数值需要重新校准——HSL L 与 OKLCH L 不是 1:1 等价。

下一步：进入 Phase 2（艺术取色决策引擎 2.0 — Ultra Dark / Near Monochrome 拆分、salient highlight palette）。
