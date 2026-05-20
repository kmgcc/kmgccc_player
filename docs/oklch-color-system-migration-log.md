# OKLCH Color System Migration Log

本日志用于记录颜色系统重构与 OKLCH 迁移过程中的实际改动、验证结果、决策与后续接力点。\
\
设计文档：`docs/oklch-migration-color-system-investigation.md`（R1–R4 调查报告）。\
\
施工计划：`docs/oklch-color-system-execution-plan.md`。

每条记录至少给出：本阶段目标、改动文件清单、决策点、验证结果、对后续阶段的"接力提示"。

***

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

```javascript
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

```text
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

**死字段残留 grep**：全部 0 命中（仅剩本次清理的说明性注释）。

**视觉验证**：本轮**只完成代码级修复**。0.4 / 0.5 的视觉对比需在浅色 / 深色 / 多种 artwork luma 下手测确认；尚未做。

### 改动文件清单

```text
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

1. `ArtworkColorExtractor.cacheVersion` **命名约束**：未来任何对 `analyze` 或 palette 派生算法的非语义修改（例如重命名 helper、Unicode 标准化）**不**需要 bump 版本；只在算法输出**可能**变化时 bump。请在 Phase 2 升级决策引擎时同步 bump 这个常量。
2. `CoverGradientBlurArtwork`**（**`FullscreenCoverGradientBlurSkin.swift`**）目前是 dead code**（`makeArtwork` 返回 `EmptyView()`）。Phase 7 旧分叉清理时统一删除，本轮不动。
3. `palette.text` **在歌词侧实际只剩** `textColor` **JSON 路径在用**。Phase 5（"歌词颜色体系收敛"）建议进一步评估：是否把这条路径也下沉到 SemanticPalette 的歌词角色，让 LyricsWebViewStore 不再直接读 `ThemePalette`。
4. `ThemeStore.backgroundColor` **仍由** `LyricsPanelView` **消费**：Phase 5 评估歌词面板背景策略时，可以一起考虑把 `palette.background` 也下沉。
5. **0.6 登记结论**：Phase 4 引入 Artwork Readability Profile 时，`MiniPlayerSpectrumView` 的 `usesDarkForeground` 应替换为语义化输入；那时再统一与 `LedMeterView` 的描述方式。

下一步：进入 Phase 1（颜色规则 token 化 + OKLCH 公共数学层）。

***

## Phase 1 — 颜色规则 token 化 + OKLCH 公共数学层

**完成日期**：2026-05-19。\
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

| 命名空间                  | 内容（决策点）                                                                                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `Accent`              | `optimizedAccent` 的深/浅模式 L 钳制、hue-aware 明度下限（按 5 个色相段）、hue-aware 饱和度上限（按 9 个色相段）、warm-band hue guard 阈值、3 层低色覆盖的饱和度安全网                 |
| `NearMonochrome`      | `nearMonochromeAccent` 的 strict-mono 4 项判定门、深/浅模式 sat 上限与 floor、tone-lift 与 tone-drop 参数（base / pivot / range / max / floor / ceiling） |
| `FallbackAccent`      | `useArtworkTint == false` 时用户 fallback accent 的深/浅 L 钳制                                                                                |
| `ReadableText`        | `readableTextOnArtwork` 的深/浅 foreground 饱和度钳制范围与目标 L；`secondaryTextOnArtwork` 的透明度                                                     |
| `CoverGradient`       | `coverGradientDominant` 与 `coverGradientText` 的 sat/L 钳制（含强对比偏置）                                                                       |
| `FullscreenLyric`     | 切换"取 dominant 色"还是"取 best-text 源"的 colorfulness / hue confidence 双阈值                                                                   |
| `WindowLyric`         | inactive 行透明度                                                                                                                          |
| `EffectiveMonochrome` | `ArtworkColorAnalysis.isEffectivelyMonochrome` 的 5 个 OR 分支阈值（branch1–5 命名锁住，**便于 Phase 2 拆分 Ultra Dark / Near Monochrome 时单点重排**）      |

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
- **5 个 isEffectivelyMonochrome 分支用** `branch1..5` **命名**。R4 J.2.c 已经标记 branch4 把 lightness 和 saturation 耦合到一个 OR 项里需要在 Phase 2 拆出；命名按位置标号而不是按"语义角色"，正是因为这些分支的语义还没正交化——一旦正交化（branch4 拆为独立的 "UltraDark" + "LowSat"），token 名也会同步改。Phase 1 仅冻结当前结构。

### 1.3 构建与测试

**构建**：

```text
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

```text
myPlayer2/Utilities/ColorSystemTokens.swift             (新增)
myPlayer2/Utilities/OKColor.swift                       (公共原语扩展)
myPlayer2/Utilities/SemanticPalette.swift               (token 替换)
myPlayer2/Utilities/ArtworkColorAnalysis.swift          (isEffectivelyMonochrome token 替换)
docs/oklch-color-system-migration-log.md                (本节)
```

### 接力提示（→ Phase 2）

1. **branch4 解耦**：R4 J.2.c 已识别 `EffectiveMonochrome.branch4*` 把 `isExtremeTone`（lightness）与 `branch4AvgSaturation` / `branch4Colorfulness`（色彩信号）耦合在同一个 OR 项里。Phase 2 应把"极暗 / 极亮"作为独立的 `UltraDark` 维度从这里拆出来，token 也对应改名。
2. **OKLCH 数学层等价单测**：Phase 2 接入 `Accent.*` 的 OKLCH 等价版本时，需要先有针对 `OKColor.okLCHToNSColor` / `oklabLerp` 等的等价单测，避免颜色输出意外漂移。若 Phase 2 在没有测试 target 的情况下直接切换主派色链路，风险较大；建议优先补一个最小测试 target（哪怕只测颜色数学一个文件）。
3. `ColorSystemTokens.Accent.darkSaturationLift / lightSaturationLift` **的轻微提升系数**（`1.06` / `1.02`）：R4 报告这两个是经验值，未来调研 OKLCH 等价 chroma lift 时需要保留视觉口径校准点。
4. `NearMonochrome.darkLiftRange` **与** `darkLiftPivot` **数值相等但语义独立**：Phase 2 若需要让 dim 封面有更陡的 tone-lift 响应，只改 `darkLiftRange`（不动 pivot）即可；本来分离这两个常量就是为这个调参点准备的。
5. `OKColor.chromaSoftShoulder` **与** `ColorMath.softShoulder` **数学相同但维度不同**：Phase 2 把 `optimizedAccent` 迁到 OKLCH 时，原来 `ColorMath.softShoulder(saturation, ...)` 应该改为 `OKColor.chromaSoftShoulder(lch, ceiling: ..., softness: ...)`。token 已经准备好（`Accent.lightSatShoulderSoftness`），切换时数值不变即可。
6. `FallbackAccent.*L` 是 HSL 钳制（走 `ColorMath.clampLightness`），不是 OKLCH。Phase 2 决定是否把 user fallback accent 也走 OKLCH 时，token 数值需要重新校准——HSL L 与 OKLCH L 不是 1:1 等价。

下一步：进入 Phase 2（艺术取色决策引擎 2.0 — Ultra Dark / Near Monochrome 拆分、salient highlight palette）。

***

## Phase 2 — 艺术取色决策引擎 2.0

**完成日期**：2026-05-20。\
**分支**：`refactor/oklch-color-system`。

### 本阶段目标

四件事一次性完成（不拆 2A/2B/2C）：

1. **Ultra Dark 与 Near Monochrome 分离建模**：两个正交维度，分别由亮度与色度信号决定，可以 (T,T) / (T,F) / (F,T) / (F,F) 四象限。
2. **重构 `isEffectivelyMonochrome`**：拆掉 R4 J.2.c 标注的 branch 4（`isExtremeTone && low sat` 把"极暗"误归入"无色相"），让旧字段名继续可用但语义干净化。
3. **小面积高显著色结构化输出**：`ArtworkColorAnalysis.salientHighlightPalette`。
4. **多色 artwork palette 基础能力**：`ArtworkColorAnalysis.displayPalette`，给 Phase 3 的 Home Shapes / BKArt / Spectrum 接入做数据准备。

本阶段不切换任何 UI 消费路径；只新增分析结果与结构能力。

### 2.1 测试基础设施 — 内嵌自检入口

**结果**：未新增 XCTest target（项目无测试 target，扩工程配置超 Phase 2 边界）。改用项目允许的备选方案 — **debug-only 自检入口**。

**新增文件**：`myPlayer2/Utilities/ColorSystemSelfCheck.swift`。

- 一个 `nonisolated enum ColorSystemSelfCheck`，通过环境变量 `COLOR_SYSTEM_SELF_CHECK=1` 在 `KmgcccPlayerApp.init()` 最前面触发；同步执行后 `exit(0)`（全部通过）或 `exit(1)`（任一失败）。
- 通过新加的 `ArtworkColorExtractor.analyzeSyntheticSample(pixels:side:)` 把合成 RGBA buffer 直接喂给 `analyzeInternal`，绕过 `CGImageSource`，结果可重复、可断言。
- 覆盖以下场景，每条单独 pass/fail：

  | 类别 | 场景 | 期望 |
  | --- | --- | --- |
  | Quadrant | UltraDark 彩色（deep navy 10,25,70） | `UltraDark=true, NearMono=false` |
  | Quadrant | UltraDark 近灰（15,15,15） | `UltraDark=true, NearMono=true` |
  | Quadrant | 正常彩色（mid teal 40,180,160） | `UltraDark=false, NearMono=false` |
  | Quadrant | 正常灰白（200,200,200） | `UltraDark=false, NearMono=true` |
  | OKColor | RGB→OKLab→OKLCH→OKLab→RGB round-trip | worst-channel ΔRGB < 0.005 |
  | OKColor | `clampLightness` / `clampChroma` | 精确钳制（误差 < 1e-9） |
  | OKColor | `normalizedHue` / `rotateHue` | 1.20→0.20、-0.10→0.90、0.95+0.10→0.05 |
  | OKColor | `chromaSoftShoulder` | input≤ceiling 透传；input≫ceiling 渐近至 ceiling+softness |
  | Salient | 95% 黑 + 5% 鲜黄 | salient 含黄、displayPalette 含黄、即使整体 nearMono=true |
  | Salient | 90% navy + 10% orange | salient 含 orange、displayPalette 至少 2 色 |
  | Salient | 80% dark canvas + 20% red title | salient 含 red |
  | Salient | 99% 黑 + 0.5%/0.5% 红/蓝噪点 | salient 为空 |
  | Display | 25%×4 红/绿/蓝/琥珀 | displayPalette ≥ 3 项、distinctHues ≥ 3、非 nearMono |
  | Display | 纯灰封面 | nearMono=true 且 displayPalette.count ≤ `nearMonoMaxCount`（=2） |

**自检运行结果**（2026-05-20）：

```
ColorSystemSelfCheck — 2026-05-20 上午1:01:54 +0000
cacheVersion=orthogonal-decision-v3
...
Result: ALL PASS
EXIT=0
```

14/14 全部通过。完整输出含每个场景的关键诊断字段（`avgHslL`/`luma`/`avgSat`/`colorfulness`/`domBri`），便于 Phase 3 调试同一封面行为时回溯。

**决策**：不强求 XCTest。Phase 2 自检入口覆盖了"四象限 + 显著色 + 多色 palette + OKLCH 数学"四个 Phase 2 真正引入的决策点；后续 Phase 3 若需要更细的 UI-端断言（例如某具体 cover 应触发哪个分支），仍建议补 XCTest target——但 Phase 2 自身的等价性已不依赖它。

### 2.2 OKColor 数学层基础回归

**结果**：自检确认现有 6 个公共原语行为正确。

| 原语 | 自检断言 |
| --- | --- |
| `nsColorToOKLCH` / `okLCHToNSColor` | 四种典型 RGB（蓝、琥珀、中灰、暗色）round-trip worst-channel ΔRGB = 0.000 |
| `clampLightness(_:lo:hi:)` | L=0.95 → clamp(0.20,0.50) → 0.50；不动 chroma |
| `clampChroma(_:lo:hi:)` | C=0.20 → clamp(0.05,0.10) → 0.10；不动 lightness |
| `normalizedHue(_:)` | 1.20→0.20, -0.10→0.90 |
| `rotateHue(_:by:)` | 0.95+0.10 → 0.05（含环绕） |
| `chromaSoftShoulder(_:ceiling:softness:)` | 0.05↦0.05（透传）；1.00↦0.147（渐近至 ceiling+softness=0.15） |

LED `LEDColorResolver` 内部 OKLCH 调用未触动；Phase 6 Tone Ladder 再决定是否搬迁。

### 2.3 ArtworkColorAnalysis — 新字段与正交化

**改动**：`myPlayer2/Utilities/ArtworkColorAnalysis.swift`。

新增字段：

| 字段 | 类型 | 语义 |
| --- | --- | --- |
| `weightedLuma` | `CGFloat` | WCAG relative luminance（pixel-weighted），用于 UltraDark 的感知补充门 |
| `dominantBrightness` | `CGFloat` | dominant bucket HSB B，用于排除"黑底单亮元素" |
| `isUltraDark` | `Bool` | 纯亮度维度 — 极暗封面 |
| `isNearMonochrome` | `Bool` | 纯色度维度 — 无可信色相 |
| `salientHighlightPalette` | `[NSColor]` | 小面积高显著色（点睛色） |
| `displayPalette` | `[NSColor]` | 质控合并 palette（Phase 3 多色消费基础） |

保留并重新定义的字段：

- `isEffectivelyMonochrome`：现在是 `isNearMonochrome` 的别名，**只用于向后兼容**（LED resolver / Home shapes / BKArt / ThemeStore log）。其语义换成"纯色度判定"——旧 branch 4（亮度耦合）已删除。

**正交化后的判定**：

`isNearMonochrome` 仅由四个色度 OR 分支决定（`ColorSystemTokens.NearMonochromeProfile`）：

1. **strict mono**：`colorfulness<0.04 && avgSat<0.10`（同旧 branch 1）
2. **low**：`colorfulness<0.10 && avgSat<0.16 && largestHighSat<0.12`（同旧 branch 2）
3. **subtle**：`avgSat<0.105 && colorfulness<0.14 && largestHighSat<0.16`（同旧 branch 3）
4. **dominant bucket fallback**：`dominantSat<0.18 && colorfulness<0.16 && avgSat<0.18`（同旧 branch 5）

旧 branch 4（`isExtremeTone && avgSat<0.18 && colorfulness<0.16 && !hasStrong`）**已删除**。

`isUltraDark` 由三个纯亮度门组成（`ColorSystemTokens.UltraDark`）：

- `avgHslL ≤ 0.22`：HSL 平均亮度切线
- `avgLuma ≤ 0.18`：WCAG 感知亮度（补足 HSL 在霓虹色上的过估）
- `dominantBrightness ≤ 0.60`：排除"黑底单亮元素"（这种是普通封面 + 亮色 element，不是 UltraDark）

### 2.4 isEffectivelyMonochrome 重构 — 影响下游消费者的边界说明

旧定义命中而新定义不再命中的封面，**仅有一类**：

> 极暗（`avgHslL<0.18 || avgHslL>0.86`）+ 中低饱和（`avgSat<0.18 && colorfulness<0.16`）+ 没有大块强彩 + 但 dominant bucket 自带 sat≥0.18 的封面。

这正是 R4 J.2.d 给出的"深紫 / 夜蓝 / 酒红黑底"边界例 — 它们应该走 `optimizedAccent` 正常 path、保留色相。Phase 2 把它们从 nearMono path 解放出来。

**下游影响**：

- `LEDColorResolver`：`isEffectivelyMonochrome` 触发 `monoIndexColor` 与 `inactiveFromBase` 的 neutral fallback。新逻辑下"深紫 / 夜蓝"封面不再被强制 fallback，LED 会沿用其原色相。**这是 K.2 期望的行为修正，不是回退**。
- `HomeAmbientShapesBackground`：`isEffectivelyMonochrome` 用作 `isLowColor` 判定。同上，"极暗有色"封面不再被强行视作低色相 → 进入正常彩色 shapes 路径。
- `BKColorEngine`：使用的是 `isMonochrome`（strict 严格 mono），**未受影响**。
- `ThemeStore` 日志：标注同步显示更新后的判定。

这些行为差异仅出现在"极暗 + 中低饱和但有真实色相"的特定封面上，**正是本次重构要修正的对象**。其它封面在新旧定义下结果完全一致（自检的"normal colored" / "near-mono" 都已覆盖）。

### 2.5 SalientHighlightPalette 实现

**新增**：`ArtworkColorExtractor.computeSalientHighlights(buckets:totalWeight:dominantHue:)`。

**算法**：复用 `analyzeInternal` 已经构建的 48-hue bucket histogram，逐桶过滤：

| 门 | token | 设计意图 |
| --- | --- | --- |
| `s ≥ 0.40` | `SalientHighlight.minSaturation` | 排除低彩 tint |
| `b ≥ 0.30` | `SalientHighlight.minBrightness` | 排除暗噪点 |
| `area ∈ [0.015, 0.30]` | `SalientHighlight.minAreaShare` / `maxAreaShare` | 既不是噪点也不是主导色 |
| `bucket.weight ≥ 0.008 × total` | `SalientHighlight.noiseFloorAbsolute` | 绝对权重防 single-pixel noise |

通过后按 `bucket.weight × (1 + sat × 0.5)` 排序，按 hue gap ≥ 0.05 OR RGB distance ≥ 0.14 去重，取前 4。

**关键设计**：salient palette **不再受 `isNearMonochrome` 阻断**。理由：95% 灰黑 + 5% 鲜黄是"整体 nearMono 但点睛色真实存在"的典型场景；如果整张图就只剩这 5% 是颜色信息，那它就是这张封面的真颜色。

**自检覆盖**：

- 95% 黑 + 5% 鲜黄 (255,200,30) → salient.count=1、含黄、displayPalette 也含黄 ✓
- 90% navy (10,25,70) + 10% orange (255,130,30) → salient.count=1、含 orange、display.count=3 ✓
- 80% 暗 canvas + 20% red title → salient.count=1、含 red ✓
- 99% 黑 + 0.5%×2 高彩噪点 → salient.count=0（绝对权重门拦截）✓

未触动 `ArtworkColorExtractor` 既有的 `uiThemePalette` / `uiThemePaletteRich` 算法 — 它们继续按既有逻辑生成 topPalette / richPalette；salient 是新增的第三条独立通道。

### 2.6 DisplayPalette 实现

**新增**：`ArtworkColorExtractor.computeDisplayPalette(top:salient:rich:isNearMonochrome:)`。

**合并顺序**：`topPalette` → `salientHighlightPalette` → `richPalette`。

每个候选与已选成员按 hue gap ≥ 0.05 OR RGB distance ≥ 0.14 去重。

**封面色彩贫乏时的克制（K.3）**：

- `isNearMonochrome == true` 时 **拒绝合入 `richPalette`**，并将上限收紧到 `nearMonoMaxCount = 2`。
- salient 仍允许通过（点睛色是真实信息）。

正常封面上限为 `maxCount = 6`。

**自检覆盖**：

- 4 色等分 → display.count=6、distinctHues=4、非 nearMono ✓
- 纯灰 → nearMono=true、display.count=1（≤ 上限 2）✓
- 95% 黑 + 5% 黄（nearMono=true）→ display.count=1，含黄（top 空，salient 进入）✓
- 90% navy + 10% orange（非 nearMono）→ display.count=3 ✓

### 2.7 cacheVersion bump

**改动**：`ArtworkColorExtractor.cacheVersion`：`"semantic-near-mono-v2"` → `"orthogonal-decision-v3"`。

**理由**：

- 分析输出新增 6 字段（`weightedLuma` / `dominantBrightness` / `isUltraDark` / `isNearMonochrome` / `salientHighlightPalette` / `displayPalette`）。
- `isEffectivelyMonochrome` 语义虽未改字段名，但实际判定逻辑剥离了旧 branch 4，特定封面（極暗有色）的结果会变化。
- `ArtworkAssetStore` / `ThemeStore.dominantColorCache` 的 key 模板已经在 Phase 0 把 cacheVersion 折进 prefix；bump 后旧 entry 整体失效，无 partial-hydration 风险（snapshot 不持久化，只内存缓存）。
- 兼容策略：snapshot 与 analysis 都是 in-memory + lazy compute，无外部存储字段，无需向后解码。

### 2.8 token 命名空间整理

**改动**：`myPlayer2/Utilities/ColorSystemTokens.swift`。

- **新增**：
  - `UltraDark`（`cutoffAvgHslL` / `cutoffWcagLuma` / `dominantBrightnessCeiling`）
  - `NearMonochromeProfile`（4 个 OR 分支阈值，命名按"strict / low / subtle / dominantBucket"语义化）
  - `ReadabilityForeground.usesDarkAvgHslL`（从旧 EffectiveMonochrome 抽出）
  - `SalientHighlight`（10 个 token，含 maxCount、area share、dedup gap）
  - `DisplayPalette`（4 个 token，含 maxCount、nearMonoMaxCount、hue/rgb distinct gap）
- **重命名**（语义化）：旧 `EffectiveMonochrome.branch{1..5}*` → 新 `NearMonochromeProfile.{strict,low,subtle,dominantBucket}*`。数值未变（仅 branch4 整组删除）。
- **保留并标记 deprecated**：旧 `EffectiveMonochrome` 命名空间仍存在（仅留下 forwarding 别名），加 `@available(*, deprecated)`，避免任何潜在外部 grep 直接失效。

### 2.9 SemanticPaletteFactory 命名澄清

**改动**：`myPlayer2/Utilities/SemanticPalette.swift`。

- `optimizedAccent` 内部由 `analysis.isEffectivelyMonochrome` 改读 `analysis.isNearMonochrome`（同义但命名更准确）。
- `nearMonochromeAccent` 顶部加 docstring：明确职责是"anti-fake-color"，**不**再承担"极暗保护"。
- 数学逻辑零变化（数值、分支、token 均未动）。这两步纯命名清理。

### 2.10 调试 / 诊断能力

`ColorSystemSelfCheck` 输出本身就是一份结构化诊断（每条场景都打印 `avgHslL / luma / avgSat / colorfulness / domBri / salient.count / display.count / nearMono`）。Phase 3 调试同一封面行为时可以再 wire 一个 `ColorSystemSelfCheck.describe(analysis:)` 复用同样格式。

**未做**：没有为正在播放的 artwork 加 runtime debug log（避免扩大成本）。Phase 3 若需要，复用 `describe(_:)` 即可。

### 2.11 构建验证

```text
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

自检：

```text
COLOR_SYSTEM_SELF_CHECK=1 \
  ./kmgccc_player.app/Contents/MacOS/kmgccc_player
→ Result: ALL PASS (14/14)
→ EXIT=0
```

### 改动文件清单

```text
myPlayer2/Utilities/ColorSystemTokens.swift            (新增 UltraDark / NearMonochromeProfile / SalientHighlight / DisplayPalette / ReadabilityForeground 命名空间；保留 deprecated EffectiveMonochrome)
myPlayer2/Utilities/ArtworkColorAnalysis.swift         (新增 6 字段；isEffectivelyMonochrome 重定义为 isNearMonochrome 别名)
myPlayer2/Utilities/ArtworkColorExtractor.swift        (cacheVersion bump → v3；computeSalientHighlights / computeDisplayPalette / analyzeSyntheticSample 新增)
myPlayer2/Utilities/SemanticPalette.swift              (命名清理：optimizedAccent 改读 isNearMonochrome；nearMonochromeAccent 加 docstring)
myPlayer2/Utilities/ColorSystemSelfCheck.swift         (新增 — 自检入口)
myPlayer2/myPlayer2App.swift                           (init() 顶部加一行 ColorSystemSelfCheck.runIfRequested())
docs/oklch-color-system-migration-log.md               (本节)
```

### 接力提示（→ Phase 3）

1. **`displayPalette` 暂无消费者**。Phase 3 接入 Home Shapes / BKArt / Spectrum 时，应读 `analysis.displayPalette`，**不要**再去自己跑 `uiThemePaletteRich` 或 hue 旋转构造 palette（K.1 / K.3）。本期已提供质控合并；UI 侧只需做投影到几何元素的工作。
2. **`isUltraDark` 暂无消费者**。Phase 3 决定是否在 SemanticPaletteFactory 加 `(UltraDark=T, NearMono=F)` 分支（让 deep navy / midnight teal / dark crimson 保留暗 L 而非被 darkMinL 提到 0.74）时，token 已就位（`Accent.darkLightnessCeiling` 仍是上限，下限可考虑用 `UltraDark.cutoffAvgHslL` 派生一个 `darkMinLUltraDark`）。
3. **`salientHighlightPalette` 暂无消费者**。Phase 3 / 4 决定是否让歌词色 / 频谱 / Home Shapes 优先取 salient 作为点睛时再接入。本期数据已可用。
4. **OKLCH 等价校准**：Phase 3 把 `optimizedAccent` 整体迁到 OKLCH 时，建议先在 `ColorSystemSelfCheck` 加 `Accent.*` 的 HSL ↔ OKLCH 等价对照（例如 `optimizedAccent` 对相同 analysis 的旧/新输出 ΔL < 0.02、ΔC < 0.02）。
5. **LED 内 OKLCH 路径仍未触动**。`LEDColorResolver.baseColorForIndex` 内联的 OKLab lerp 应该在 Phase 6 Tone Ladder 时统一改成 `OKColor.oklabLerp`；Phase 2 不动 LED 视觉参数。
6. **`isEffectivelyMonochrome` 别名**：当所有现有消费者切到 `isNearMonochrome` 后（Phase 3 末或 Phase 4），可在该次 commit 一起删除别名字段。本期保留是为避免在颜色系统重构同时改动 LED / Home / BKArt 的读路径。
7. **branch 4 删除带来的实际行为变化**：仅命中"极暗 + 中低饱和但 dominant bucket 有 sat ≥ 0.18 的有色封面"。Phase 3 上 UI 之前，建议在浅色/暗色模式下手测以下 artwork：
   - 暗紫色（如 Lana Del Rey "Born to Die" cover 类型）
   - 夜蓝（深空摄影、夜景封面）
   - 暗红 / 酒红黑底（如 Radiohead "Kid A" 类型）
   预期视觉变化：accent 不再被强提到 0.66-0.74 的灰蓝带，能更忠实反映封面色相。

---

## Phase 2 收尾补记（2026-05-20）

完成 Phase 2 主提交（`52857e4`）后对两处可加固点的复核与最小修订。两项变更都不改 UI、不扩 token 数量、不调阈值，纯属算法序与编译条件层面的强化。

### 收尾.1 — displayPalette salient 优先级

**发现的脆弱性**：原 `computeDisplayPalette` 顺序为 `top → salient → rich`。在 `isNearMonochrome=true` 时 `cap = nearMonoMaxCount = 2`，`topPalette` 的两个可分辨 grey bucket（如 (15,15,15) 与 (60,60,60)，RGB gap≈0.176 > `rgbDistinctGap` 0.14）会先于 salient 把两个槽占满，让 5% 高显著黄被挤出 `displayPalette`。原本通过的 `checkSalientYellowOnBlack` 之所以没暴露问题，是因为该场景里 `uiThemePalette` 走 near-mono 快速分支只返回 1 个 grey —— 偶发通过，并非设计保证。

**修订**（`ArtworkColorExtractor.swift` `computeDisplayPalette`）：合并顺序改为

1. `top.first` —— 主导核心色，绝不被 salient 顶掉；
2. `salient[*]` —— 在 `top` 尾部之前进入，保证其至少与 top 第二项竞争；
3. `top.dropFirst()` —— 其余 top 按原面积权重顺序；
4. `rich[*]` —— 仅在非 near-mono 走完；
   全部仍受 `hueDistinctGap` / `rgbDistinctGap` 与 cap 约束。

**为什么不动 token**：本质是排序问题，不是阈值问题。新增 token 反而稀释意图。

**对正常封面（cap=6）的影响**：`topPalette` 调用 `targetCount=4`，salient 最多 `maxCount=4`，6 槽足够容纳 `top[0] + salient(≤4) + top[1..3]` 中的多数主项，仅当 salient 极多时会把 `top` 尾部挤掉，但此时挤掉的是面积更小的 top 候选，符合"salient 的视觉点睛优先于 top 弱尾"的语义。`rich` 在正常封面仅作为补位。

**新增自检**：`checkDisplayPaletteSalientPriorityUnderContention` —— 50%(15,15,15) + 45%(60,60,60) + 5%(255,200,30)。
- 验证 `isNearMonochrome=true`、`top.count == 2`（两个可辨灰度都进 topPalette）、`display.count == 2`、`yellow ∈ displayPalette`、`yellow ∈ salientHighlightPalette`。
- 旧序下该测试会失败（两 grey 占满 cap，黄被丢弃）；新序通过。这是从"偶发正确"升级到"机制保证"的硬证据。

### 收尾.2 — ColorSystemSelfCheck Release 安全

**原状**：`runIfRequested()` 只用 env var (`COLOR_SYSTEM_SELF_CHECK=1`) 作为门。理论上一个 Release 包如果用户/CI 误设该 env var，进程会在 `myPlayer2App.init()` 顶部 `exit()` —— 这是发布隐患。

**修订**（`ColorSystemSelfCheck.swift`）：在 `runIfRequested()` 体外加 `#if DEBUG ... #endif`。Release 构建直接把整段编译掉，env var 不可达、`exit` 不可达；Debug 构建仍叠加 env var 二段门保证日常 Debug 启动 no-op。

**验证矩阵**（实际执行）：
| 配置 | env var | 行为 | 结果 |
|---|---|---|---|
| Debug | `COLOR_SYSTEM_SELF_CHECK=1` | 跑 14 + 1 = 15 个 check，`exit(0)` | `EXIT=0` ALL PASS |
| Debug | 未设置 | 正常启动 GUI | 3s 后进程仍存活 → no-op |
| Release | `COLOR_SYSTEM_SELF_CHECK=1` | 正常启动 GUI（`#if DEBUG` 已剥离） | 3s 后进程仍存活 → 无 self-check 执行 |
| Release | 未设置 | 正常启动 GUI | 与上一致 |

**为什么用 `#if DEBUG` 而非 Configuration 检查**：`#if DEBUG` 在编译期消除代码与符号，链接器都看不到 `runAll` 系列函数 —— 既排除运行时风险，也避免 Release 包里携带"看上去可调用"的 entry。Configuration 字符串检查只能做运行时跳过，安全等级更低。

### 实际修改的文件（本收尾批次）

- `myPlayer2/Utilities/ArtworkColorExtractor.swift` —— `computeDisplayPalette` 顺序重排 + 长 docstring 说明优先级语义；无新 token。
- `myPlayer2/Utilities/ColorSystemSelfCheck.swift` —— `runIfRequested()` 加 `#if DEBUG` 包裹 + 文件头说明 Release 安全；新增 `checkDisplayPaletteSalientPriorityUnderContention`。
- `docs/oklch-color-system-migration-log.md` —— 本节。

### 验证

- `xcodebuild ... -configuration Debug ... build` → `** BUILD SUCCEEDED **`
- `xcodebuild ... -configuration Release ... build` → `** BUILD SUCCEEDED **`
- `COLOR_SYSTEM_SELF_CHECK=1 ./kmgccc_player`（Debug）→ 15/15 PASS，`EXIT=0`
- Debug 无 env var → 3s 进程存活
- Release with env var → 3s 进程存活（self-check 被 `#if DEBUG` 完全剥离）

***

## Phase 3 — 装饰色与真实多色分发

**完成日期**：2026-05-20。\
**分支**：`refactor/oklch-color-system`。

### 本阶段目标

第一次把"真实 artwork 多色"正式接入 UI 消费端：

1. **Home Shapes**：使用 artwork 多色（`displayPalette`）而非单 accent + hue rotate。
2. **BKArt**：保留 Ultra Dark 保护，但用 `displayPalette` 启用真正多色背景；`isUltraDark` 进入晚期 UltraDark 判定。
3. **Spectrum**：使用 artwork 两色 / 多色填充（`displayPalette.prefix(2)`），salient 自然成为右侧/高频段颜色；单色封面降级为同色调 L 变体（不再 fallback 中性灰，不再 hue rotate 假多色）。

本期严格遵守 Phase 3 边界：不改 MiniPlayer 控件色语义化、不改歌词、不改 Header、不做 Tone Ladder、不动 LED；只改"颜色来源 + 场景化处理"。

### 3.1 Home Shapes — displayPalette + OKLCH 背景化

**改动**：`myPlayer2/Views/Home/HomeAmbientShapesBackground.swift`。

**新接入路径**：

`HomeAmbientPalette.palette(...)` 顶部新增 Phase 3 主路径：

```text
analysis.displayPalette  (top.first → salient → top.tail → rich)
   ↓
project(_:targets:)       OKLCH per-mode tint
   ↓
6-entry palette  ([NSColor] for shape colorIndex assignment)
```

`project(_:targets:)` 实现：

- `OKColor.nsColorToOKLCH(color)` 拿到 OKLCH。
- 按 `AmbientTuning` 对应深/浅、是否 ultraDark、是否 nearMono 取四象限对应钳制带：
  | 模式 | UltraDark | NearMono | L 范围 | chromaCeiling |
  | --- | --- | --- | --- | --- |
  | Dark | ✓ | – | 0.10–0.26 | 0.030 / 0.075 |
  | Dark | – | ✓ | 0.16–0.28 | 0.038 |
  | Dark | – | – | 0.18–0.34 | 0.115 |
  | Light | – | ✓ | 0.78–0.90 | 0.022 |
  | Light | – | – | 0.74–0.86 | 0.058 |
- `okLCHToNSColor(tuned, alpha: 1)`。

**Padding 策略（K.3 — 不强行伪造多色）**：

`displayPalette.count < 6` 时不再 hue-rotate，改为对真实色做 `tonalVariant(of:lDelta:targets:)` —— **只动 L，不动 H**，交替正负。padded 颜色仍可被签名识别为 palette 衍生项。

**Fallback**：

仅当 `analysis == nil`（无 artwork / extractor 失败）或 `displayPalette` 完全为空时，才走原有单 source-color + 6 hue-rotate variants 路径。这是 Phase 3 唯一保留的 hue-rotate 代码，触发频率从"正常路径"降级到"无 analysis 的退化路径"。

**缓存签名增强**：

`PaletteSignature` 增加三个字段：`isUltraDark`、`displayPaletteHash`、`salientPaletteHash`。这样同一 sourceColor 但 analysis.displayPalette 不同时能正确重建（之前仅根据 sourceColor + colorfulness + avgSaturation + isEffectivelyMonochrome 判断，会漏掉 displayPalette 内部变化）。`isEffectivelyMonochrome` 字段名保留但 Phase 2 后实际读 `isNearMonochrome`。

**调试日志**：

`LogConfig.isCategoryEnabled(.ui)` 开启时，每次 palette 重建打印一行：

```text
[HomeAmbient/palette] scheme=dark nearMono=false ultraDark=true hasSalient=true colors=[#... ...]
```

### 3.2 BKArt — displayPalette 多色背景 + 强化 Ultra Dark

**改动**：`myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift`。

**Palette 源切换**：

`applyResolvedPalette(...)` 通过新静态方法 `selectedExtractedPalette(analysis:basePalette:richPalette:)` 决定喂给 `BKColorEngine.make(extracted:...)` 的 palette：

1. `analysis?.displayPalette` 非空 → 使用 displayPalette（Phase 2 质控合并 = top.first + salient + top.tail + rich，受 hueDistinctGap / rgbDistinctGap / cap 6 约束）。
2. 否则 richPalette。
3. 否则 basePalette。
4. 否则 `BKArtBackgroundView.fallbackPalette`。

**Salient 落点**：通过 displayPalette 的预排序（top.first → salient → ...），salient 进入 `BKColorEngine` 的候选 palette 输入。引擎内部已有的 `enforceCandidateHueSource` / `enforceDominantHueAffinity` / `makeShapePool` 会让 salient 自然成为 **shape pool / accent candidate**，而不是直接占据 bg 主色——这正符合 §4.4 "salient 不要直接作为最大面积主背景，可以作为次级 shape 色 / 局部强调色"的要求。

**Ultra Dark 保护强化**：

`isUltraDarkPalette(_:analysis:)` 第一判定从 `coverLuma < 0.36` 改为：

```swift
if let analysis, analysis.isUltraDark { return true }
// fallback: 旧的 imageCoverLuma + areaDominantB + grayScore 判定（保留作为 analysis nil 时的 fallback）
```

意义：Phase 2 的 `isUltraDark` 是亮度维度（avgHslL ≤ 0.22 || avgLuma ≤ 0.18 || dominantBrightness ≤ 0.60），与 `isNearMonochrome` 正交。深紫 / 夜蓝 / 暗红 这类"极暗有色"封面会被识别为 UltraDark = true 同时 NearMono = false → 触发 BK 的 UltraDark 渲染叠层保护，但 displayPalette 中仍有真实色相，因此背景多色性不被淹没。

**Snapshot 路径**：保持 `analysis = nil`（snapshot 不携带 displayPalette / isUltraDark）。该路径继续走 richPalette + 旧 UltraDark 判定，零行为变化。

**调试日志**：`[BKArt/palette] ultraDark=... nearMono=... hasSalient=... colors=[...]`。

### 3.3 Spectrum — displayPalette.prefix(2) + 同色调 L 变体兜底

**改动**：`myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift`、`myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift`。

**Color source**：`FullscreenMiniPlayerView.spectrumArtworkColors` 改为：

```text
analysis.displayPalette (优先)
   ↓ prefix(2)
fallback: analysis.topPalette.prefix(2)
fallback: [artBackgroundPrimary, artBackgroundSecondary]
```

由于 displayPalette 顺序为 `top.first → salient → top.tail → rich`，2 色截取自然变成 **`[top.first, salient[0] (if any) | top[1]]`**——左端是主色，右端是点睛色或副色。9 个 capsule 跨左→右 lerp，频谱高频段（右侧）自动获得 salient（如果存在）。这是 §5.3 "salient 适合作为高频段 / 峰值段色 / 次色 / 发光点睛色"的最低代价实现。

**单色封面兜底**：

`MiniPlayerSpectrumView.resolveArtworkFaithfulColors` 当 displayPalette 只有 1 个色时，右端不再退到 accent / 中性灰；改用 `makeTonalRightEndpoint(of:usesDarkForeground:)`：

- `OKColor.nsColorToOKLCH(color)` → 拿到 OKLCH。
- L 偏移 ±0.10（`usesDarkForeground ? -0.10 : +0.10`），H/C 保持。
- `okLCHToNSColor(tuned, alpha: 1)`。

效果：单色封面下频谱仍是 "同色调略深 → 同色调略亮" 的 L 阶变，**不再 hue rotate 假多色**，也不再退到中性灰。仅在 OKLCH 转换都失败时才落到 accent。

**`adjustedSpectrumBase` / 9-capsule lerp 几何 / 亮度饱和度曲线**：未触动。Phase 3 只换"颜色来源"，不调"发光后处理曲线"。

**调试日志**：`[Spectrum/palette] ultraDark=... nearMono=... hasSalient=... colors=[...]`。

### 3.4 边界遵守清单

- [x] LED 未改（`LEDColorResolver` 内部 OKLCH 调参原封不动）。
- [x] MiniPlayer 控件色未语义化（仍读 `accentColor`）。
- [x] Artwork Readability Profile 未实现。
- [x] 歌词颜色策略未改。
- [x] Header 路径未改。
- [x] Tone Ladder 未做。
- [x] `SemanticPalette` 主 accent 仍是 HSL 路径，未切 OKLCH。
- [x] Phase 2 算法（`analyzeInternal` / `computeSalientHighlights` / `computeDisplayPalette` / token 阈值）**完全未改**。
- [x] Home Shapes 布局 / 动画 / 透明度未改（仅替换 `palette` 函数返回内容）。
- [x] BKArt 动画 / 布局未改（仅替换 `BKColorEngine.make` 的 `extracted` 输入与 `isUltraDarkPalette` 的第一判定）。
- [x] Spectrum 几何绘制 / AVAudio 驱动未改（仅替换 `spectrumArtworkColors` 与单色兜底）。

### 3.5 构建验证

```text
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

### 3.6 改动文件清单

```text
myPlayer2/Views/Home/HomeAmbientShapesBackground.swift             (displayPalette → OKLCH 背景化、PaletteSignature 增字段、调试日志)
myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift               (selectedExtractedPalette、isUltraDarkPalette 强化、调试日志)
myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift          (spectrumArtworkColors 改读 displayPalette、调试日志)
myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift            (makeTonalRightEndpoint 单色兜底)

docs/oklch-color-system-migration-log.md                           (本节)
```

### 3.7 手测建议（5 类封面 × 3 个 UI surface）

预期最低基线：

| 封面类型 | Home Shapes | BKArt | Spectrum |
| --- | --- | --- | --- |
| **(A) 灰黑背景 + 小面积鲜黄**（如 some metal albums） | 大部分 shapes 是深灰 L 变体，**至少 1 个 shape 是 salient 黄**（OKLCH chroma 被收束但 hue 保留） | bg 走深灰，但 shape pool / dot tier 必须出现黄色调（salient 进入 candidate） | 左端深灰 / 黑，右端鲜黄（salient）→ 9 capsule 从灰渐变到黄 |
| **(B) 深蓝绿 + 橙色点睛** | shapes 主体是深蓝绿 L 变体，**部分 shape 携橙色 hue**（salient orange 不被合并掉，displayPalette 至少 2-3 色） | bg primary = 深蓝绿，shape pool / accent 候选含橙 | 左 = 深蓝绿，右 = 橙 → 高频段 capsule 偏橙 |
| **(C) 高饱和多色封面** | 6 shapes 大概率覆盖到 3-4 个真实 hue（不再 6 个全是同 hue 偏移） | bgVariants 多色更丰富，shape pool hueSpread > 之前的 hue-family 派生 | 左右两色都是真实 displayPalette 前两色，差异明显 |
| **(D) 极暗彩色（深蓝 / 酒红 / 暗紫）** | shapes 保留深 L band（ultraDark profile：L 0.10–0.26），但 hue 不被洗成灰（chromaCeiling 0.075，不是 0.030） | `controller.setUltraDarkActive(true)` 仍触发；但 bg / shape pool 保留深紫 / 深酒红 hue，**不再被 BKColorEngine 误判为 grayscaleTrue 而走灰阶 fallback** | 左右两色都偏深，但 hue 真实可辨（非中性灰） |
| **(E) 近灰阶或黑白封面** | shapes 全部走 nearMono 通道（chromaCeiling 0.038 / 0.022），整张图保持安静；如果有任何 salient，**至少 1 个 shape 是该 salient L 变体** | bg primary 几乎中性，shape pool 高度去饱和（已有的 `applyAnalysisBgSGating` 路径仍在 1.x ceiling 工作） | 左右几乎同色（同色 L 变体兜底），不再退到 #999 中性灰 |

**关键退出条件复述**：

- 监听同一封面时，Home Shapes / BKArt / Spectrum 三处颜色气质**同源**（都来自 displayPalette）。
- Spectrum / Home Shapes 至少各**有机会消费一次 salient**（取决于 salient 是否存在 & 是否进入 displayPalette 前 2/6）。
- Ultra Dark 暗色封面的"夜色感"不被多色 palette 接入破坏。

### 3.8 留给后续 Phase 的问题

1. **ArtworkAssetSnapshot 不携带 displayPalette / salient / isUltraDark / isNearMonochrome / weightedLuma / dominantBrightness**。当 BKArt 走 snapshot cache 路径时（已访问过的封面），analysis 仍为 nil → 退化到旧 rich+luma 判定，丢失多色性的部分增益。Phase 4 或 Phase 7 应评估：是否把 Phase 2 新字段持久化到 snapshot，或让 ThemeStore 在更早一层缓存 ArtworkColorAnalysis（不只是 dominantColor）。本期不动，避免与 BKArt UltraDark 渲染层耦合。
2. **Home Shapes ambient base layer**（`HomeAmbientPalette.ambientBaseColor`）仍走旧 HSL 路径，使用单 sourceColor + `analysis?.isEffectivelyMonochrome` 短路判断。它绘制的是 **shapes 背后的纯色背景层**，与 shape palette 是两件事。Phase 5 / Phase 6 可考虑把这一层也走 OKLCH，但本期不动。
3. **Spectrum salient 优先级**：当前是 "displayPalette.prefix(2)"，所以如果 salient 已是 displayPalette[1]，就会出现在右端。如果 artwork 的 displayPalette 顺序变成 `top[0] → top[1] → salient(later)`（即 salient 没排到前 2），salient 不会进入 Spectrum。这是 Phase 2 排序策略的内嵌结果，不在 Phase 3 调整范围。
4. **BKArt 调试日志在 snapshot 路径上不打印 analysis 字段**（因为 analysis 为 nil）。Phase 4 持久化 analysis 后即可补全。
5. **Phase 4 入口**：MiniPlayer 控件色语义化 + Artwork Readability Profile。`MiniPlayerSpectrumView` 的 `usesDarkForeground: Bool` 参数（来自 `FullscreenMiniPlayerView.usesDarkArtworkForegroundForClear`）届时应替换为语义化输入（参见 Phase 0 §0.6 已登记的后续）。

***

## Phase 3 回修补记（2026-05-20）

用户手测 Phase 3 落地版本（commit `b2faae1`）后报告 5 个视觉问题。其中 3 个属于 Phase 3 退出条件未满足或新引入，必须本轮修复；2 个属于跨阶段问题，本轮**不修**但写入文档以确保 Phase 4 / Phase 5 不会遗忘。

### 3.9 已修：Spectrum 在近黑白 / 低饱和封面下偏粉

**症状**：纯黑白灰封面、几乎零饱和度封面、低饱和 muted 封面下，全屏 mini player 频谱出现可感知的粉色 / 偏色，与原封面气质背离。

**根因**（两层叠加）：

1. `displayPalette` 的排序 `top.first → salient → top.tail → rich` 在 nearMono 封面下，salient 槽承载的是面积极小但 hue 鲜明的微亮点（如黑白照片里的一抹粉色反光），`prefix(2)` 直接把它送进 Spectrum 右端。
2. `MiniPlayerSpectrumView.adjustedSpectrumBase` 在 `s < 0.55` 时强行使用 `min(0.70, max(0.18, s * 1.08))`。任何残留 hue（例如 nearMono 调色板上的 s=0.02）都会被抬到 saturation 0.18，**视觉上从灰阶被推到粉/黄/蓝**。

**修复**（两层防御）：

1. `FullscreenMiniPlayerView.prepareSpectrumColors(_:analysis:)`：在送进 `MiniPlayerSpectrumView.updateColors` 之前做一次 OKLCH 预处理。
   - `analysis.isNearMonochrome` 为真：每个色经 `OKColor.nsColorToOKLCH` → `min(c, 0.008)` → `okLCHToNSColor` 投回。**强制 chroma ≈ 0**，hue 槽虽然存在但视觉上是灰阶。
   - 非 nearMono 但 `analysis.colorfulness < 0.18`：经 `OKColor.chromaSoftShoulder(ceiling: 0.05, softness: 0.04)` 软压。
   - 其他（正常彩色封面）：原样直通。
2. `MiniPlayerSpectrumView.adjustedSpectrumBase` 饱和度曲线分段重写：
   - `s < 0.06`：原值通过（不再 `max(0.18, ...)`）。
   - `0.06 ≤ s < 0.22`：`min(0.30, s * 1.04)`（轻提，**无 0.18 地板**）。
   - `0.22 ≤ s ≤ 0.55`：保留旧 `min(0.70, max(0.18, s * 1.08))`。
   - `s > 0.55 / s > 0.72`：保留旧 0.94× / 0.88× 收束。

调用方端（`FullscreenMiniPlayerView`）已先 OKLCH 中性化；`adjustedSpectrumBase` 这条作为 defence-in-depth，未来如新 Spectrum 消费者直接调它也不会再放大伪色相。

**自检覆盖**（`ColorSystemSelfCheck` 新增 §"Phase 3 hotfix — consumer projection"）：

- `Spectrum: near-mono input neutralised` — 95% 黑 + 5% 鲜黄合成样，预处理后输出最大 OKLCH chroma ≤ 0.010。**实测 maxOKLCHChroma=0.008**。
- `Spectrum: low-sat not amplified` — 低饱和灰蓝合成样，预处理后输出 chroma 比 ≤ 1.05×源。**实测 1.000×**。
- `Spectrum: colourful pass-through` — 4 色鲜艳合成样，预处理输出与输入完全相等（按 sRGB ε=1e-6 比对）。**实测 equal=true**。

### 3.10 已修：Home Art Shapes 在近黑白封面下偏粉

**症状**：黑白灰、几乎无饱和度封面下，Home 背景的 6 个 ambient shape 出现可感知粉色。

**根因**：`HomeAmbientPalette.ambientTuning` 在 `isLowColor=true` 时 chromaCeiling 仍是 `0.038`（dark）/ `0.022`（light），chromaScale 仍是 `0.46` / `0.32`。当 displayPalette 顺序把 salient 抬到第二槽时，salient 颜色的源 OKLCH chroma 可能在 0.06–0.12 区间，乘 0.46 得到约 0.028–0.055，再被 chromaCeiling 0.038 钉住——**远超灰阶视觉门槛**，看起来就是粉色。

**修复**：`ambientTuning(...)` 的 nearMono 分支大幅收紧（Phase 3 hotfix 标注）：

| 分支 | 旧 chromaCeiling | 新 chromaCeiling | 旧 chromaScale | 新 chromaScale |
| --- | --- | --- | --- | --- |
| dark + ultraDark + nearMono | 0.030 | **0.010** | 0.42 | **0.18** |
| dark + 非 ultraDark + nearMono | 0.038 | **0.012** | 0.46 | **0.22** |
| light + nearMono | 0.022 | **0.008** | 0.32 | **0.18** |

非 nearMono 路径**完全未动**（正常彩色封面继续在 0.115 / 0.075 / 0.058 三档下工作）。

**自检覆盖**（同 §3.12）：

- `HomeShapes: near-mono chroma ceiling` — 95% 黑 + 5% 鲜黄合成样投影后，最大 OKLCH chroma ≤ 0.011（ultraDark+nearMono 路径，limit 0.0105）。**实测 maxOKLCHChroma=0.010**。

### 3.11 已修：UltraDark 下 Home Art Shapes 未随 BKArt 压暗

**症状**：UltraDark 极暗封面下，BKArt 走 UltraDark 渲染保护后整体压暗（`ultraDarkOverlay` opacity 0.50 + harmonizer 压低 L），但 Home Shapes 仍偏亮，与 BKArt 出现明度割裂。

**根因**：`ambientTuning` ultraDark 分支 L 区间是 `[0.10, 0.26]`，lOffset 0.06，lScale 0.46。与"普通 dark + 非 ultraDark"分支 `[0.18, 0.34]` 重叠 8 个百分点；nearMono ultraDark 封面经投影后落在 0.20–0.26 区间——视觉上和普通 dark 几乎无差。

**修复**：ultraDark 分支 L 区间下沉到 **`[0.05, 0.18]`**，lOffset → **0.04**，lScale → **0.32**。即任何 displayPalette 颜色（无论其原 L 是 0.05 还是 0.85）经 `0.04 + L*0.32` 都落进新区间。极暗封面（源 L ≈ 0.10）投影到 L ≈ 0.072；亮 salient（源 L ≈ 0.80）投影到 L ≈ 0.18 上限。整体感官现在与 BKArt 的"夜色"基调一致。

**自检覆盖**：

- `HomeShapes: ultraDark lightness band` — 深蓝 (10,25,70) 合成样投影后，所有 shape OKLCH L 都落在 `[0.05, 0.18]`。**实测 L range=[0.080, 0.180]**。

### 3.12 未修但写入文档（跨阶段接力）：近黑白下 Fullscreen MiniPlayer UI 与 Lyrics 偏色

以下两个用户报告**不在 Phase 3 回修范围**，本轮严格禁止修复以避免误触 Phase 4 / Phase 5 的整体语义化工作。但本节作为**显眼接力点**记录入此处，并同步登记到执行计划文档与调查报告：

#### Issue A — 全屏 MiniPlayer UI 在近黑白封面下出现淡蓝 / 淡黄 / 轻微染色

- **触发条件**：纯黑白灰、近零饱和度封面。
- **症状**：全屏 mini player 的文字 / 图标 / 控件色出现淡淡偏蓝 / 偏黄 / 其他轻微伪色相。
- **归属**：**Phase 4 — MiniPlayer 控件色语义化 + Artwork Readability Profile**。
- **修复方向**：
  - 当前 `FullscreenMiniPlayerView.controlPrimaryNSColor` / `usesDarkArtworkForegroundForClear` 仍从原 SemanticPalette accent / averageColor 推导，未走 nearMono 中性化通道。
  - Phase 4 需要 `MiniPlayerControlPalette`（待新增）在 `analysis.isNearMonochrome` 时强制把 UI 主色去到 OKLCH 中性轴（chroma ≈ 0），仅保留 L 区分（提升与背景的对比即可，不要染色）。
  - 验收：纯灰封面下 UI 颜色读取必须 `circularHueDistance < 0.01` 且 `chroma < 0.005`，或者直接是 system label color。

#### Issue B — 窗口 / 全屏歌词在近黑白封面下偏粉红

- **触发条件**：纯黑白灰、近零饱和度封面。
- **症状**：窗口歌词面板与全屏歌词面板的高亮色 / 文字色均偏粉红。
- **归属**：**Phase 5 — 歌词颜色体系收敛**。
- **修复方向**：
  - 当前歌词色彩链路（AMLL bridge 一侧设置的 `lyricsHighlight` / `lyricsForeground` 等）部分仍走旧 HSL accent 路径，nearMono 时残留 hue 没有归零。
  - Phase 5 收敛时，**near-mono 中性化必须作为显式规则**写入 Swift 侧统一歌词色彩决策函数：
    - `analysis.isNearMonochrome == true` → 歌词所有可见色去到 OKLCH chroma ≤ 0.005，仅靠 L 与 alpha 体现层级。
  - 窗口歌词与全屏歌词共用同一决策函数后必须**两端同时验收**（避免单端修复造成视觉割裂）。

### 3.13 构建 / 自检 / 文件 / 提交

**构建**：

```text
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

**自检**：

```text
COLOR_SYSTEM_SELF_CHECK=1 ./kmgccc_player.app/Contents/MacOS/kmgccc_player
→ Result: ALL PASS  (5 phase-3-hotfix scenarios + 18 prior scenarios)
```

**改动文件清单**：

```text
myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift          (prepareSpectrumColors / OKLCH 预处理 / nonisolated 静态 / DEBUG 自检桥)
myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift            (adjustedSpectrumBase 饱和度曲线分段重写)
myPlayer2/Views/Home/HomeAmbientShapesBackground.swift             (ambientTuning ultraDark / nearMono 收紧 / 静态 nonisolated / DEBUG 自检桥)
myPlayer2/Utilities/ColorSystemSelfCheck.swift                     (新增 Phase 3 hotfix 5 scenarios + SwiftUI import)
docs/oklch-color-system-migration-log.md                           (本节)
docs/oklch-color-system-execution-plan.md                          (Phase 4 / Phase 5 接力项)
docs/oklch-migration-color-system-investigation.md                 (近黑白伪 hue 跨阶段备忘)
```

### 3.14 手测建议（4 类封面，验证回修无回归 + 新规则生效）

| 封面类型 | Home Shapes 预期 | BKArt 预期 | Spectrum 预期 |
| --- | --- | --- | --- |
| **纯黑白灰 / 极低饱和无 hue** | 完全中性，6 个 shape L 阶梯分布；**无任何粉 / 黄 / 蓝染色** | 与 Phase 3 主体一致（不在回修范围，但应继续中性） | 9 个 capsule 从浅灰渐变到深灰；**无粉色** |
| **极低饱和灰蓝 / 灰棕**（colorfulness ≈ 0.10–0.18） | 主体色保留原 muted 灰冷调 hue，但 chroma 不被抬高 | 保持低 chroma 气质 | 左右两端均贴近源色低饱和气质，**不出现"比封面鲜艳很多"的回弹** |
| **UltraDark 深蓝 / 酒红 / 暗紫**（colorfulness ≥ 0.30，luma ≤ 0.18） | shapes 整体明显比"普通 dark"更暗（OKLCH L 落在 [0.05, 0.18]），hue 保留 | UltraDark 渲染保护层叠加，整体压暗 | 双端均深暗，但 hue 真实可辨 |
| **正常高彩多色**（colorfulness ≥ 0.40） | 6 shape 覆盖到多个真实 hue，**回修未拖累彩色收益** | 多色 bg + shape pool 多色，与 Phase 3 主体一致 | 左右两色都是 displayPalette 前两色，差异明显 |

### 3.15 Phase 4 / Phase 5 接力点（与 §3.12 对应）

- **Phase 4 显式入口**：MiniPlayer 控件色 `nearMono` 中性化规则。代码切入点 `FullscreenMiniPlayerView.controlPrimaryNSColor` / `shouldUseDarkArtworkForeground(for:)`。验收：手测 Issue A 复现样本应不再出现淡蓝 / 淡黄。**Phase 4 已完成本轮任务：见下节。**
- **Phase 5 显式入口**：Swift 侧统一歌词色彩决策函数（含窗口与全屏两面），增加 `analysis.isNearMonochrome == true` → chroma ≤ 0.005 规则。验收：手测 Issue B 复现样本应不再偏粉。

***

## Phase 4 — 交互与可读性语义色

**完成日期**：2026-05-20。\
**分支**：`refactor/oklch-color-system`。

### 本阶段目标

三件事：
1. **MiniPlayer 控件色语义化**：把分散在 View 层的 HSL 控件色重算逻辑收束到 `MiniPlayerControlPalette`。
2. **建立 Artwork Readability Profile**：统一"压在 artwork 上的 UI 文字 / 图标前景色决策"，通过 `ArtworkReadabilityProfile` 对外。
3. **修复 Phase 3 接力问题**：近黑白 artwork 下 Fullscreen MiniPlayer UI 出现淡蓝 / 淡黄伪 hue（`§3.12 Issue A`）。

### 4.1 ColorSystemTokens 新增命名空间

新增两个命名空间：

- `ReadabilityProfile`：`secondaryAlpha`（0.78）/ `tertiaryAlpha`（0.58）/ `quaternaryAlpha`（0.40）/ `nearMonoChromaCeiling`（0.004）/ `nearMonoChromaAssertion`（0.005）。
- `MiniPlayerControl`：`liftedMinL`（0.88）/ `liftedMaxL`（0.97）/ `liftedChromaCap`（0.12）/ `neutralL`（0.94）/ `nearMonoChromaAssertion`（0.005）。

### 4.2 SemanticPalette 新增类型与字段

新增两个 value 类型（`Equatable, Sendable`）：

**`ArtworkReadabilityProfile`**：
- `usesDarkForeground: Bool` — 透传 `analysis.usesDarkForeground`（loose gate）。
- `isNearMonochrome: Bool` — 便于消费者无需再依赖 analysis。
- `foregroundPrimary / Secondary / Tertiary / Quaternary / iconForeground: NSColor` — 分层 alpha，当 nearMono 时 primary 已 OKLCH chroma-crushed（≤ 0.004），下级 alpha 叠加后也满足 ≤ assertion。

**`MiniPlayerControlPalette`**：
- `primary / secondary / progressFill / progressTrack: NSColor`。
- 非 nearMono：通过 `liftedAccentControl(globalAccent)` 在 OKLCH 空间把 accent lift 到 L≥0.88，cap chroma≤0.12。
- nearMono：通过 `neutralAchromaticControl()` 直接输出 OKLCH(L=0.94, C=0)，chroma = 0。

`SemanticPalette` 新增两个字段：`readabilityProfile: ArtworkReadabilityProfile` 和 `miniPlayerControl: MiniPlayerControlPalette`。

### 4.3 readableTextOnArtwork / secondaryTextOnArtwork 重定向

`SemanticPaletteFactory.make` 现在先派生 `readabilityProfile`，然后把 `readabilityProfile.foregroundPrimary` 赋给 `readableTextOnArtwork`，`foregroundSecondary` 赋给 `secondaryTextOnArtwork`。

**效果**：已有消费者（HomeHero `artworkTextPrimary`、`coverGradientText` 上游）在不改调用点的情况下自动获得 nearMono 中性化。

**关于 `secondaryTextOnArtwork` 语义变更**：旧值是 `bestTextSourceColor.withAlphaComponent(0.86)`，外部无消费者（grep 确认）。新值是 `readableTextOnArtwork.withAlphaComponent(0.78)`，语义更清晰且与 HomeHero `artworkTextSecondary` 逻辑对齐。

### 4.4 FullscreenMiniPlayerView 控件色迁移

- `controlPrimaryNSColor`：
  - `usesDarkArtworkForegroundForClear == true` → `semanticPalette.readabilityProfile.foregroundPrimary`（over-artwork surface）。
  - 其他 → `semanticPalette.miniPlayerControl.primary`（chrome surface）。
- 删除 `resolveControlAccentColor`、`resolveControlPrimaryColor`、三个 HSL 阈值常量以及所有 HSL helper 函数（`enforceMinimumHslLightness` / `enforceMaximumHslLightness` / `enforceMinimumHslSaturation` / `hslComponents` / `rgbColorFromHsl` / `clamp01`）。
- 保留 `shouldUseDarkArtworkForeground(for:)` — 它是 over-blur surface 的专用 stricter gate，不属于 readabilityProfile 的通用 `usesDarkForeground`。

### 4.5 全面收束：ExpandableVolumeControl / FullscreenPlayerView / FullscreenQueueView

同一"over-artwork stricter gate / chrome fallback"模式原来散落在三个文件中：

| 文件 | 旧路径 | 新路径 |
| --- | --- | --- |
| `ExpandableVolumeControl` | `FullscreenMiniPlayerView.resolveControlAccentColor(...)` | `palette.miniPlayerControl.primary` |
| `FullscreenPlayerView` | `FullscreenMiniPlayerView.resolveControlAccentColor(...)` | `palette.miniPlayerControl.primary` |
| `FullscreenQueueView` | 本地复制的 `resolveControlAccentColor(...)` + 全套 HSL helpers | `palette.miniPlayerControl.primary`（`processedThemeColor`） |

`FullscreenQueueView` 的本地 HSL helper 全部删除（约 90 行），与 `FullscreenMiniPlayerView` 的 HSL helper 一起下线。

### 4.6 HomeHeroView 显式接入 ReadabilityProfile

- `artworkTextPrimary` → `heroPalette.readabilityProfile.foregroundPrimary`（等价于旧 `readableTextOnArtwork`，但现在语义清晰）。
- `artworkTextSecondary` → `heroPalette.readabilityProfile.foregroundSecondary`（等价于旧 `readableTextOnArtwork.withAlphaComponent(0.78)`）。

### 4.7 自检扩展（Phase 4 — 5 个新场景）

| 场景 | 输入 | 断言 | 实测结果 |
| --- | --- | --- | --- |
| ReadabilityProfile: near-mono neutral | 灰白 (200,200,200) | foregroundPrimary OKLCH chroma ≤ 0.005 | chroma=0.004 ✓ |
| ReadabilityProfile: bright artwork → dark fg | 浅米白 (240,235,228) | usesDarkForeground=true, L < 0.50 | L=0.250 ✓ |
| ReadabilityProfile: dark artwork → light fg | 深黑紫 (25,22,30) | usesDarkForeground=false, L > 0.80 | L=0.933 ✓ |
| MiniPlayerControl: near-mono neutral | neutralAchromaticControl() 直接 | chroma ≤ 0.005, L ≥ 0.88 | chroma=0.000, L=0.940 ✓ |
| MiniPlayerControl: colourful hue preserved | liftedAccentControl(蓝色源) | Δhue ≤ 0.06, L ≥ 0.88 | srcH=outH=0.698, L=0.880 ✓ |

自检总计：**ALL PASS（25/25）**，`EXIT=0`。

### 4.8 构建验证

```text
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

### 4.9 改动文件清单

```text
myPlayer2/Utilities/ColorSystemTokens.swift              (新增 ReadabilityProfile + MiniPlayerControl 命名空间)
myPlayer2/Utilities/SemanticPalette.swift                (ArtworkReadabilityProfile + MiniPlayerControlPalette 类型；factory 新 derivation；nonisolated helpers；#if DEBUG bridge)
myPlayer2/Utilities/ColorSystemSelfCheck.swift           (Phase 4 五个新场景；SemanticPaletteSelfCheck 桥接)
myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift (controlPrimaryNSColor 切换；删除 HSL helpers)
myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift    (fullscreenMiniPlayerPrimaryNSColor 切换)
myPlayer2/Views/Fullscreen/FullscreenQueueView.swift     (processedThemeColor 切换；删除本地 HSL 副本)
myPlayer2/Views/Controls/ExpandableVolumeControl.swift   (controlPrimaryNSColor 切换)
myPlayer2/Views/Home/HomeHeroView.swift                  (artworkTextPrimary / Secondary 接入 readabilityProfile)
docs/oklch-color-system-execution-plan.md                (Phase 4.5 新增路线图；Phase 4 退出条件更新)
docs/oklch-color-system-migration-log.md                 (本节)
```

### 4.10 边界遵守清单

- [x] Phase 4.5（全局淡彩前景色）：仅写入文档，未实现。
- [x] `.primary / .secondary` 系统颜色：未改。
- [x] 普通 App 字体体系：未改。
- [x] 歌词颜色策略：未改（Phase 5 接力）。
- [x] Header 路径：未改。
- [x] Tone Ladder：未做。
- [x] LED：未改。
- [x] Home Shapes / BKArt / Spectrum 的 Phase 3 行为：未改。
- [x] `SemanticPaletteFactory.optimizedAccent` / `nearMonochromeAccent` 主逻辑：未改。

### 4.11 接力提示（→ Phase 4.5 / Phase 5）

1. **Phase 4.5（文档已登记）**：全局淡彩前景色体系。先做全 App 字体 / 普通前景颜色审计（区分系统语义色、ThemeStore accentColor 消费、固定光学常量），再设计 `AppForegroundPalette`，渐进接入。不要暴力替换 `.primary`。

2. **Phase 5（歌词颜色收敛，Issue B）**：窗口与全屏歌词在 nearMono 封面下偏粉（`§3.12 Issue B`）。Phase 5 统一歌词颜色决策函数时，`isNearMonochrome == true` → 所有歌词可见色 OKLCH chroma ≤ 0.005，两端（窗口 + 全屏）同时验收。

3. **`shouldUseDarkArtworkForeground` stricter gate**：目前在 `FullscreenMiniPlayerView` 留为静态方法，供 `FullscreenPlayerView` 与 `ExpandableVolumeControl` 共用。若未来 Phase 5/6 引入更多"压在 blur 上"的 UI surface，考虑把 stricter gate 提升到 `ArtworkReadabilityProfile` 的第二个字段（`usesDarkForegroundOverBlur: Bool`），让 view 层只做路由。

4. **CoverGradientBlurSkin 面板 UI**（`CoverGradientBlurSettingsView`）仍读 `themeStore.accentColor`。这是 settings 面板，不属于"压在 artwork 上的前景"，Phase 4 明确不改。Phase 7 清理时评估是否纳入 Phase 4.5 的 App Foreground palette。

5. **`readabilityProfile.foregroundSecondary` alpha = 0.78**：与旧 `HomeHeroView.artworkTextSecondary` 等价，与旧 `secondaryTextOnArtwork`（alpha=0.86）不同。旧 `secondaryTextOnArtwork` 无外部消费者（已确认），语义现在对齐 HomeHero 惯例（0.78）。

***

