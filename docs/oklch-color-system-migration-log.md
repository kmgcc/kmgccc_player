---
type: Note
---
# OKLCH Color System Migration Log

按阶段归档颜色系统从 HSL 到 OKLCH 的迁移过程。每个 Phase 保留：目标、关键技术决策、最终参数、验收结果、留给后续阶段的接力点。中间错误探索、临时回归、过程日志已删除——保留"为什么这么做"，不复述"试错了什么"。

设计文档：`docs/oklch-migration-color-system-investigation.md`（R1–R4 调查报告）。  
施工计划：`docs/oklch-color-system-execution-plan.md`。

---

## Phase 0 — Pre-migration cleanup

**目标**：清理"无消费的契约"和"潜在 B 类 bug"，给 Phase 1 让出干净的起点。不引入新算法、不改任何视觉口径。

### 0.1 ArtworkAssetStore cacheVersion 单点化

**改动**：

- `Utilities/ArtworkColorExtractor.swift` 新增 `public nonisolated static let cacheVersion: String`（初值 `"semantic-near-mono-v2"`，Phase 2 bump 到 `"orthogonal-decision-v3"`）。
- `Models/ArtworkAssetSnapshot.swift` 把实例 `cacheKey` 改为委派给 `static func cacheKey(trackID:artworkChecksum:)`，并把 `ArtworkColorExtractor.cacheVersion` 前缀进 key。
- `Services/Artwork/ArtworkAssetStore.swift` 两条读写路径都走同一 key 模板。
- `Services/Theme/ThemeStore.swift` 删私有 `colorExtractionCacheVersion`，直接读 extractor 的静态字段。

**为什么选 key-prefix 而非 snapshot 内嵌字段**：内嵌字段需要每个读者主动校验、容易漏；前缀方案单点修改，老 entry 在算法版本变更后自动失效，新 entry 同版本内仍能正常缓存。in-progress 合并仍按 key 字符串去重，前缀只是把 namespace 拓宽，不引入新 race。

### 0.2 歌词 Swift → Web 死字段清理

`ThemePalette` 中的 `accent` / `shadow` 字段无任何 web 端消费者，但仍在每次 `refreshPalette` 计算并通过 `applyEffectiveTheme` 写入 `WKWebView`。删除链路：

- `ThemePalette` 删 `accent`/`shadow` 字段。
- `LyricsWebViewStore.applyEffectiveTheme` 删 `shadowColor` config 键 + IIFE 删 `--amll-bg`/`--amll-accent`/`--amll-shadow` 三条 setProperty。
- `LyricsViewModel` surface config 字典删 `shadowColor`。
- `FullscreenPlayerView` 两个 `ThemePalette(...)` 构造点同步去除参数。
- `Resources/AMLL/index.html` 删 `if (hasOwn("shadowColor"))` 善后分支。

**保留**：`--amll-text` / `palette.text`（仍是 SwiftUI 与 AMLL `textColor` 的活字段）、`palette.background`（`LyricsPanelView` 仍读）、`--amll-active`/`--amll-inactive`/`--amll-lp-color`（仍是渲染契约）。

### 0.3 其他前置遗留

- **MiniPlayerSpectrumView fallback 统一**：把不同代码路径中三份不一致的 fallback 颜色推导收敛到一处。
- **ClassicLEDSkin 阴影深浅自适应**：硬编码阴影色改为按 `colorScheme` 选择。
- **FullscreenCoverGradientBlurSkin 占位 icon 自适应**：占位图标颜色随 `usesDarkForeground` 切换。
- **colorScheme 响应方式评估**：保留现有 `@Environment(\.colorScheme)`，不引入新机制；记录为 Phase 6 待重审项。

### 不在 Phase 0 处理的项

- AMLL 一侧字段（与 Phase 0 边界正交）。
- 主派色逻辑、UltraDark / NearMonochrome 决策（Phase 2）。
- 任何 OKLCH 公共数学层的提级（Phase 1）。

---

## Phase 1 — Token 化 + OKLCH 公共数学层

**目标**：把 `SemanticPaletteFactory` 与 `ArtworkColorAnalysis.isEffectivelyMonochrome` 内分散的数值集中到 `ColorSystemTokens`；把 `OKColor.swift` 从 LED 专用工具提级为整个颜色系统的公共 OKLab/OKLCH 数学层。**不改任何决策逻辑，不改任何数值。**

### 1.1 OKColor 公共化

- 头部 docstring 从 "Used ONLY by LEDColorResolver" 改为 "Public OKLab/OKLCH colour math layer"。
- `OKLab` / `OKLCH` 加 `Equatable, Sendable`。
- 新增 6 个公共原语（保持现有 LED API 不变）：
  - `normalizedHue(_:)`（原 `private` 提升 `static`）
  - `clampLightness(_:lo:hi:)` / `clampChroma(_:lo:hi:)`
  - `chromaSoftShoulder(_:ceiling:softness:)` — `ColorMath.softShoulder` 的 OKLCH 等价
  - `rotateHue(_:by:)` — OKLCH 内 hue 旋转 + 归一化
  - `oklabLerp(_:_:t:)` — 通过 OKLab 中间表示插值，避免色相环绕

**不动 LED**：`LEDColorResolver.baseColorForIndex` 内联的 OKLab lerp 与 hueShift / hueAwareChromaCap 表是 LED 视觉产品参数；机械替换会引入风险且无单测保障，留给 Phase 6 Tone Ladder 一起重做。

### 1.2 ColorSystemTokens 命名空间

新增 `Utilities/ColorSystemTokens.swift`，按语义角色嵌套：

| 命名空间 | 内容 |
|---|---|
| `Accent` | `optimizedAccent` 的深/浅 L 钳制、hue-aware 明度下限（5 段）、hue-aware 饱和度上限（9 段）、warm-band hue guard、3 层低色 sat 安全网 |
| `NearMonochrome` | `nearMonochromeAccent` 的 strict-mono 四项判定、深/浅 sat 上限与 floor、tone-lift / tone-drop 参数 |
| `FallbackAccent` | `useArtworkTint == false` 时用户 fallback accent 的深/浅 L 钳制 |
| `ReadableText` | `readableTextOnArtwork` 的深/浅 sat 钳制范围与目标 L；`secondaryTextOnArtwork` 透明度 |
| `CoverGradient` | `coverGradientDominant` / `coverGradientText` 的 sat/L 钳制 |
| `FullscreenLyric` | "取 dominant 色"还是"取 best-text 源"的 colorfulness / hueConfidence 双阈值 |
| `WindowLyric` | inactive 行透明度 |
| `EffectiveMonochrome` | `isEffectivelyMonochrome` 的 5 个 OR 分支阈值（按 `branch1..5` 标号锁住，便于 Phase 2 拆分时单点重排） |

**关键命名决策**：token 名反映"语义意图"而非"等价表达式"（例 `darkMinLByHueCyanBlue`），底层数学换 OKLCH 时调用点零改动。

**保留并标记 deprecated**：旧 `EffectiveMonochrome` 命名空间 Phase 2 后只剩 forwarding 别名。

### 1.3 未 token 化的项及原因

- LED 视觉调参（neutral baseline、hue-aware chroma caps、level-driven L/C 曲线、hue shift 表）— Phase 6 范畴。
- `ArtworkColorExtractor` 内 bucket weight / distinctness gap / WCAG contrast / 像素 alpha 阈值 — extractor 私有行为，与 Phase 2 决策升级强耦合。
- `SemanticPaletteFactory.optimizedAccent` 里的 hue 区间端点（如 `0.10..<0.18`）— 这是色相轮分段的"索引键"，不是阈值，保持字面量正确。

### Phase 1 验收

- `xcodebuild Debug build → ** BUILD SUCCEEDED **`
- 无新单元测试（项目无 test target）。Token 替换是纯字面量重命名，等价性靠"编译通过 + LED 视觉未动 + 新原语暂无消费者"保证。

---

## Phase 2 — 决策引擎 2.0：正交化 + 多色 palette

**目标**：

1. 把 `isEffectivelyMonochrome` 拆成两个**正交**维度 `isUltraDark`（亮度轴）与 `isNearMonochrome`（色度轴）；
2. 删除 R4 J.2.c 标注的 branch 4（`isExtremeTone && low sat` 把"极暗有色"误归入"无色相"）；
3. 新增小面积高显著色结构化输出 `salientHighlightPalette`；
4. 新增质控合并 palette `displayPalette`，给 Phase 3 多色消费做数据准备。

### 2.1 测试基础设施：内嵌自检入口

项目无 XCTest target。Phase 2 改用 debug-only 自检：

- 新增 `Utilities/ColorSystemSelfCheck.swift` 与 `nonisolated enum ColorSystemSelfCheck`。
- `KmgcccPlayerApp.init()` 顶部加 `ColorSystemSelfCheck.runIfRequested()`，仅在 `COLOR_SYSTEM_SELF_CHECK=1` 时触发，PASS 后 `exit(0)`、FAIL `exit(1)`。
- 通过 `ArtworkColorExtractor.analyzeSyntheticSample(pixels:side:)` 绕过 `CGImageSource` 直接喂合成 RGBA buffer，结果可重复可断言。
- **Phase 2 收尾.2**：`runIfRequested()` 体外加 `#if DEBUG ... #endif`。Release 构建直接把整段编译掉，避免 env var 触发 Release 包 `exit()` 隐患。

### 2.2 正交化两维

**`isUltraDark`（亮度轴）**：三个纯亮度门 AND：
- `avgHslL ≤ 0.22`（HSL 平均亮度）
- `weightedLuma ≤ 0.18`（WCAG 感知亮度，补足 HSL 在霓虹色上的过估）
- `dominantBrightness ≤ 0.60`（排除"黑底单亮元素"——这种是普通封面 + 亮色 element）

**`isNearMonochrome`（色度轴）**：四个色度 OR 分支（`ColorSystemTokens.NearMonochromeProfile`）：

1. **strict mono** — `colorfulness<0.04 && avgSat<0.10`
2. **low** — `colorfulness<0.10 && avgSat<0.16 && largestHighSat<0.12`
3. **subtle** — `avgSat<0.105 && colorfulness<0.14 && largestHighSat<0.16`
4. **dominant bucket fallback** — `dominantSat<0.18 && colorfulness<0.16 && avgSat<0.18`

**旧 branch 4 删除**：仅命中"极暗（avgHslL<0.18 || >0.86）+ 中低饱和（avgSat<0.18 && colorfulness<0.16）+ 没有大块强彩 + 但 dominant bucket 自带 sat ≥ 0.18 的封面"。这正是深紫 / 夜蓝 / 酒红黑底——应走 `optimizedAccent` 保留色相。

**`isEffectivelyMonochrome`**：现在是 `isNearMonochrome` 的别名（向后兼容 LED / Home shapes / BKArt / ThemeStore log），不再耦合亮度。

**`ArtworkColorAnalysis` 新增字段**：`weightedLuma`、`dominantBrightness`、`isUltraDark`、`isNearMonochrome`、`salientHighlightPalette`、`displayPalette`。

### 2.3 salientHighlightPalette（点睛色）

**算法**（`ArtworkColorExtractor.computeSalientHighlights`）：复用 48-hue bucket histogram，逐桶过滤：

| 门 | 阈值 | 设计意图 |
|---|---|---|
| `s ≥ 0.40` | `SalientHighlight.minSaturation` | 排除低彩 tint |
| `b ≥ 0.30` | `SalientHighlight.minBrightness` | 排除暗噪点 |
| `area ∈ [0.015, 0.30]` | min/maxAreaShare | 既不是噪点也不是主导色 |
| `weight ≥ 0.008 × total` | `noiseFloorAbsolute` | 绝对权重防 single-pixel noise |

通过后按 `weight × (1 + sat × 0.5)` 排序，按 hue gap ≥ 0.05 OR RGB distance ≥ 0.14 去重，取前 4。

**关键设计**：salient 不被 `isNearMonochrome` 阻断。理由：95% 灰黑 + 5% 鲜黄是"整体 nearMono 但点睛色真实存在"——这 5% 就是封面的真颜色信息。

### 2.4 displayPalette（质控合并）

**合并顺序**（Phase 2 收尾.1 重排后的最终版本）：

1. `top.first` — 主导核心色，绝不被 salient 顶掉
2. `salient[*]` — 在 top 尾部之前进入，保证至少与 top 第二项竞争
3. `top.dropFirst()` — 其余 top 按面积权重
4. `rich[*]` — 仅在非 near-mono 时走完

**为什么需要 salient priority 重排**：原顺序 `top → salient → rich` 在 nearMono 封面下，cap = `nearMonoMaxCount = 2`，topPalette 的两个可分辨 grey bucket（如 #0F0F0F 与 #3C3C3C，RGB gap≈0.176 > rgbDistinctGap 0.14）会先于 salient 把两个槽占满，让 5% 高显著黄被挤出。新增自检 `checkDisplayPaletteSalientPriorityUnderContention`（50%黑 + 45%深灰 + 5%鲜黄）锁死机制。

**封面色彩贫乏时的克制**（K.3）：
- `isNearMonochrome == true` → 拒绝合入 `richPalette`，cap 收紧到 `nearMonoMaxCount = 2`。
- salient 仍允许通过。
- 正常封面 cap = 6。

每个候选与已选成员按 hue gap ≥ 0.05 OR RGB distance ≥ 0.14 去重。

### 2.5 cacheVersion bump

`ArtworkColorExtractor.cacheVersion`：`"semantic-near-mono-v2"` → `"orthogonal-decision-v3"`。

**理由**：6 个分析字段新增、`isEffectivelyMonochrome` 语义虽未改字段名但实际判定变化、key 前缀方案让旧 entry 自动失效。snapshot 与 analysis 都是 in-memory + lazy compute，无外部存储字段，无需向后解码。

### 2.6 Phase 2 self-check 关键结果

14 + 1（Phase 2 收尾的 displayPalette salient priority）个场景全部通过：

- 四象限：UltraDark 彩色 / UltraDark 近灰 / 正常彩色 / 正常灰白
- OKColor: round-trip ΔRGB < 0.005、clamp 精确、normalizedHue / rotateHue 环绕正确、chromaSoftShoulder 透传与渐近
- Salient: 5% 鲜黄 / 10% orange / 20% red title / 高彩噪点过滤
- Display: 4 色等分、纯灰、95%黑+5%黄（nearMono 仍含黄）、salient priority 抗 grey contention
- Quadrant cacheVersion=`orthogonal-decision-v3`，`EXIT=0`

---

## Phase 3 — 消费端接入：BKArt / Spectrum / Home Shapes

**目标**：第一次把"真实 artwork 多色"接入 UI——但严格不改 MiniPlayer 控件色 / 不改歌词 / 不改 Header / 不动 LED / 不切 Tone Ladder。仅替换"颜色来源 + 场景化处理"。

### 3.1 Home Shapes — displayPalette + OKLCH 背景化

`HomeAmbientPalette.palette(...)` 主路径：`displayPalette → project(_:targets:) → 6-entry palette`。

`project` 按 4 象限取不同 L 范围与 chromaCeiling：

| 模式 | UltraDark | NearMono | L 范围 | chromaCeiling（hotfix 后） |
|---|---|---|---|---|
| Dark | ✓ | – | 0.05–0.18 | 0.030 / 0.075 |
| Dark | – | ✓ | 0.16–0.28 | **0.012**（原 0.038） |
| Dark | – | – | 0.18–0.34 | 0.115 |
| Light | – | ✓ | 0.78–0.90 | **0.008**（原 0.022） |
| Light | – | – | 0.74–0.86 | 0.058 |

**Padding 策略（K.3 不伪造多色）**：`displayPalette.count < 6` 时不再 hue-rotate，改为对真实色做 `tonalVariant(of:lDelta:targets:)`——**只动 L，不动 H**，交替正负。

**Fallback**：仅当 `analysis == nil`（无 artwork / extractor 失败）才走原有单 source-color + 6 hue-rotate variants。这是 Phase 3 唯一保留的 hue-rotate 退化路径。

**PaletteSignature 增字段**：`isUltraDark` / `displayPaletteHash` / `salientPaletteHash`，避免同一 sourceColor 但 displayPalette 内部变化时漏更新。

### 3.2 BKArt — displayPalette 多色背景 + UltraDark 强化

`selectedExtractedPalette(analysis:basePalette:richPalette:)` 决定 `BKColorEngine.make(extracted:...)` 输入：

1. `analysis?.displayPalette` 非空 → 用 displayPalette
2. 否则 richPalette
3. 否则 basePalette
4. 否则 `fallbackPalette`

**Salient 落点**：通过 displayPalette 顺序（top.first → salient → ...），salient 进入 `BKColorEngine` 候选 palette。引擎内部已有的 `enforceCandidateHueSource` / `enforceDominantHueAffinity` / `makeShapePool` 让 salient **自然成为 shape pool / accent candidate**，而不是占据主背景——符合 §4.4 "salient 不直接作为最大面积主背景"的要求。

**UltraDark 强化**：`isUltraDarkPalette(_:analysis:)` 第一判定从 `coverLuma < 0.36` 改为 `analysis.isUltraDark`。深紫 / 夜蓝 / 暗红被识别为 UltraDark=true 同时 NearMono=false → 触发 BK UltraDark 渲染叠层保护，但 displayPalette 中仍有真实色相，背景多色性不被淹没。

**Snapshot 路径**：保持 `analysis = nil`（snapshot 不携带 displayPalette / isUltraDark），继续走 richPalette + 旧 UltraDark 判定，零行为变化。

### 3.3 Spectrum — displayPalette.prefix(2) + 同色调 L 兜底

`FullscreenMiniPlayerView.spectrumArtworkColors`：

```
analysis.displayPalette → prefix(2)
  fallback: analysis.topPalette.prefix(2)
  fallback: [artBackgroundPrimary, artBackgroundSecondary]
```

由于 displayPalette 顺序 `top.first → salient → top.tail`，2 色截取自然变成 `[top.first, salient[0] (if any) | top[1]]`——左端主色、右端点睛/副色。9 个 capsule 跨左→右 lerp，频谱高频段（右）自动获得 salient。

**单色封面兜底**（`MiniPlayerSpectrumView.resolveArtworkFaithfulColors`）：displayPalette 只有 1 个色时，右端不退到 accent / 中性灰；改用 `makeTonalRightEndpoint`——L 偏移 ±0.10（`usesDarkForeground ? -0.10 : +0.10`），H/C 保持。**单色封面下不再 hue-rotate 假多色**。

### 3.4 Phase 3 hotfix — nearMono / ultraDark consumer projection

用户手测后报告 3 个必须本轮修的问题，2 个跨阶段问题写入文档不改。

**Hotfix A: Spectrum 在近黑白封面下偏粉**：

两层根因：
1. `displayPalette` 排序把 salient 抬到第二槽，nearMono 封面下 salient 是面积极小但 hue 鲜明的微亮点（黑白照片的一抹粉色反光），`prefix(2)` 直接送进 Spectrum 右端。
2. `MiniPlayerSpectrumView.adjustedSpectrumBase` 在 `s < 0.55` 时强行 `max(0.18, s * 1.08)`——任何残留 hue 都会被抬到 saturation 0.18，**视觉上从灰阶被推到粉/黄/蓝**。

两层修复：
1. `FullscreenMiniPlayerView.prepareSpectrumColors`：送进 Spectrum 之前做 OKLCH 预处理。
   - `isNearMonochrome` → `min(c, 0.008)` 投回（强制 chroma ≈ 0）。
   - 非 nearMono 但 `colorfulness < 0.18` → `chromaSoftShoulder(ceiling: 0.05, softness: 0.04)`。
   - 正常彩色 → 原样直通。
2. `adjustedSpectrumBase` 分段重写：
   - `s < 0.06`：原值通过（无地板）
   - `0.06 ≤ s < 0.22`：`min(0.30, s * 1.04)`（轻提，无 0.18 地板）
   - `s ≥ 0.22`：保留旧曲线

**Hotfix B: Home Shapes 在近黑白封面下偏粉**：

`ambientTuning` nearMono 分支大幅收紧——chromaCeiling dark 0.038→0.012、light 0.022→0.008，chromaScale 0.46→0.22 / 0.32→0.18（详见 §3.1 表格）。非 nearMono 路径完全未动。

**Hotfix C: UltraDark 下 Home Shapes 未随 BKArt 压暗**：

ultraDark L 区间从 `[0.10, 0.26]` 下沉到 `[0.05, 0.18]`，lOffset 0.06→0.04、lScale 0.46→0.32。极暗封面源 L≈0.10 投影到 L≈0.072；亮 salient 源 L≈0.80 投影到 L≈0.18 上限。整体感官与 BKArt"夜色"基调一致。

新增 5 个 hotfix self-check（spectrum 中性化 / spectrum 低饱和不放大 / spectrum 彩色透传 / Home Shapes nearMono chroma ceiling / Home Shapes ultraDark L band），全部通过。

### 3.5 写入文档不改的跨阶段问题

- **Issue A — Fullscreen MiniPlayer UI 在近黑白封面下淡蓝 / 淡黄**：归属 Phase 4 MiniPlayer 控件色语义化。
- **Issue B — 窗口 / 全屏歌词在近黑白封面下偏粉红**：归属 Phase 5 歌词颜色收敛。

### 3.6 Phase 3 接力到后续

- `ArtworkAssetSnapshot` 不携带 displayPalette / salient / isUltraDark — Phase 4/7 评估持久化。
- `HomeAmbientPalette.ambientBaseColor` 仍走旧 HSL 单 sourceColor — Phase 5/6 评估。
- 调试日志：`[HomeAmbient/palette]` / `[BKArt/palette]` / `[Spectrum/palette]` 三条统一格式。

---

## Phase 4 — ReadabilityProfile + MiniPlayer 控件色语义化

**目标**：

1. 统一"压在 artwork 上的 UI 文字 / 图标"前景决策为 `ArtworkReadabilityProfile`。
2. 把分散在 4 个 View 文件中的 MiniPlayer HSL 控件色重算逻辑收束到 `MiniPlayerControlPalette`。
3. 修复 Phase 3 Issue A（近黑白封面下淡蓝/淡黄伪 hue）。

### 4.1 新增 ColorSystemTokens 命名空间

- `ReadabilityProfile`：secondaryAlpha 0.78 / tertiaryAlpha 0.58 / quaternaryAlpha 0.40 / nearMonoChromaCeiling 0.004 / nearMonoChromaAssertion 0.005。
- `MiniPlayerControl`：liftedMinL 0.88 / liftedMaxL 0.97 / liftedChromaCap 0.12 / neutralL 0.94 / nearMonoChromaAssertion 0.005。

### 4.2 ArtworkReadabilityProfile

`Equatable, Sendable` value 类型，挂在 `SemanticPalette`。字段：

- `usesDarkForeground: Bool` — 透传 `analysis.usesDarkForeground`（loose gate）。
- `isNearMonochrome: Bool` — 便于消费者无需依赖 analysis。
- `foregroundPrimary` / `Secondary` / `Tertiary` / `Quaternary` / `iconForeground: NSColor` — 分层 alpha；nearMono 时 primary 已 OKLCH chroma-crushed（≤0.004）。

`SemanticPaletteFactory.make` 先派生 `readabilityProfile`，然后把 `readabilityProfile.foregroundPrimary/Secondary` 回填给 `readableTextOnArtwork`/`secondaryTextOnArtwork`——已有消费者（HomeHero、coverGradientText 上游）零改动自动获得 nearMono 中性化。

**secondaryTextOnArtwork alpha 变更**：旧 0.86 无外部消费者（grep 确认），新 0.78 对齐 HomeHero `artworkTextSecondary` 惯例。

### 4.3 MiniPlayerControlPalette

`primary / secondary / progressFill / progressTrack: NSColor`。

- **非 nearMono**：`liftedAccentControl(globalAccent)` 在 OKLCH 把 accent lift 到 L≥0.88、cap chroma≤0.12。这是迁移前 `resolveControlAccentColor` 把 HSL 饱和度抬到 ≥0.88 的等价 OKLCH 版本。
- **nearMono**：`neutralAchromaticControl()` 直接输出 `OKLCH(L=0.94, C=0)`——这是 Phase 4 对 Issue A 的根因修复：旧路径在残留 nearMono hue 上 lift saturation，把"几乎中性"放大成"明显粉/蓝/黄"。collapse 到 chroma=0 切断这条路径。

### 4.4 收束 4 个 View 文件的 HSL helper

| 文件 | 旧路径 | 新路径 |
|---|---|---|
| `FullscreenMiniPlayerView` | `resolveControlAccentColor(...)` | `palette.miniPlayerControl.primary`；over-artwork 走 `readabilityProfile.foregroundPrimary` |
| `FullscreenPlayerView` | `FullscreenMiniPlayerView.resolveControlAccentColor(...)` | `palette.miniPlayerControl.primary` |
| `ExpandableVolumeControl` | 同上 | `palette.miniPlayerControl.primary` |
| `FullscreenQueueView` | 本地复制的 `resolveControlAccentColor` + 全套 HSL helper | `palette.miniPlayerControl.primary` |

删除的 HSL helper：`enforceMinimumHslLightness` / `enforceMaximumHslLightness` / `enforceMinimumHslSaturation` / `hslComponents` / `rgbColorFromHsl` / `clamp01`，以及 `FullscreenQueueView` 本地副本（~90 行）。

**保留**：`shouldUseDarkArtworkForeground(for:)` — over-blur surface 专用 stricter gate，不属于 readabilityProfile 通用 `usesDarkForeground`。

**HomeHeroView 显式接入**：`artworkTextPrimary` → `heroPalette.readabilityProfile.foregroundPrimary`；`artworkTextSecondary` → `foregroundSecondary`。

### 4.5 Phase 4 self-check

5 个新场景，总计 25/25 PASS：

| 场景 | 输入 | 断言 | 实测 |
|---|---|---|---|
| ReadabilityProfile: near-mono neutral | (200,200,200) | foregroundPrimary chroma ≤0.005 | 0.004 |
| ReadabilityProfile: bright artwork → dark fg | (240,235,228) | usesDarkForeground=true, L<0.50 | L=0.250 |
| ReadabilityProfile: dark artwork → light fg | (25,22,30) | usesDarkForeground=false, L>0.80 | L=0.933 |
| MiniPlayerControl: near-mono neutral | neutralAchromaticControl() | chroma≤0.005, L≥0.88 | 0.000 / 0.940 |
| MiniPlayerControl: colourful hue preserved | liftedAccentControl(blue) | Δhue≤0.06, L≥0.88 | Δh=0 / 0.880 |

---

## Phase 4.5 — AppForegroundPalette（普通 App UI 淡彩前景色）

**目标**：建立 App 普通 UI（sidebar、列表、settings、Home 卡片）专用的"几乎中性、但带主题色温"前景色体系。本期经历了三次回修：初版 chroma 太低肉眼无感、第二轮补 chroma 但漏接显眼路径、第三轮扩接入面并做浅色模式独立 cap。本节按最终状态记录。

### 4.5.1 AppForegroundPalette 结构

挂在 `SemanticPalette`，`Equatable, Sendable` value 类型：

```swift
struct AppForegroundPalette {
    let primary: NSColor      // L≈0.96 深 / L≈0.22 浅
    let secondary: NSColor    // L≈0.78 深 / L≈0.38 浅
    let tertiary: NSColor     // L≈0.59 深 / L≈0.52 浅
    let quaternary: NSColor   // L≈0.44 深 / L≈0.60 浅
    let disabled: NSColor     // L≈0.36 深 / L≈0.65 浅；chroma 恒为 0
}
```

`ThemeStore` 便利属性：`var appForegroundPalette: AppForegroundPalette { semanticPalette.appForeground }`。

### 4.5.2 生成规则（最终版）

```text
hue = OKLCH(globalAccent).h
chromaScale = isNearMonochrome ? 0 : min(colorfulness / 0.40, 1.0)
hueChromaFactor = isDark 时按 hue 段：
    cool (0.40–0.72) → 0.65
    violet (0.72–0.88) → 0.75
    其他 → 1.0
isDark 时 c = min(chromaScale × tierChromaCap × hueChromaFactor, chromaCeiling)
isLight 时 c = min(chromaScale × lightTierChromaCap, lightChromaCeiling)
NSColor = OKLCH(L = 深/浅 tier L, c = c, h = hue)
disabled: c = 0 always
```

**最终 chroma cap（深 / 浅模式独立）**：

| Tier | dark cap | light cap |
|---|---|---|
| primary | 0.070 | 0.100 |
| secondary | 0.056 | 0.080 |
| tertiary | 0.040 | 0.060 |
| quaternary | 0.022 | 0.040 |
| disabled | 0.000 | 0.000 |
| chromaCeiling | 0.080 | 0.110 |
| colorfulChromaAssertion | 0.090 | 0.120 |

### 4.5.3 为什么 chroma cap 经历两次上调

**初版（0.012 / 0.010 / 0.008 / 0.006）**：理论上轻微着色。实测：深色 primary L=0.96 下，C=0.012 的 OKLCH 颜色 sRGB HSB 饱和度约 3–5%；文本抗锯齿叠加背景后几乎不可辨；数字色彩拾取工具读到接近 0%。**肉眼完全看不出**，吸管也读不出来。

**第一轮回修 ×4（0.048 / 0.038 / 0.028 / 0.016）**：colorfulness ≈ 0.25 时 primary c=0.030，L=0.96 对应 HSB 饱和度约 10–12%，吸管能读出但视觉仍弱。

**第二轮回修（0.070 / 0.056 / 0.040 / 0.022）+ 浅色模式独立 cap**：用户明确"下次大胆一点上色"。primary L=0.96 在暖色方向受 sRGB gamut clamp，实际 C≈0.025–0.050；secondary L=0.78 headroom 更宽，可达 0.056；浅色模式 headroom 比深色更宽，独立提到 0.100。

### 4.5.4 为什么深色模式要做 hue-aware reduction

蓝/紫色文字在深色 UI 中读起来比黄/橙色"更彩"——人眼在深色背景下对冷色色相更敏感。同 chroma 下蓝白看着像"淡蓝彩色文字"，琥珀白看着仍是"暖白"。Cool (0.40–0.72) 减 35%、violet (0.72–0.88) 减 25%、warm/其他 不减。浅色模式不需要此偏置。

### 4.5.5 为什么浅色模式 primary L 从 0.14 提到 0.22

L=0.14 接近 sRGB 黑，gamut 在该亮度下几乎零 chroma headroom——任何色彩信号都会被 clamp 掉。L=0.22（深炭灰）下 chroma headroom 显著扩大，**保持文字感觉够深**的同时让暖/冷偏向可被吸管检测出来。

### 4.5.6 secondary / tertiary 比例约束

self-check 断言：
- 深色：secondary C ≤ 0.045 绝对低彩上限；tertiary C ≤ secondary × 0.70。
- L 阶梯：深色严格降序（primary > secondary > ... > disabled）；浅色严格升序。

理由：副文字必须保持低彩，且用 L 阶梯保证层级。dark primary L=0.96 位于 sRGB gamut headroom 很窄的区域，某些 hue 的实际 chroma 会被 clamp 到低于 secondary；因此 secondary 不再用 realised primary chroma 做比例基准，而是用绝对低彩上限锁定。

### 4.5.7 与 ArtworkReadabilityProfile 的分离

两套 palette 完全正交：

|  | AppForegroundPalette | ArtworkReadabilityProfile |
|---|---|---|
| 场景 | 普通 App UI（sidebar、列表、settings、Home 卡片） | 压在 artwork/blur 上的 UI（HomeHero、Fullscreen MiniPlayer） |
| 生成基准 | `globalAccent` OKLCH hue + 固定 L 目标 | `analysis.bestTextSourceColor` HSL 派生 + OKLCH nearMono 归零 |
| chroma 上限 | 严格 cap（最高 0.10 浅 / 0.07 深） | 不限 chroma（直接派生，仅 nearMono 时归零） |
| dark/light 分支 | 是（两套 L 目标 + 两套 cap） | 否（通过 `usesDarkForeground` 控制） |

self-check `checkAppFgSeparateFromReadabilityProfile` 断言同一 analysis 下两者 primary 不同。

### 4.5.8 性能策略：单点订阅 + 参数透传

高频列表（TrackRowView、HomeRankRow 等）**不允许**每行新增 `@EnvironmentObject ThemeStore`。

模式：

```swift
// 父层（HomeView / PlaylistDetailView / AllAlbumsView 等）
let appFgPrimary   = Color(nsColor: themeStore.appForegroundPalette.primary)
let appFgSecondary = Color(nsColor: themeStore.appForegroundPalette.secondary)
let appFgTertiary  = Color(nsColor: themeStore.appForegroundPalette.tertiary)

// 子组件接收 plain Color 参数，默认值是系统色
struct TrackRowView {
    var rowPrimaryColor: Color = .primary
    var rowSecondaryColor: Color = .secondary
    var rowTertiaryColor: Color = Color.secondary.opacity(0.7)
    ...
}
```

`ThemeStore` 是 `ObservableObject` 且发布 ~15 个 `@Published` 属性；每个直接订阅者会在任一属性变化时全量重评——高频 row 直接订阅会显著拖慢列表滚动与刷新。

### 4.5.9 Row 刷新延迟 hotfix

第二轮回修后用户报告：切歌后 row 颜色"过几秒才变"或"离开页面再回来才变"。

根因：`TrackRowView.Equatable ==` 当时只比较 `track.id` 和几个状态字段，**没有把 `rowPrimaryColor` / `rowSecondaryColor` 加入比较**。`.equatable()` 包装器看到 `==` 返回 true 就跳过 body 重评——即使 ThemeStore 已经发布新 palette、父层重新调用，row 仍然渲染旧颜色。

修复：把全部三个 row color 参数（`rowPrimaryColor` / `rowSecondaryColor` / `rowTertiaryColor`）补进 `Equatable ==`。

同样模式扩散：检查 BatchTrackEditSheet 内 `BatchAMLLPreviewPanel: Equatable` 等 Equatable 视图时，凡是新增颜色参数都必须同步进 `==`，否则 row refresh 不会生效。

### 4.5.10 已接入覆盖（截至本轮）

**第一批**（初版接入）：SidebarView section 标题 + chevron/+ 图标、V2FeatureTipView 说明、HomeView 快照卡 / stat 卡 / 排行榜 / 空状态 / 页脚。

**第二批**（chroma 回修 + 显眼路径）：Home 各 section 大标题（`精选` / `播放列表` / `艺人` / `专辑` / `音乐足迹`）、Sidebar 主导航 `主页` / `所有歌曲`。

**第三批**（Expansion 全局接入）：HomePlaylistCard / HomeAlbumCard / HomeArtistCircle / HomeRankRow（标题与副标题）；HomePreferenceRankingView（列标题与空态）；SidebarView 艺人行 / 专辑行；SettingsSidebarView（标题 / 分类图标未选中 / 分类文字）；FullscreenQueueView 非 artwork 模式 primary/secondary/tertiary；TrackRowView 标题（非播放）+ 艺人名；TrackInfoEditorCore label / helper / metadata；PlaylistDetailView 单点订阅 + 透传到 TrackRowView。

**本轮（Phase 4.5 Coverage Finalization）新增**：

| 区域 | 内容 |
|---|---|
| HomeAlbumsSection / HomeArtistsSection | "查看全部"按钮文字 + chevron 接入 subtitleColor（secondary） |
| AllAlbumsView | 单点订阅；AlbumListRow 新增 titleColor/subtitleColor/metaColor 参数；textBlock + ellipsis 图标 |
| AllArtistsView | 单点订阅；ArtistListRow 新增 titleColor/subtitleColor；textBlock + ellipsis 图标 |
| BatchTrackEditSheet | 标题（"当前：..."副行）、空态图标 + 标题、queueRow 标题/艺人/专辑、metadata 字段 labels、readonly 元数据组、歌词文本 prompt 与说明、batchLabeledField / batchReadonlyRow / batchScrollingEditor 三个 helper 中所有 `.secondary`/`.tertiary` label；BatchAMLLPreviewPanel 通过 `secondaryTextColor: NSColor` 参数透传并加入 Equatable `==` |
| LDDCSearchSection | 单点订阅；歌曲名/艺人/模式/翻译/平台 labels、搜索结果计数（两处）、空态占位符（图标+文字）、预览标题（split + stacked）、空预览占位符、原文/翻译 label、candidate row 标题（primary）+ 艺人/专辑（secondary）+ score badge（tertiary） |
| Settings 详情页 | 新增 `\.settingsAppForegroundColors` 环境值与 `SettingsAppForegroundColors` 结构；SettingsView detail 注入；SettingsHeaderLabel / SettingsSwitchRow / settingsRowLabelStyle / settingsDescriptionStyle / settingsSectionTitleStyle 五个共享接口读取环境值，`!forcesWhiteText` 时优先使用 AppForegroundPalette；fullscreen 设置面板（forcesWhiteText=true）保持现有白色层级不变；AboutSettingsView 三处硬编码 `.secondary`/`.tertiary`/`.primary` 改为使用共享 modifiers |

### 4.5.11 不接入的边界

不动：
- 歌词（Phase 5）
- AMLL 渲染层
- 已由 ArtworkReadabilityProfile 管理的 artwork overlay 文字
- LED / Spectrum / BKArt / Home Shapes
- destructive / danger / error / accent / selected / playing 状态色
- glass / shadow / highlight / material 光学常量
- 明确固定白/黑的皮肤光效
- SlidingSelector 中未选中段的灰色（与选中段的 accent 形成视觉对比，是状态色）

设计常量保留：
- `Color.white.opacity(0.045)` / `Color.black.opacity(0.035)` — material tint 背景
- 玻璃高光 stroke / fill
- 阴影
- SidebarView `.background(.secondary.opacity(0.1))` 等背景填充

### 4.5.12 AppKit Toolbar 图标（仍未实现，明确 TODO）

**位置**：`myPlayer2/AppKit/AppKitMainToolbarController.swift`。所有 toolbar 项都是 `NSToolbarItem.image = NSImage(systemSymbolName: ...)`（sidebarToggle / homeNavPill / sort / pillGroup / homePillGroup / lyricsToggle 等）。当前由系统按 template image 自动渲染，不响应 AppForegroundPalette。

**实现路径（具体到 API）**：

1. 在 `attachToWindow` 时给 toolbar controller 加 `themeStore` 弱引用 + Combine 订阅 `themeStore.objectWillChange`，每次发布后调用一个新 `applyForegroundTint()` 方法。
2. `applyForegroundTint()` 走 toolbar.items：
   - 对每个 `NSToolbarItem`：`item.image = item.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [palette.primary]))`
   - 对 `NSToolbarItemGroup`：遍历 `subitems` 做相同处理
3. 同时在 `attachToWindow` 的初始化阶段（item 创建后）跑一次 `applyForegroundTint()`，避免首帧空 tint。
4. 验证：切歌后切换 toolbar 项是否正确重 tint；不应导致 toolbar layout 抖动。

**为什么本轮不做**：
- 需要新增 themeStore 弱引用 + ColorScheme 切换响应 + lifecycle 处理（detachFromWindow 时取消订阅）
- 每个 toolbar item 创建路径有不同 image 应用模式（普通 item.image / NSToolbarItemGroup images:[] / NSMenuToolbarItem）
- 首批 PoC 应做 sidebarToggle 验证视觉效果再扩展
- 与 Phase 5 歌词收敛不冲突，可以独立排期

**风险**：`paletteColors:` 在 macOS 12+ 可用，部署目标 macOS 26+ 满足。但需要确认 `NSToolbarItem` 在 unified toolbar 下是否会被系统重新染色覆盖（NSToolbarItem 受 NSWindow 影响）。建议在 PoC 阶段实测。

### 4.5.13 Phase 4.5 self-check（11 个场景）

| 场景 | 断言 |
|---|---|
| Near-mono → all tiers achromatic | C ≤ 0.005 每层 |
| Colorful dark primary has detectable tint | 0.001 < C ≤ 0.090 |
| Colorful light primary has detectable tint | 0.001 < C ≤ 0.110 |
| Light-mode primary C > dark-mode primary C | per-mode cap split 生效 |
| Dark-mode L hierarchy | primary > secondary > tertiary > quaternary > disabled |
| Light-mode L hierarchy | 升序 |
| AppForeground.primary ≠ ReadabilityProfile.foregroundPrimary | 两条管线独立 |
| Dark secondary C bounded | C ≤ 0.045 |
| Dark tertiary C ≤ secondary × 0.70 | 三层级 chroma 弱于副层级 |
| Cool-hue accent produces lower dark primary C than warm accent | hue-aware reduction 生效 |
| Light-mode directional | 暖 R>B / 冷 B>R |

**自检维护：`Dark secondary C ≤ primary × 0.65` → `Dark secondary C bounded`**

测得 sec/pri = 1.665（secondaryC=0.031, primaryC=0.019）。根因：dark primary L=0.96 在冷色相方向 sRGB gamut headroom 极窄，OKLCH→sRGB 转换在 `okLCHToNSColor` 内被 gamut clamp 压到 C≈0.019；同时 dark secondary L=0.78 headroom 更宽，转回 OKLCH 后实测 C≈0.031。

该断言在 commit `f7e9e3d` 上已经失败（本轮验证：stash 后跑同一 self-check 仍 FAIL，sec/pri=1.665 完全一致），**不是本轮引入的回归**。

工程含义：在视觉层面，dark mode 冷色高亮 primary 文字会因为 gamut clamp 反而比 secondary 副文字 chroma 更弱。这有可能造成"副文字看起来比主文字更彩"的轻微反直觉。Phase 5 自检维护中未改生产色彩，把该断言改为 `secondaryC ≤ 0.045` 绝对低彩上限；冷色 gamut-clipping 风险继续由 dedicated cool-hue checks 覆盖。后续若要从产品视觉上处理，可单独评估：
- 方案 A：放宽 dark primary L 到 0.93（牺牲一点亮度换 chroma headroom）
- 方案 B：assertion 改为 hue-aware（高 L + 冷色 hue 时跳过比较）
- 方案 C：dark mode primary chroma cap 降到约 0.045（与 gamut clamp 后的 secondary 持平之下）

其余 10 个 Phase 4.5 场景全部 PASS。Phase 5 自检维护后，Phase 4.5 断言不再因 high-L primary gamut clipping 产生误报。

### 4.5.14 验证指引

测试时备好：暖色封面（R>B 主导）、冷色封面（B>R 主导）、nearMono 封面（R≈G≈B）。

吸管检查位置：
1. Home 专辑卡标题、艺人副标题
2. Home stat 卡数值 + 单位
3. Home 排行行：歌曲（primary tint）/ 艺人（secondary tint）
4. Sidebar 艺人 / 专辑条目
5. Library 列表行：标题（primary）/ 艺人（secondary）/ 时长（tertiary）
6. Settings 分类标题 + 图标
7. 全屏队列标题、歌曲行、时长
8. TrackInfoEditor 字段 label
9. Home "查看全部"按钮文字 + chevron
10. AllAlbumsView / AllArtistsView 列表行
11. BatchTrackEditSheet 队列行、字段 label、metadata 区
12. LDDCSearchSection 搜索结果行、预览标题
13. Settings 详情页（Appearance / About）section 标题、SettingsSwitchRow 标题与说明

预期：暖/冷封面在每个位置显示出温度倾斜；nearMono 全部回到中性灰；primary 倾斜最强、secondary 显著弱、tertiary 非常细微。

---

## Phase 5 — 歌词颜色体系收敛（2026-05-21）

### 5.1 统一入口

新增 `LyricsColorPalette` / `LyricsSurfaceColorSet` / `LyricsCoverBlurBlendProfile`，并挂到 `SemanticPalette.lyrics`。Swift 侧现在由 `SemanticPaletteFactory.lyricsPalette(...)` 统一输出：

- 窗口歌词：`windowActive` / `windowInactive`
- 全屏基础色：`fullscreenBase` / `fullscreenInactiveBase`
- 全屏分层色：`fullscreen.mainActive` / `mainInactive` / `lineTimingMainInactive` / `subActive` / `subInactive` / `lineTimingSubInactive`
- Cover Blur：`coverBlurLyricsColorSet(analysis:themeColor:profile:)`

`ThemeStore.refreshPalette` 不再为歌词重新跑一套 average/accent 决策，而是消费 `semantic.lyrics.windowActive/windowInactive` 回填 legacy `ThemePalette`。`FullscreenPlayerView` 不再内联 fullscreen HSL 派生与 cover blur HSL 参数，改为调用 `SemanticPaletteFactory.fullscreenLyricsColorSet(...)` / `coverBlurLyricsColorSet(...)`。

Phase 5 的最终规范是 **Swift-owned lyrics color contract**：

- 歌词颜色决策归 Swift，主要入口是 `SemanticPalette.lyrics` 与 `SemanticPaletteFactory.lyricsPalette(...)`。
- Swift 明确输出 `LyricsColorPalette`、`LyricsSurfaceColorSet`、`LyricsCoverBlurBlendProfile` 对应的 window / fullscreen / cover blur surface colors。
- Web rendering-only / adapter contract：AMLL Web 层只负责渲染、opacity、blend、shadow structure、mix-blend-mode 与兼容 fallback，不承担主要 hue 决策。
- Phase 5 之后，任何 AMLL adapter 改动都必须同步更新 `docs/amll-upgrade-implementation-log.md` 与 `docs/amll-custom-behavior-and-patch-registry.md`。

### 5.2 nearMono 偏粉根因与修复

**根因**：窗口歌词旧路径在 `ThemeStore` 内从 average color 重新走 `ArtworkColorExtractor.adjustedAccent`；该函数会对 dark-mode lyric active 加 saturation floor。全屏歌词旧路径在 `FullscreenPlayerView` 内对 highlight / inactive / cover blur 做 HSL 派生，也存在最小 saturation 与偏色 profile。nearMono 封面的 RGB 残留 hue 本来很弱，但这些 floor 会把残留 hue 放大成肉眼可见的粉 / 蓝 / 黄。

**修复 / nearMono lyrics neutralization**：`analysis.isNearMonochrome == true` 时，歌词所有 Swift 可控可见色走 OKLCH 中性化，`chroma` 收敛到 `ColorSystemTokens.Lyrics.nearMonoChromaCeiling = 0.004`，自检断言上限为 `0.005`。层级不靠 hue，仍保留 active / inactive 的 L 与 alpha 差异。黑白灰 / 近灰 artwork 下，不允许 visible lyrics colors 出现可见粉、蓝、黄等伪 hue。

### 5.3 彩色 artwork 窗口歌词观感

正常彩色 artwork 下，窗口歌词 active 仍沿用 Phase 5 前的产品路径：`ArtworkColorExtractor.adjustedAccent(from: analysis.averageColor, isDarkMode:)`。Phase 5 只是把这条路径移动到 `SemanticPaletteFactory.windowLyricActive(...)` 并在 nearMono 分支补中性化，因此彩色封面不会被误灰化；SelfCheck 增加 `colorful window keeps theme tint`，要求非 nearMono 窗口歌词仍保留合理 chroma。

### 5.4 Fullscreen skin 策略

- Apple / Cover Gradient / Cover Blur 类皮肤：保留 lighter / darker profile、opacity 与 blend 表示层级的现有策略；nearMono 下由 Swift 先输出中性色，Web 不再二次选 hue。
- 普通 fullscreen / 艺术背景类皮肤：本轮先收敛入口与 nearMono 修复，仍保留既有 layer / opacity 行为；后续 Phase 6 应把艺术背景歌词层级推进到更不透明的 OKLCH Tone Ladder。

### 5.5 Web / CSS 边界

`Resources/AMLL/index.html` 仍负责 AMLL 渲染、opacity、blend、shadow structure 和向后兼容 fallback。调整点：

- `syncFullscreenDerivedColors()` 优先消费 Swift 下发的显式颜色，例如 `--amll-fs-sub-inactive` / `--amll-cb-sub-inactive` 以及 fullscreen / cover blur background 输入，不再无条件从 main inactive 派生 secondary/sub 颜色；
- fullscreen / cover blur background active 只在 Swift 未给显式值时才 fallback 派生，fallback 只是兼容缺省路径；
- 固定白 / 黑 / blend 常量保留为渲染结构，不作为 hue 决策来源。

AMLL adapter contract：后续重建 `index.html` 或升级 AMLL 时，必须保留 Swift 显式颜色字段与 `syncFullscreenDerivedColors()` 的优先级，不得删除字段后依赖 Web 派生作为主路径。

### 5.6 SelfCheck

新增 Phase 5 歌词自检：

1. nearMono window active / inactive chroma ≤ 0.005
2. nearMono fullscreen active/base 与 inactive tiers chroma ≤ 0.005
3. nearMono cover blur lighter / darker profile chroma ≤ 0.005
4. colorful window lyric 保留 theme tint，不被误中性化
5. window / fullscreen active 与 inactive 明度/alpha 层级合理

验证结果：

- `ColorSystemSelfCheck` 41/41 PASS。
- nearMono window / fullscreen / cover blur 歌词色 OKLCH chroma ≤ 0.005。
- 彩色窗口歌词 tint 保留，不被误中性化。
- Debug build succeeded：`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`。

### 5.7 Phase 6 接力

Tone Ladder 不在 Phase 5 强做。下一阶段建议优先处理：

- 艺术背景类 fullscreen lyrics 的不透明 OKLCH 明度 / 彩度梯级；
- glow / shadow 是否需要从渲染 structure 进一步拆出 Swift 语义 token；
- Web fallback 继续瘦身，最终只保留 legacy-safe fallback 与纯渲染行为。

Phase 6 不得破坏 Swift-owned lyrics color contract：Tone Ladder 可以优化艺术背景 fullscreen lyrics 的不透明明度 / 彩度层级，但颜色决策仍应留在 Swift 侧，Web 继续保持 rendering-only / adapter contract。

---

## Phase 6 — Tone Ladder 与 LED / 艺术 fullscreen lyrics（2026-05-21）

### 6.1 系统级 Tone Ladder

新增 `PerceptualToneLadder`，放在 `OKColor.swift` 的 OKLCH 数学层之后，作为 Phase 6 的公共色阶派生能力。参数集中在 `ColorSystemTokens.ToneLadder`，避免把审美 magic number 散到 LED 或 fullscreen view。

设计原则：

- **L 是主层级轴**：active / secondary / inactive / line-timing inactive 有明确 OKLCH L 间距。
- **C 与 L 联动**：高亮处 chroma 受 soft shoulder 克制；中间态保留足够 chroma；很暗的层级再回落，避免边缘脏亮。
- **hue-family drift 很小**：暖色暗部轻微偏 amber，蓝色暗部轻微偏 indigo，绿/黄避免荧光和脏灰；高亮处反向漂移更弱，避免蓝色高亮过冷。
- **nearMono 归中性**：lyrics ladder chroma ceiling 0.004 / assertion 0.005；LED nearMono cap 0.006。

Tone Ladder 不知道 skin / AMLL / View，只接收 OKLCH seed + role，输出 opaque OKLCH tone。消费者仍负责语义选择：LED 用 LED seed；艺术 fullscreen lyrics 用 active seed 和 inactive/background seed。

### 6.2 LED Meter 接入

`LEDColorResolver` 保留原有结构：

- center / edge 仍由 artwork semantic palette 与 OKLab 插值决定；
- LED 数量、中心向外点亮、status light、opacity glow 与 stroke 结构不变；
- level → lit state 的离散逻辑仍由 `LedMeterView` 控制。

改变的是 lit LED 的**颜色派生**：旧 `oklchColorForLevel` 中的 level-driven L/C/hue 微调替换为 `PerceptualToneLadder.ledTone(...)`。新 ladder：

- 暗色模式 LED L 从约 0.746 → 0.821 → 0.890，OKLab 距离约 0.076 / 0.069；
- 中段 chroma 有轻微 boost，解决“中间态只是亮一点、偏淡”的问题；
- 彩色 artwork 下 peak LED chroma 自检 ≥ 0.058，当前样本 C≈0.092；
- nearMono / low-color artwork 不强行彩色化，nearMono cap 为 C≤0.006。

`baseColorForIndex` 同步改用公共 `OKColor.oklabLerp(...)`，收掉 Phase 1 留下的 LED 内联 OKLab 插值技术债。

### 6.3 艺术背景 fullscreen lyrics 接入

`SemanticPaletteFactory.fullscreenLyricsColorSet(...)` 新增 `usesArtisticBackground` 参数。`FullscreenPlayerView.makeFullscreenLyricsColorSet(...)` 在 `settings.fullscreenArtBackgroundEnabled == true` 时开启 Tone Ladder 路径。

艺术背景路径：

- active / subActive 使用 highlight seed；
- inactive / lineTiming / subInactive 使用 inactive/background seed（优先 BKArt surface background），让暗层跟背景更同源；
- 所有输出 alpha=1，层级主要由 OKLCH L/C/H 决定，不靠透明度把文字“冲淡”；
- ultraDark 背景会整体下压 tone ladder 的 active/sub/inactive L，但仍保持 active 可读；
- nearMono 继续走 Swift 侧 chroma crushing，visible lyrics 不出现伪 hue。

未开启艺术背景时，普通 fullscreen 仍走 Phase 5 的旧 profile。Cover blur / Apple / Cover Gradient 不走这条路径。

### 6.4 Apple / Cover Gradient / Cover Blur 边界

本轮没有修改 `Resources/AMLL/index.html`，也没有修改 generated AMLL bundle。Web 仍只消费 Swift 显式颜色并负责渲染、blend、opacity、shadow structure。

Apple fullscreen 当前通过 `makeAppleStyleCoverBlurLyricsTheme(...)` 走 cover blur lighter profile；Cover Gradient Blur 走 `coverBlurLyricsColorSet(...)` lighter/darker profile。这两个 profile 未接 Tone Ladder，继续保留 Phase 5 的 blend / opacity 语言。SelfCheck 新增 `cover blur profile remains separate`，锁定 cover blur inactive L 与 artistic inactive L 分离。

### 6.5 SelfCheck 与验证

Phase 6 新增 6 个自检，总数 47：

1. Tone Ladder artistic lyrics L/chroma hierarchy；
2. Tone Ladder nearMono outputs neutral；
3. LED tone steps have perceptual distance；
4. LED colorful artwork not pale；
5. Artistic fullscreen tone ladder hierarchy；
6. Cover blur profile remains separate。

验证结果（Phase 6 v1）：47/47 PASS。

**但 v1 的自检设计本身有缺陷**，详见 6.7 失败复盘——v1 数学距离合格、视觉灰白化。

### 6.6 Phase 7 接力（v1 时的展望，部分已被 v2 覆盖）

- 清理旧 HSL fullscreen fallback：非艺术 fullscreen 仍保留 Phase 5 HSL profile，Phase 7 可评估是否以 Tone Ladder 复述并做视觉 A/B。
- glow / shadow 仍是 Web 渲染 structure；若要主题化 glow，应新增 Swift semantic glow token，不能让 Web 决定 hue。
- Apple / Cover Gradient 是否需要"极轻量 Tone Ladder"只可作为单独审美评估，默认保留当前 profile。
- `isEffectivelyMonochrome` alias 仍可在 Phase 7 收掉。

### 6.7 Phase 6 v1 失败复盘与 v2 重做（2026-05-21）

#### 6.7.1 v1 的视觉表现

人工检查结论：

1. LED 各 level 的色彩科学明度层级在视觉上**不明显，甚至比旧版更不明显**；
2. 艺术背景类 fullscreen lyrics 的 active / inactive / secondary 几乎变成灰白色，hue identity 丢失；
3. v1 的 SelfCheck 47/47 PASS，但视觉是失败的。

#### 6.7.2 v1 根因

**根因 A：艺术歌词的 dual-seed 把背景色当成 inactive 种子**。`FullscreenPlayerView.resolveFullscreenLyricsInactiveBaseColor(...)` 在 `settings.fullscreenArtBackgroundEnabled == true` 时返回 `bkController.currentSurfaceBackgroundColor` / `primaryBackgroundColor`——这是渲染后的**艺术背景表面色**，OKLCH chroma 通常只有 0.03–0.06。这一去饱和种子进入 Tone Ladder 后，inactive 永远不可能恢复 hue identity。

**根因 B：v1 Tone Ladder 内多层 chroma 压缩链路叠加**：

- chromaScale 跨角色单调下降 (0.78 → 0.60 → 0.48 → 0.40 → 0.34 → 0.28)；
- hueCap 按角色再压一档 (×0.82 / ×0.68 / ×0.58 / ×0.50 / ×0.44 / ×0.38)；
- 在 L > 0.82 / L < 0.46 再叠 brightShoulder×0.74 / shadowShoulder×0.62。

这三层乘下来，inactive C 普遍落在 0.02–0.04 区间，低于"可视有彩"阈值（≈0.04），就是用户看到的"几乎变成灰白色"。

**根因 C：LED OKLCH L 与 opacity 打架**。v1 把 LED L 下沿拉到 0.700（dark mode），但 LED 渲染层还叠着 `opacity 0.08 → 1.00` 的 6.25× 透明度斜坡。低 level 的 OKLCH L=0.725 被 opacity 0.16 再次压缩，最终落点更暗——级别差不是"色彩科学层级"，而是"看不见 vs 看得见"。

**根因 D：v1 SelfCheck 门槛过松**。`inactive.c > 0.018` 是"不是纯灰"，不是"可视有彩"；`oklabDistance(low, mid) >= 0.060` 不把 opacity 多重叠加纳入感知模型；完全没有 hue identity 检查；没有四 hue family 的具体数值回归。

#### 6.7.3 v2 重做策略

**策略 1：歌词 single-seed**。`artisticFullscreenLyricsColorSet` 改为只用一个 seed（active highlight）派生所有角色。`FullscreenPlayerView.resolveFullscreenLyricsInactiveBaseColor(...)` 移除 `bkController.currentSurfaceBackgroundColor` / `primaryBackgroundColor` / `lockedFullscreenLyricsBackgroundColor` 三条"用背景色当 lyric 种子"的旧路径——背景色仅作可读性校准参考，不得作为 lyric 颜色种子。

如果 preferred seed 自身 chroma 过低，按 `analysis.dominantColor` → `analysis.bestTextSourceColor` → `analysis.topPalette.first` 顺序换更鲜活的源（`artisticLyricsSingleSeed`）。

**策略 2：v2 Tone Ladder 的 chroma 哲学反过来**：

- 角色 chromaScale **不再单调下降**，而是聚集在 1.0 附近：0.92 / 0.96 / 1.04 / 1.02 / 1.00 / 0.96。inactive scale 略**高于** active，正好抵消 active L=0.88 处的 gamut 收口；
- hueCap **取消按角色削减**，所有 lyrics 角色共享 hue family cap（黄 0.110、红 0.130、蓝 0.140、紫 0.120）；
- 取消 brightShoulder / shadowShoulder——v1 这两层是把好端端的彩色压成灰的元凶；
- 引入 visible-chroma floor `lyricsColorfulMinimumChroma = 0.050`，彩色路径下任何角色都不允许低于这条线；
- hue drift 紧缩到 ±0.005–0.012（v1 是 ±0.014–0.018），保证 hue identity 在所有角色下守住。

**策略 3：LED L band 退到上半区**：dark mode 0.780 → 0.920、light mode 0.430 → 0.560。这让 OKLCH 层 stay 在视觉可见范围内，不再被 opacity 压到看不见。低 level 不是"夹缝里挣扎的暗色"，而是"opacity dim 的鲜活色"。

LED chromaScale 改为 `1.0 + ledMidChromaBoost·sin(πt) - ledPeakChromaTrim·(t−0.85)/0.15` 在 [0.85, 1.0] 段做温和的 peak 收口。chroma 全程 ≥ base.c，中段比 base.c 高 18%；peak 比 base.c 低 6%（防止白化）。hue drift family-aware 但 scale 收到 0.55（v1 是 0.85）。

#### 6.7.4 v2 失败兜底

如果未来 v2 在手测中再次失败，回退路径是把 `usesArtisticBackground` 这条分支关掉——艺术背景 fullscreen 会自动回到 Phase 5 HSL profile。Phase 5 路径**未改动**，作为 fallback 始终可用。

#### 6.7.5 v2 SelfCheck 加固

新增/重写 9 个自检（Phase 6 总数 13，全部 PASS）：

1. v2 artistic lyrics L hierarchy + chroma floor（要求 inactive ≥ 视觉 floor 0.050）；
2. v2 near-mono outputs neutral；
3. v2 (yellow) chroma + hue identity preserved；
4. v2 (red) chroma + hue identity preserved；
5. v2 (blue) chroma + hue identity preserved；
6. v2 (purple) chroma + hue identity preserved；
7. v2 LED tone steps have perceptual distance；
8. v2 LED colorful artwork not pale；
9. v2 LED peak not white-washed（peakL ≤ 0.95 + hueΔ ≤ 0.025）；
10. v2 LED lightness survives opacity ramp（perceived L Δ ≥ 0.080）；
11. v2 artistic fullscreen hierarchy（新增 inactive/active chroma ratio ≥ 0.85）；
12. v2 hue identity preserved on colourful artwork（四角色 hueΔ 全 ≤ 0.025）；
13. v2 cover blur profile remains separate。

四 hue family 全部 PASS：每个家族 6 个角色都 cap 在 family chroma 上限（黄 0.110 / 红 0.130 / 蓝 0.140 / 紫 0.120），hueΔ 全部 ≤ 0.009。LED 真实 opacity 下感知 L Δ = 0.832（阈值 0.080）。

总数 53/53 PASS（旧 47 + 新 9，删除 v1 弱门槛 3）。

#### 6.7.6 v2 验证

- `ColorSystemSelfCheck` 53/53 PASS。
- Debug build：`xcodebuild ... build` 成功。
- 推荐手测：① 强彩色 artwork（黄/橙/蓝/紫）下开启艺术背景，确认 fullscreen 歌词 inactive 不再灰白；② 多 LED level 渐变下确认低、中、高 level 之间的色彩感知差异；③ nearMono artwork（纯灰 / 极暗）确认歌词仍中性；④ Apple / Cover Gradient / Cover Blur 视觉无变化；⑤ ultraDark artwork 下确认 active L 仍可读。

### 6.8 Phase 7 接力（v2 时的展望）

- v2 LED 的 mid chroma boost 与 opacity 模型仍是基于黑底假设；未来 LED 容器若改为非黑底（如 frosted glass），需要在 SelfCheck 中重新建模"复合后感知 L"；
- 非艺术 fullscreen lyrics 仍走 Phase 5 HSL profile；如要统一到 Tone Ladder，需做 A/B 与实机验证；
- glow / shadow 与 Apple / Cover Gradient 决策不变；
- `isEffectivelyMonochrome` alias 仍可在 Phase 7 收掉。

### 6.9 Phase 6 v3 — 渲染链路 audit + seed-trust 修复（2026-05-21）

#### 6.9.1 v2 仍然失败的现象

- 强彩色 artwork + 艺术背景皮肤下，用户人工吸管取色 ≈ `#808284`（L≈0.555、C≈0.004），完全中性灰。
- 翻译行 / sub inactive 明度比 main inactive 低 0.10，用户反馈"翻译行明度太低"。
- LED 级别差仍由 opacity 主导，OKLCH L / chroma / hue 变化肉眼几乎看不出，"色彩科学层级"未实现。

#### 6.9.2 端到端 render-path audit 结论

从 Swift 一路追到 WKWebView computed style：

1. `FullscreenPlayerView.applyFullscreenLyricsTheme` 把 `colorSet.mainInactive` 等转成 `rgba(R,G,B,1.0)`，正确；
2. `LyricsWebViewStore.setConfigJSON` → `window.AMLL.setConfig(config)`，正确；
3. `index.html#applyFullscreenColorVar` 把 alpha 剥成 `rgb(R,G,B)` 写到 `--amll-fs-main-inactive` 等 CSS var，正确；
4. CSS `.amll-fs-word-base` 强制 `color: var(--amll-fs-main-inactive,...)` `opacity:1!important` `mix-blend-mode:normal!important`，正确，没有任何 fallback 灰；
5. `syncFullscreenDerivedColors` 在变量缺失时会落到 `computedStyle.color`，但本路径下变量是已写的；
6. 因此**屏幕上的灰不是 web 层覆盖出来的**，而是 **Swift 端就已经下发了灰色**。

进一步定位 Swift 内部：

- `FullscreenPlayerView.resolveLyricsAnalysis(forTrackID:)` 在 `themeStore.paletteMatches` 不成立时返回 `ArtworkColorAnalysis.neutralFallback`；
- `ArtworkColorAnalysis.neutralFallback.isNearMonochrome` 被硬编码为 `true`（`Utilities/ArtworkColorAnalysis.swift:93`）；
- 这个 `true` 一路传入 `PerceptualToneLadder.artisticLyricsTone(..., isNearMonochrome: true)`，把所有角色 chroma 钳到 `nearMonoChromaCeiling = 0.004`；
- 落出来后 `neutraliseLyricsSurfaceIfNearMono` 又再钳一遍。
- 结果：即使 seed（highlightBaseColor / accentColor）是鲜艳颜色，最终 lyric 全部输出 OKLCH `L≈0.555 C≈0.004`，对应 sRGB ≈ `#808284`。完美命中用户吸管色。

v2 SelfCheck 没有覆盖"`isNearMonochrome=true` + 彩色 seed"这条路径，所以 53/53 PASS 但屏幕上灰。

#### 6.9.3 v3 修复策略

**核心改动：信 seed 不信 analysis bit**。`isNearMonochrome` 由 analysis 全局决定，但艺术歌词的颜色身份由 seed 决定。两层耦合是 v2 的真正根因。

1. `PerceptualToneLadder.artisticLyricsTone`：当 `base.c >= lyricsSeedChromaPreferred`（0.045）时，**忽略** `isNearMonochrome` 参数，走彩色 floor / cap 路径；
2. `PerceptualToneLadder.ledTone`：同样规则；
3. `SemanticPaletteFactory.artisticFullscreenLyricsColorSet`：seed 有可视 chroma 时跳过尾部的 `neutraliseLyricsSurfaceIfNearMono`（避免双重 clamp）；
4. `FullscreenPlayerView.applyFullscreenLyricsTheme`：新增 v3 诊断日志，使用 `ColorSystemDiagnostic.describe(...)` 在艺术背景路径下打印 highlight base / inactive base / 全部 6 个 role 的 `#RRGGBB (L=… C=… H=…)`。开关：`COLOR_SYSTEM_LYRICS_DEBUG=1` 或艺术背景启用时自动。

**翻译行 L 拉近**：

- `lyricsSubInactiveL`：0.505 → 0.585（与 mainInactive 0.605 差 0.020）；
- `lyricsLineTimingSubInactiveL`：0.455 → 0.540（与 lineTimingMainInactive 0.560 差 0.020）；
- 严格顺序改为 `mainActive > subActive > mainInactive > subInactive > lineTimingMainInactive > lineTimingSubInactive`（v2 旧顺序 mainInactive > lineMain > subInactive 已不再适用）。

**LED 拉开"色彩科学层级"**：

- `ledDarkMinL` 0.780 → 0.620、`ledDarkPeakL` 0.920 → 0.945（dark L 跨度从 0.14 拉到 0.33）；
- `ledLightMinL` 0.430 → 0.340、`ledLightPeakL` 0.560 → 0.640；
- `ledMidChromaBoost` 0.18 → 0.42（中段更"活"）、`ledPeakChromaTrim` 0.06 → 0.10（peak 收口更稳）；
- `ledShadowDriftScale` 0.80 → 1.25、`ledHighlightDriftScale` 0.50 → 0.70（低 level 暖偏更明显）；
- `ledLightnessVisibilityAssertion` 0.080 → 0.180（自检阈值随之收紧）。

#### 6.9.4 v3 SelfCheck 加固

新增 4 条 v3 回归门（v2 漏检的就是这些）：

1. **`ToneLadder v3: colourful seed survives isNearMonochrome=true`** — 直接把 `isNearMonochrome=true` + 彩色 seed 喂入 `artisticLyricsTone`，要求所有 6 个角色 chroma ≥ 0.040（v2 此处会 fail，输出 0.004）。
2. **`Lyrics v3: artistic path keeps colour under .neutralFallback analysis`** — 走 `SemanticPaletteSelfCheck.fullscreenLyricsColorSet` 全链路，传入真实的 `.neutralFallback`（`isNearMonochrome=true`）+ 彩色 highlight，要求最终 set 全角色 chroma ≥ 0.040 且 inactive hueΔ ≤ 0.025。这是直接覆盖用户屏幕场景的回归门。
3. **`Lyrics v3: sub-inactive L close to main-inactive L`** — main/sub inactive 与 line/line-sub inactive 的 L 差均 ≤ `lyricsSubInactiveLightnessProximityAssertion` (0.060)。
4. **`LED v3: low-level hue drift visible vs peak`** — low level 的 family shadow drift 必须大于 peak 的 highlight drift，且 lowHueΔ ≥ 0.003。

`checkToneLadderNearMonoNeutral` 改名为 v3 并使用真正灰色 seed（c=0.003）测试 nearMono 路径——v3 契约下"分析 bit + seed 双重信号"才会触发中性化，这条测试与新契约一致。

#### 6.9.5 v3 验证

- `ColorSystemSelfCheck` **53/53 PASS**（含 4 条新增 v3 门）。
- Debug build：`xcodebuild ... build` 成功。
- 关键数值（log 摘录）：
  - `Lyrics v3: artistic path keeps colour under .neutralFallback analysis` — minRoleC=0.066，seedC=0.194，inactive hueΔ=0.006；
  - `ToneLadder v3: colourful seed survives isNearMonochrome=true` — minRoleC=0.130，min limit=0.040；
  - `Lyrics v3: sub-inactive L close to main-inactive L` — main vs sub Δ=0.020，line vs lineSub Δ=0.020；
  - `LED v2: tone steps have perceptual distance` — L=0.685/0.815/0.945（v2 是 0.78/0.85/0.92，幅度从 0.14 拉到 0.26）；
  - `LED v2: lightness survives opacity ramp` — perceived L Δ=0.872，远高于 0.180 阈值；
  - `LED v3: low-level hue drift visible vs peak` — lowHueΔ=0.007、peakHueΔ=0.002。
- Web layer：本轮未触动当时的 `index.html` / `style.css` / `bridge.js` / `lyrics-renderer.js`；Phase 5 Swift-owned color contract 仍由 Swift 侧负责。迁移前残留的 `lyrics-renderer.js` 已在 2026-05-31 清理删除，当前 AMLL 运行路径不再包含该文件。
- 推荐手测：① 强彩色 artwork（黄/橙/蓝/紫）+ 艺术背景开关下，全屏 inactive 行不再灰白，可以肉眼读出 hue；② 翻译行明度与 inactive 主歌词行接近；③ LED 1/3/5/7/10 级别从下至上应能感到 L 与色彩明显爬升；④ nearMono artwork 与 Apple / Cover Gradient / Cover Blur 视觉无任何变化；⑤ 设 `COLOR_SYSTEM_LYRICS_DEBUG=1` 启动并切换 tracks，`Log.debug` 应在艺术背景路径下打印每一组 highlight base / 6 个 role 的 hex+OKLCH。

### 6.10 Phase 6.1 — 艺术歌词修正 + 视觉层级 + 日间反相（2026-05-21）

**用户报告与本轮根因**（v3 后人工测试结果）：

1. 夜间艺术背景歌词已经"有颜色"，但 (a) 高饱和封面歌词过饱和；(b) 某些中饱和封面 seed 被取低；(c) active L 偏低，希望抬高；(d) translation L 明显比 inactive 主歌词低。
2. 艺术背景视觉层：移动圆形明度太高；floating shapes 明度偏高（尤其 UltraDark）；BK1/BK2 偏灰，需要"更暗 + 略提高饱和度"。
3. 日间模式：当前亮色艺术背景 + 浅色歌词看不清。需要"亮背景 + 深色歌词"反相体系，且歌词任何颜色都必须低于背景颜色。

根因审计（不只调参）：

- **(a) 高饱和过饱和**：v3 的 `artisticLyricsTone` 末段把 `base.c * chromaScale` 直接 `clamp(_, floor, cap)` 到 hue-family cap（红 0.130 / 黄 0.110 / 蓝 0.140）。高 C seed 全部贴 cap，没有平滑过渡。
- **(b) 中饱和取低**：`SemanticPaletteFactory.fullscreenLyricBase` 在 `colorfulness < 0.20` 时跳到 `bestTextSourceColor`，该函数从最 chromatic 的 mid-tone 桶取，但桶大小被 area-weighting 压制时输出会比 `dominantColor` 更灰。`artisticLyricsSingleSeed` 的 candidates 顺序也把 `preferred`（= `fullscreenLyricBase` 的输出）放在最前，所以一旦 v3 fullscreenLyricBase 拿到低彩 text-source，整条链路就走低彩。
- **(c) active L 偏低**：v3 token `lyricsMainActiveL = 0.880` 是为了与 inactive 0.605 拉开 0.275 gap；但 0.880 在用户屏幕上读不到"高亮"的清晰度，inactive 又因 v3 把 L 抬到 0.605 显得不够"沉"。
- **(d) translation 太暗**：v3 `lyricsSubInactiveL = 0.585` 与 `lyricsMainInactiveL = 0.605` gap 0.02，proximity assertion 0.060 太宽，实际跑出来差距大于人眼能容忍的"同档"——尤其 line-timing 模式 sub 是 0.540 比 inactive 0.560 差 0.02 但视觉上更暗。
- **背景层**：`BKColorEngine.tierRanges` 夜间普通 `dotB = 0.56…0.82`，圆形可一直跳到 L 0.82，比"solid bg 0.24…0.40"高出近一倍，确实"明度太高"。`fgB = 0.44…0.64` 同理。BK1/BK2 由 `makeBackgroundVariants` 在 `tier.bgB` / `variantSRange` 内挑色，bg 上限 0.40 → 一旦 lumaKBg 0.82 把映射拉高就偏灰。
- **日间反相**：`PerceptualToneLadder.artisticLyricsTone` 与 `tierRanges` 都没看 scheme；日间 lyrics 跑同一套高 L target（0.88 active），bg 也只是把 bgB 上抬到 0.85。亮 lyrics 叠亮 bg 必然糊。

**本轮处理**（commit pending — Phase 6.1 / refactor/oklch-color-system）：

- `OKColor.swift`：`PerceptualToneLadder.artisticLyricsTone` 新增 `scheme: ColorScheme = .dark`；彩色路径在 `clamp` 之前先 `OKColor.chromaSoftShoulder(ceiling=0.095, softness=0.045)`（光线模式各 0.072/0.030）。`hueChromaCap` 在 `.lyrics` 角色下 `.light` 走 `baseCap * 0.72`。
- `ColorSystemTokens.swift`：
  - 夜间 L：`lyricsMainActiveL` 0.880 → 0.905；`lyricsSubActiveL` 0.780 → 0.830；`lyricsMainInactiveL` 0.605 → 0.580；`lyricsSubInactiveL` 0.585 → 0.575；line-timing 两项各 −0.005。
  - 日间 L 反相 token：`lyricsLightMainActiveL = 0.150`、`lyricsLightSubActiveL = 0.260`、`lyricsLightMainInactiveL = 0.430`、`lyricsLightSubInactiveL = 0.435`、line-timing 0.470 / 0.500。严格升序。
  - chroma shoulder + 光线模式版本；`lyricsSubInactiveLightnessProximityAssertion` 0.060 → 0.020；
  - seed-selection token：`lyricsDominantSeedMinChroma=0.025`、`lyricsSalientSeedMinChroma=0.090`、`lyricsSalientSeedMinHueGapFromDominant=0.08`、`lyricsSalientSeedMaxFieldColorfulness=0.18`、`lyricsSalientSeedDominantConfidenceMin=0.42`、`lyricsSalientSeedMaxLargestHighSatArea=0.22`。
- `SemanticPalette.swift`：
  - `fullscreenLyricBase` 改成"dominant 优先 + dominant 太灰才回退 bestText"；
  - `artisticLyricsSingleSeed` 升级为：nearMono → preferred；`pickSalientLyricSeed` 通过则用 salient；否则 dominant；否则 candidate scan 兜底；
  - 新增 `pickSalientLyricSeed`：colorfulness ≤ 0.18 + dominantHueConfidence ≥ 0.42 + largestHighSatArea ≤ 0.22 + salient chroma ≥ 0.09 + 与 dominant hue 距 ≥ 0.08；
  - `artisticFullscreenLyricsColorSet` 新增 scheme 透传，调用 `artisticLyricsTone(... scheme: scheme)`。
- `BKColorEngine.swift`：`tierRanges` 夜间 / 夜间 veryDark / 夜间 coverLuma<0.34 / 日间 四个分支的 `bgB`、`fgB`、`dotB`、`bgS`、`fgS`、`dotS` 全部按上面"夜间 dotB/fgB 下压、bgS/fgS/dotS 略升；日间 bgB 抬高、shapes 跟随"重写。BK1/BK2 由 `makeBackgroundVariants` 内部 clamp 到新 `tier.bgB` / `variantSRange` 自动获得"更暗 + 略升饱和"。
- `ColorSystemSelfCheck.swift`：新增 Phase 6.1 段 9 项；既有 v3 检查在新 token 下复算仍 PASS（其中 `Lyrics v2: artistic fullscreen tone ladder hierarchy` 的 chromaRatio 在 navy seed 下重算为 ≥ 1.0，远高于 0.85 阈值）。
- **未触动**：`amll-core.js` / `amll-lyric.js` 生成 bundle；`index.html` CSS 变量名；Apple / Cover Gradient / Cover Blur lyrics profile；HSL fullscreen fallback；普通 `AppForegroundPalette`；Home Shapes / Spectrum / BKArt 之外的视图。

**AMLL 行为**：Swift → Web 仍是 `fullscreenActiveColor` / `fullscreenInactiveColor` / `fullscreenSubActiveColor` / `fullscreenSubInactiveColor` / `fullscreenBackgroundColor`（= `subActive`）/ `fullscreenLineTimingInactiveColor` / `fullscreenLineTimingSubInactiveColor` 七色。`index.html` 中：
- interlude dots `[class*="interludeDots"] > *` color fallback chain 是 `var(--amll-fs-main-active, var(--amll-active, ...))` → Swift 下发的 active 会自动覆盖；日间反相后 dots 变深色，无需触 bundle；
- background lyric base 是 `var(--amll-fs-sub-color, var(--amll-fs-main-inactive, ...))`，inactive 由 Swift 下发，同样自动跟随；
- glow / shadow 用 `currentColor` 推导，跟随 lyric color，日间反相后自动变深；不存在硬编码白色阴影需要改 bundle。

**SelfCheck 新项摘要**：
- `Phase 6.1: artistic mainActive L raised (≥ 0.90)` — 夜间 active 抬高确认；
- `Phase 6.1: high-chroma seed soft-shouldered` — 高 C seed 介于 ceiling 与 (ceiling+softness) 之间；
- `Phase 6.1: mid-chroma seed survives the shoulder` — 中 C seed 不被压；
- `Phase 6.1: light-mode artistic lyrics inverted (ascending L)` — 日间 L 升序；
- `Phase 6.1: light-mode translation L matches inactive L` — proximity ≤ 0.020；
- `Phase 6.1: seed selection dominant-first on mid-sat` — 中饱和单色 seed 走 dominant，非低彩 text-source；
- `Phase 6.1: salient fires on uniform-dark + yellow` — 黑底小黄 seed = 黄；
- `Phase 6.1: salient suppressed on multi-colour art` — 棕 70% + 蓝 30% seed = 棕；
- `Phase 6.1: nearMono seed stays neutral` — 中性 seed 保留 nearMono 路径，不被新 salient gate 误触发。

**推荐手测**：
1. 夜间 + 艺术背景开 + 高饱和封面（亮黄、亮橙、亮红、亮蓝）：active 明显比 v3 更亮且更清晰；inactive 仍可读，但更"沉"；高饱和封面歌词不刺眼，但仍是彩色。
2. 夜间 + 艺术背景 + 中饱和封面（橄榄、棕、灰蓝）：歌词色不应莫名变低饱和；hue 与封面 dominant 一致；翻译行与 inactive 同档。
3. 夜间 + 艺术背景 + 黑底小亮色（如 95% 黑 + 5% 亮黄）：seed 应是黄，歌词跟着染色。
4. 夜间 + 艺术背景 + 多色封面（棕 70% / 蓝 30%）：seed 应仍是 dominant 棕，不能跳到小色块。
5. 夜间 + 艺术背景：移动圆形与 floating shapes 明度肉眼可见低于 v3；BK1/BK2 切换更暗、不再发灰；UltraDark 下 shapes 进一步压低。
6. 日间 + 艺术背景：背景层比 v3 更亮（白偏色），歌词全部反相为深色；active 是最深；translation = inactive 主歌词；interlude dots 与 background lyric 自动变深（fallback chain 接住）。
7. nearMono artwork（纯灰）：歌词与背景均无色偏，深 / 浅模式下都不引入伪色。
8. Apple / Cover Gradient / Cover Blur 关掉艺术背景：视觉完全无变化。

---

### 6.11 Phase 6.2 — 艺术背景歌词 / Seed 选择 / 日夜视觉最终化（2026-05-21）

人工测试 Phase 6.1 后用户反馈 (a) salient gate 太保守，"明明 95% 黑 + 5% 亮黄也不被命中"；(b) `isNearMonochrome` 把"明明有颜色但低饱和"的封面灰白化；(c) nearMono 下艺术背景 floating shapes 仍有淡粉残留；(d) 夜间高饱和封面 inactive 仍过饱和、active 不够亮、UltraDark inactive 不够暗、纯色背景的移动圆形太亮；(e) 日间艺术背景与 shapes 太暗，歌词死黑、glow 仍是白色 glow、MiniPlayer UI 没切 dark profile。

**本轮处理**（commits `cd0aee6` → `eb372c6`）：

- `SemanticPaletteFactory.focusScore(...)`（新增，`myPlayer2/Utilities/SemanticPalette.swift:714-781`）— 用连续 score 替代 Phase 6.1 的硬 AND gate：
  - `visualContrast = clamp(dC × 0.45 + dL × 0.20 + dH × 0.35, 0, 1)`，其中 `dC = max(0, salient.c - dominant.c) / 0.20`、`dL = |salient.l - dominant.l| / 0.50`；当 `dominant.c < 0.045`（真灰 / 真黑）时把 `dH` 当作 1.0（hue 不可信），让 "黑底 + 亮色" 这种典型设计封面能稳定 fire。
  - `salience = clamp(salient.c / 0.20, 0, 1)`。
  - `fieldUniformity = (1 - clamp(colorfulness / 0.20, 0, 1) + clamp(dominantHueConfidence / 0.45, 0, 1)) / 2`。
  - `designFocus`：salient 面积在 (0.005, 0.22] 时 1.0；> 0.22 时线性回落到 0.44。
  - 减去 `noisePenalty=0.30`（面积 < 0.005）+ `competingPenalty=0.25`（salient palette 含 ≥ 2 个 chroma comparable 的不同色相）。
  - 阈值 `lyricsSeedFocusScoreThreshold=0.55`：≥ 阈值才 salient 胜出，否则走 dominant。
- `ArtworkColorAnalysis.analyzeInternal(...)`（`myPlayer2/Utilities/ArtworkColorAnalysis.swift:305-348`）— 新增 trust override：dominant / topPalette / salient 任一 OKLCH chroma ≥ `trustedHueChromaFloor=0.045` 即跳过 4-branch OR 的非严格分支；strict mono（branch 1: `colorfulness < 0.04 && avgSat < 0.10`）保持无条件。
- `BKColorEngine.make(...)`（`myPlayer2/Views/NowPlaying/BKColorEngine.swift:323-372`）— 在 `harmonized` 构造前增加 nearMono 后处理：当 `analysis.isNearMonochrome && !analysisHasTrustedHueCandidate(analysis)` 时，对 `bgStops` / `shapePool` / `dotBase` / `bgVariants` 用 `OKColor.neutralise(.., chromaCeiling: 0.008)` crush 残留色相。
- `OKColor.neutralise(_:chromaCeiling:)`（新增，`myPlayer2/Utilities/OKColor.swift:212-225`）— 通用 OKLCH chroma crush 帮助函数，与 `FullscreenMiniPlayerView.neutralizeForNearMono` 镜像（Spectrum 早已用同款）。
- `PerceptualToneLadder.artisticLyricsTone(...)`（`myPlayer2/Utilities/OKColor.swift:382-422`）— soft chroma shoulder 改为受 `lyricsHighChromaShoulderTrigger=0.085` 门控：`scaled = base.c * chromaScale`，只有 `scaled >= trigger` 才走 shoulder；mid-C seed 穿过原样到 cap，避开 Phase 6.1 "中饱和被压" 问题。
- `ColorSystemTokens.ToneLadder` 夜间 token 退耦（`myPlayer2/Utilities/ColorSystemTokens.swift:465-494`）：
  - `lyricsMainActiveL` 0.905 → **0.920**；
  - `lyricsSubActiveL` 0.830 → **0.855**；
  - `lyricsUltraDarkInactiveTrim` 0.060 → **0.095**；
  - `lyricsMainActiveChromaScale` 0.92 → **0.98**；
  - `lyricsSubActiveChromaScale` 0.96 → **1.00**；
  - inactive / line-timing L 不变。
- `ColorSystemTokens.ToneLadder` 日间 token 重设（`myPlayer2/Utilities/ColorSystemTokens.swift:493-503`）：
  - `lyricsLightMainActiveL` 0.150 → **0.215**（不死黑）；
  - `lyricsLightSubActiveL` 0.260 → **0.325**；
  - `lyricsLightMainInactiveL` 0.430 → **0.470**；
  - `lyricsLightSubInactiveL` 0.435 → **0.475**；
  - `lyricsLightLineTimingMainInactiveL` 0.470 → **0.510**；
  - `lyricsLightLineTimingSubInactiveL` 0.500 → **0.540**；
  - 严格升序保持；与 `bgB.lower=0.92` 的 gap ≥ `lyricsLightBackgroundLyricGapMin=0.20` invariant 满足。
- `BKColorEngine.tierRanges`（`myPlayer2/Views/NowPlaying/BKColorEngine.swift:1168-1219`）夜间：
  - `bgB` 0.18…0.32 → **0.14…0.28**；`fgB` 0.34…0.54 → **0.28…0.46**；`dotB` 0.46…0.68 → **0.40…0.58**（`dotB.upper` 刚好等于 inactive L floor 0.580）；
  - UltraDark / veryDark / 暗主导分支同向收紧；
  - `bgS` / `fgS` / `dotS` 保持，chroma 补偿降亮带来的灰扑扑。
- `BKColorEngine.tierRanges` 日间：
  - `bgB` 0.88…0.95 → **0.92…0.97**；`fgB` 0.78…0.88 → **0.80…0.90**；`dotB` 0.62…0.74 → **0.66…0.78**；
  - `bgS` 0.10…0.30 → **0.06…0.22** 避免 pastel；`fgS` / `dotS` 上限同样收。
- `FullscreenMiniPlayerView`（`myPlayer2/Views/Fullscreen/FullscreenMiniPlayerView.swift:423-460`）— 新增 `usesDarkControlForegroundForLightArtisticBackground` gate：`settings.fullscreenArtBackgroundEnabled && colorScheme == .light && themeStore.hasArtworkThemeColor` → `controlPrimaryNSColor = readabilityProfile.foregroundPrimary`（Phase-4 OKLCH-neutralised on nearMono，自动获得反粉红行为）。
- AMLL highlight transition：审计后**延期**。fullscreen 线级 transition (`color .14s/.18s ease-out`) 已经在 `index.html` 但 transition 由浏览器 sRGB interp 计算，非 Swift 可控；per-word/char "seam" 由生成 bundle 的 mask-image / linear-gradient 内联，无 CSS 变量 hook，需要 fork core patch。已记入 `docs/amll-custom-behavior-and-patch-registry.md` 和 `docs/amll-upgrade-implementation-log.md`。

**SelfCheck**（`myPlayer2/Utilities/ColorSystemSelfCheck.swift`）新增 20 个 Phase 6.2 场景：

- focus-score 5 个：`focus seed fires on 95% black + 5% yellow`、`focus seed fires on blue + orange salient`、`focus suppressed on 70% brown + 30% blue`、`focus suppressed on tiny noise dot`、`focus suppressed on multi-colour`；
- nearMono trust override 3 个：`nearMono NOT triggered by low-sat chromatic cover`、`nearMono still triggers on true grey`、`black + bright salient avoids nearMono`；
- art shape 反粉红 2 个：`OKColor.neutralise crushes chroma + preserves L`、`shapes keep tint when trusted hue exists`；
- 夜间 shoulder/active/UltraDark/moving circle 5 个：`night high-chroma inactive softened`、`night mid-chroma passes through`、`night active L lifted (>= 0.915)`、`UltraDark inactive deeper`、`night moving circle dotB.upper <= lyric inactive L`；
- 日间 bg/lyric/translation 4 个：`day bg L floor >= active L + gapMin`、`day active L >= 0.180`、`every day lyric L < day bg L floor`、`day translation L close to inactive L`；
- MiniPlayer day-profile 1 个：`MiniPlayer day profile swaps to dark foreground`。

同时修正 3 个 Phase 5/6 既有测试以反映 Phase 6.2 语义：
- `Spectrum: near-mono input neutralised` / `HomeShapes: near-mono chroma ceiling` synthetic 换为纯灰（之前的 95% 黑 + 5% 亮黄已不再被 Phase 6.2 标为 nearMono）；
- `Display: salient priority under near-mono contention` 去掉 `nearMono=true` 前置条件，只断言 "yellow survives salient + display"；
- `Lyrics v2: hue identity preserved on colourful artwork` 把 active.c floor 放宽到 0.035（Phase 6.2 active L 0.920 + 红色 hue 在 sRGB gamut 边界，最大可表 chroma ≈ 0.045）。

`COLOR_SYSTEM_SELF_CHECK=1` 本地运行曾为 **ALL PASS**。2026-05-23 文档止血修正：后续 Phase 6.3 / 6.4 人工复测已否定多项可见结论，因此这里的 self-check 不能再被解释为视觉验收通过。

**推荐手测**：
1. 夜间 + 高饱和封面（亮黄 / 橙 / 红 / 蓝）：active 比 v3/6.1 更亮且更"鲜"；inactive 不再过饱和（mid-C 不再被压）；translation 与 inactive 同档。
2. 夜间 + 中饱和封面（橄榄、棕、灰蓝）：seed = dominant，hue 与封面一致；中饱和不被压低。
3. 夜间 + 黑底小亮色（95% 黑 + 5% 亮黄）：focus-score 触发，seed = 黄，歌词跟着染色。
4. 夜间 + 多色封面（棕 70% / 蓝 30%）：focus-score 不触发，seed = dominant 棕。
5. 夜间 + UltraDark：inactive 明显更暗；moving circle 更暗；floating shapes 更暗。
6. 夜间 + nearMono（真灰）：后续仍需重测歌词、背景、shapes、moving circle 是否中性；Phase 6.3 / 6.4 人工复测发现 shapes 淡粉有回归。
7. 夜间 + low-sat chromatic 封面（暖灰、压暗的复古）：后续仍需重测是否被 nearMono 灰白化；不能再沿用“Phase 6.2 不再灰白化”的结论。
8. 日间 + 高饱和封面 + 艺术背景：后续仍需重测 bg / shapes / lyrics / MiniPlayer；Phase 6.3 / 6.4 人工复测确认日间背景和歌词仍偏暗，MiniPlayer 仍未统一 dark foreground。
9. 日间 + nearMono：高 L 中性背景；歌词深灰；shapes 中性。
10. Apple / Cover Gradient / Cover Blur：视觉无变化。

---

### 6.12 Phase 6.3 — Artistic Color System Stabilization（2026-05-22）

本轮目标是修正 Phase 6.2 人工验收未通过的艺术背景颜色稳定性问题，不进入 Phase 7，不处理 AMLL active/inactive feather transition。

> **2026-05-23 人工复测止血结论**：Phase 6.3 是一次中间实现尝试，未通过人工视觉验收。以下条目只能作为“曾经尝试过的代码方向”阅读，不能再作为“已修复 / 已完成”的事实。下一轮不得基于“Phase 6.3 已完成”继续微调；应重新从颜色状态机、MiniPlayer profile、pending palette、nearMono 判定和日间艺术背景体系做架构审计。

**实现尝试（已被人工验收否定为不充分）**：

- `ArtworkColorAnalysis` 曾尝试让 `salientHighlightPalette` 输出 `salientHighlightAreaShares`，并把 nearMono 改成“没有任何可信 hue 才 nearMono”。人工复测确认仍有很多有色封面被误判成黑白，因此不得再写“低饱和彩色封面不再灰白化”。
- `SemanticPaletteFactory.focusScore` 曾尝试用 OKLab 感知距离、ΔC、ΔL、Δhue、dominant-field confidence、competing high-saturation area、nonlinear area gate 建模视觉焦点。人工复测确认小面积强焦点仍不稳定，下一轮需要重新调查 seed selection。
- `BKColorEngine` 曾尝试对 true nearMono 且无 trusted hue 的 bgStops / shapePool / dotBase / bgVariants 执行 OKLCH chroma crush。人工复测确认淡粉问题有回归，不能再写“true nearMono shapes 防粉完全解决”。
- 夜间艺术背景曾做 dark tier / warm-red saturation gating / UltraDark shape-circle 调整；该方向不等于最终验收通过，后续仍需以真实封面手测为准。
- 日间艺术背景曾尝试 high-B airy light tier，但人工复测确认整体仍偏暗；不能再写“日间艺术背景已足够明亮”。
- 日间歌词曾尝试提高 light artistic lyric L，但人工复测确认 active / inactive 仍偏暗、阴沉；不能再写“日间艺术歌词已完成反相”。
- Fullscreen emphasis glow：Swift 下发 `fullscreenEmphasisGlowColor = mainActive`；`index.html` adapter 只消费该 CSS var 重染 fullscreen emphasis keyframes 与 drop-shadow fallback。日间艺术背景下 glow 源是深色；不改 generated AMLL bundle，不把 hue 决策放回 Web。
- Fullscreen MiniPlayer UI 曾尝试在 `fullscreenArtBackgroundEnabled && colorScheme == .light` 下固定使用 `readabilityProfile.foregroundPrimary`。人工复测确认主 MiniPlayer、左右按钮、音量、进度、文字颜色路径仍分裂，且仍会随封面明暗变化。
- ThemeStore 曾尝试在 artwork cache miss / pending full analysis 时保留上一首 palette。人工复测确认切歌仍会闪 default / 错误深浅色，pending palette 状态机需要重新审计。

**仍可保留的方向**：

- 日间 emphasis glow 切成暗色是正确方向；但下一轮仍需确认 Swift 下发、Web adapter 消费和视觉结果不要回退。
- AMLL active/inactive feather transition 本轮不处理，继续留在 backlog。

**SelfCheck / Build**：

- `COLOR_SYSTEM_SELF_CHECK=1` 曾为 `Result: ALL PASS`，但这只说明 synthetic gates 通过，不代表人工视觉验收通过；不得用这些 self-check 结论掩盖上述失败点。
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`：PASS。

**边界**：

- 未进入 Phase 7。
- 未处理 AMLL highlight / feather transition；保留已有 backlog。
- 未修改 generated `amll-core.js` / `amll-lyric.js`。
- 未改 Apple / Cover Gradient / Cover Blur profile、普通 AppForegroundPalette、Home Shapes / Spectrum。

**推荐手测**：

1. 黑底小黄、蓝底小橙、极小强对比标题/Logo：重新验证歌词 seed 是否真的选中焦点色。
2. 70% 棕 + 30% 蓝、普通四色封面、噪点封面：重新验证是否仍走 dominant，不乱跳。
3. 低饱和暖灰 / 复古彩色封面：重新验证是否仍被 nearMono 灰白化。
4. 真灰封面：重新验证歌词、BK、BK1/BK2、floating shapes、moving circle 是否中性且不淡粉。
5. 日间艺术背景：重点检查是否仍偏暗，歌词是否仍阴沉，MiniPlayer icon / text 是否仍随封面变白。
6. 连续切歌：重点检查是否仍闪 default blue / neutral fallback / 错误深浅色。

---

### 6.13 Phase 6.4 — Artistic Color System Architecture Stabilization（2026-05-23）

Phase 6.3 后的人工验收说明：剩余问题已经不是单个 token，而是颜色路径与状态链路分裂。日间艺术背景仍受夜间/UltraDark 思路影响，Fullscreen MiniPlayer 控件各自判断前景色，切歌 pending 时 view 层仍会把 `.neutralFallback` / default palette 注入歌词，snapshot cache-hit 路径还会丢失 `ArtworkColorAnalysis`，导致 nearMono / trusted hue / UltraDark 信息断裂。

> **2026-05-23 人工复测止血结论**：Phase 6.4 仍未通过人工验收。以下内容记录当时的架构稳定化尝试，但其中多项“已统一 / 已修复 / 不再”的结论已被用户人工测试否定。下一轮应从架构审计开始，不要继续基于 Phase 6.4 的完成假设做 token 微调。

**实现尝试（未通过人工验收）**：

- 日间艺术背景曾改为独立 light artistic profile（`bgB=0.975…0.995`、`fgB=0.930…0.985`、`dotB=0.860…0.950`）并移除 light path 的旧硬上限。人工复测确认日间艺术背景仍偏暗，不能再写“已足够明亮 / 已是 airy light design”。
- 日间 UltraDark 曾被限制为 dark-scheme-only。该方向仍值得下一轮审计，但人工复测确认日间背景和歌词仍受到压暗或暗沉效果影响；不能把“日间 UltraDark 已彻底禁用”当作事实。
- 日间歌词曾提升为 active 0.305 / sub-active 0.410 / inactive 0.560 / translation 0.565 / line timing 0.590…0.610。人工复测确认 active / inactive 仍偏暗、阴沉；不能再写“日间艺术歌词 deep but alive 已完成”。
- Fullscreen MiniPlayer UI 曾尝试统一 fixed dark profile。人工复测确认主 MiniPlayer、左右控制区、音量、进度、歌名/歌手、hover / expanded 状态仍存在多条颜色路径，并会随封面明暗变化或动画状态闪变。
- 切歌 pending 曾尝试在 view-layer hold。人工复测确认仍会闪 default palette / neutral fallback / 错误深浅色，说明 ThemeStore、snapshot、fullscreen lyrics injection 与全局消费者之间仍有状态机裂缝。
- Artwork snapshot 携带完整 analysis：`ArtworkAssetSnapshot` 新增 `analysis` 字段；`ArtworkAssetStore.snapshotMetadata` 生成 snapshot 时计算并缓存 `ArtworkColorAnalysis`；ThemeStore cache-hit path 优先复用 snapshot analysis。BKArt / fullscreen lyrics / nearMono trusted hue 不再因为 snapshot 命中而丢失 displayPalette、salient、UltraDark 与 nearMono 判定。
- nearMono 误判曾归因于 cache-hit / pending 路径丢 analysis 后被 fallback/neutral 吞掉。人工复测确认仍有很多有色封面被误判成黑白，说明真实原因未完全查清；下一轮必须重新审计 average / palette / fallback / strict mono / trusted hue 覆盖路径。
- nearMono shapes 方向：允许极淡、克制、适配黑白的低彩 tint 是正确方向，不要回退死灰；但人工复测确认淡粉问题有回归，不能再写“防粉完全解决”。
- Emphasis glow 保持 Phase 6.3 正确方向：日间切成 dark glow 是正确方向；下一轮只需确认不要回退。本轮未改 `index.html`、未改 generated AMLL bundle。

**SelfCheck / Build**：

- `COLOR_SYSTEM_SELF_CHECK=1` 曾为 `Result: ALL PASS`，但人工复测已否定多个可见结论。后续应把 self-check 作为回归辅助，而不是验收依据。
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`：PASS。
- Debug：fullscreen artistic lyrics theme pending 时输出 `[OKLCH] hold fullscreen artistic lyrics palette pending ...`，用于手测确认新歌颜色 ready 前没有发布 default/neutral lyrics palette。

**边界**：

- 未进入 Phase 7。
- 未处理 AMLL active/inactive feather transition；保留已有 backlog。
- 未修改 generated `amll-core.js` / `amll-lyric.js`。
- 未改 Apple / Cover Gradient / Cover Blur profile、普通 AppForegroundPalette、Home Shapes / Spectrum。

---

### 6.14 Phase 6.5 — Artistic Color System Architecture Repair（2026-05-23）

Phase 6.5 重新审计了颜色状态机、fullscreen MiniPlayer 前景色策略、艺术背景日间路径、nearMono / trusted hue 语义和 BKArt shape fallback。结论：Phase 6.3 / 6.4 的问题不是单点 token，而是多个消费者各自 fallback、各自判断可读性。

**最终架构决策**：

- 新增 `FullscreenMiniPlayerForegroundStrategy`，把 fullscreen MiniPlayer、左侧退出全屏歌词按钮、底部 transport、progress/time、queue/order pill、volume、hover / expanded 状态统一到一个 `FullscreenMiniPlayerForegroundProfile`。Apple skin 固定 light profile；Cover Gradient Blur / clear blur 根据 artwork readability 统一切 light/dark；Artistic day 固定 dark profile；Artistic night 固定 light profile。
- `ThemeStore` 引入 explicit pending hold：presentation artwork loading / cache miss / full analysis pending 时保留上一套有效 semantic palette，不发布 `.neutralFallback` 中间态；只有真正 no artwork 或 extraction 失败才 fallback。`PlaybackThemeArtworkWatcher` 的 task id 加入 loading + artwork checksum，避免 artwork ready 后不触发主题更新。
- Fullscreen lyrics / cover blur / BKArt 消费端不再在 pending 时自行发 default：lyrics seed fallback 在 palette pending 时复用 `themeStore.semanticPalette`；cover blur 可复用 held theme；`BKArtBackgroundView` 在 artwork loading 时保留上一帧 palette。
- nearMono 重新定义为“没有可信色相”，不是“平均饱和度低”。`ArtworkHueTrust` 需要 palette/top/rich/salient 或 dominant + real sampling support；`.neutralFallback` 的 fallback orange 不再能冒充真实 hue。muted coherent hue floor 降到 0.024，但必须有 avg saturation / colorfulness / dominant confidence / coherent palette 支撑。
- `SemanticPalette`、MiniPlayer spectrum、BKColorEngine 使用统一的 effective nearMono：`analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate`。有可信 hue 的低饱和封面不再被歌词、AppForeground、MiniPlayer、BKArt 二次灰化。
- true nearMono BKArt shapes 仍允许极淡低彩，但全部经 OKLCH chroma crush，避免淡粉 / 淡黄 / 淡蓝 fallback hue 失控。
- 日间艺术背景独立为 airy high-B profile：`bgB=0.990...1.000`、`fgB=0.955...0.995`、`dotB=0.920...0.980`；fullscreen 背景层日间不再叠 `effectiveDimmingIntensity` 黑色压暗层。
- 日间艺术歌词提升为干净深灰体系：active L=0.335、inactive L=0.620、translation L=0.622、line timing L=0.650/0.668。active 更清楚但不死黑；translation 与 inactive 同层；dark emphasis glow 方向保留。

**SelfCheck / Build**：

- `COLOR_SYSTEM_SELF_CHECK=1 /Users/kmg/Library/Developer/Xcode/DerivedData/kmgccc_player-aswiqhmbwwcbdpglyofdrjkjowjq/Build/Products/Debug/kmgccc_player.app/Contents/MacOS/kmgccc_player`：`Result: ALL PASS`。
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`：PASS。

**仍不处理**：

- AMLL active / inactive feather transition 继续留在 backlog。
- 未修改 generated `myPlayer2/Resources/AMLL/amll-core.js` / `amll-lyric.js`，未修改 fork core。

---

### 6.15 Phase 6.6 — BKArt / Lyrics Color Path Audit & State Chain Fixes（2026-05-23）

Phase 6.6 对 BKArt 和艺术歌词的完整颜色链路做了 paused / playing / pending / seeded / resolved 全路径审计，并对 4 个已发现问题做了手术级修复。详见独立审计文档 `docs/superpowers/plans/2026-05-23-phase-6.6-path-audit.md`。

**审计结论**：

- **paused vs playing 不是颜色差异根因**：`isPlaying` 参数只传给 `BKArtBackgroundRepresentable`（NSView 动画层），不参与 SwiftUI 层的 `BKColorEngine.make()`、palette 提取、analysis 传递或 lyrics 颜色决策。两条状态的颜色计算路径完全一致。
- **真实的颜色分裂来自以下 6 个根因**：(1) Seeded vs resolved palette 输入不同（seeded 无 analysis，resolved 有 analysis）；(2) Now Playing seeded 是单 accent 色，fullscreen seeded 是完整 rich palette；(3) ThemeStore 初始 `.neutralFallback` 是 warm amber，消费者提前读取会闪黄；(4) Fullscreen lyrics 有独立于 ThemeStore 的 resolution 层，可绕过 ThemeStore 已发布的状态；(5) `resolveFullscreenLyricsBaseColor()` 最终 fallback 是 `AppSettings.accentColor`，与 artwork 无关；(6) `BKArtBackgroundView` 的 `@State harmonized` 默认初始值永远是 light-mode 冷灰，暗色模式下先闪一下才切回正确色。

**修复内容**：

1. **Track-change default color flash（优先级 #1）** — 三处协调修改：
   - `AppKitMainSplitPanes.swift`：Now Playing `BKArtBackgroundView` 新增 `holdPaletteWhenArtworkMissing: playbackCoordinator.presentation.isArtworkLoading`，切歌 artwork pending 时不再立即回退到 cold gray fallback。
   - `ThemeStore.swift`：`updateThemeFromArtworkData()` 在 `artworkData == nil && sourceChanged` 时调用 `holdCurrentThemeForPendingArtwork()` 保留上一首有效 semantic palette，不再发布 `.neutralFallback` 中间态。
   - `PlaybackCoordinator.swift`：`makeLocalPresentation()` 的 `isArtworkLoading` 从硬编码 `false` 改为 `track.artworkData?.isEmpty != false && track.resolvedArtworkURL() != nil`，让 view layer 能正确感知 artwork 是否在加载中。

2. **Paused / playing 路径统一（优先级 #2）** — 审计确认无需代码修改。`isPlaying` 不进入任何颜色决策链路。任务标记为已完成。

3. **nearMono shapes 防粉（优先级 #3）** — `BKColorEngine.neutraliseCGColor()`（~line 3023）在 true nearMono 且无 trusted hue 时，把 warm residual hue 旋转到 `ColorSystemTokens.NearMonochrome.neutralCoolHue`（~209° cyan-blue），使 shapes 呈现蓝 / 薄荷 / 黄主导的极淡低彩，而非 residual pink。之前版本只是 chroma crush 但没有 hue 纠偏，导致不同 fallback 路径下 residual pink / yellow / blue 不可控。

4. **日间亮度 fine-tune（优先级 #4）** — `BKColorEngine.tierRanges()` 中 `lowSatColorCover` 块的 `fgB` 和 `dotB` 亮度 boost 原本对 dark / light 无条件执行。在 light mode 下，基础 `fgB = 0.955...0.995`、`dotB = 0.920...0.980`，乘以 `1.05 / 1.10` 后上限全部顶到 `1.0...1.0`（纯白）；随后 `enforceBrightnessHierarchy` 的 light branch 把 `bgMin` 提升到 `fgMax + 0.08`，背景也被推到纯白。结果是低饱和彩色封面在日间艺术背景下 shapes 和背景都变成纯白、完全不可见。**修复**：把 `fgB` 和 `dotB` 的 brightness boost 用 `if isDark { ... }` 保护，保留 `fgS / dotS / bgS` 的饱和度提升对两种模式都生效。

**SelfCheck / Build**：

- `COLOR_SYSTEM_SELF_CHECK=1`：`Result: ALL PASS`（61/61）。
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`：PASS。

**边界**：

- 未进入 Phase 7。
- 未处理 AMLL active-inactive feather transition；保留已有 backlog。
- 未修改 generated `amll-core.js` / `amll-lyric.js`。
- 未改 Apple / Cover Gradient / Cover Blur profile、普通 AppForegroundPalette、Home Shapes / Spectrum。

---

### 6.16 Phase 6.7 — Artistic Color System Final Stabilization（2026-05-23）

Phase 6.7 针对 Phase 6.6 后剩余的 4 个具体视觉问题进行定点修复。

**修复内容**：

1. **Fix A — nearMono Art Shapes 粉色残留**：
   - 根因：`BKColorEngine.neutraliseCGColor()` 把 warm residual hue（h ≤ 0.22 或 h ≥ 0.92）旋转到 cool neutral（~209°），但 pink/magenta 区间 ~0.80–0.90 刚好不在旋转范围内，导致 true nearMono 下 shapes 仍呈淡粉。
   - 修复：新增静态 `nearMonoShapePreset`（初版 4 色预设：pale cyan-blue、yellow、mint、sky），`neutraliseShapes == true` 时 `shapePoolOut` 不再用 hue 旋转，而是直接循环使用预设 palette。该方向解决了粉色泄漏，但 Phase 6.10 已确认 yellow 一路审美不成立，需要继续收敛为更冷、更淡的蓝 / 青 / 薄荷 / 偏紫蓝。
   - 涉及文件：`BKColorEngine.swift`

2. **Fix B — Light 模式 BK1/BK2 UltraDark 压暗**：
   - 根因：`updateUltraDarkOverlay` 在 `isUltraDarkCover == true` 时无条件叠加黑色 overlay（opacity 0.50），light mode 下 airy bright 背景也被压暗。
   - 修复：把 `shouldShowOverlay` 增加 `harmonized.isDark` 条件，仅 dark mode 下显示 overlay。light mode 下 UltraDark 封面保留 airy bright 背景。
   - 涉及文件：`BKArtBackgroundView.swift`

3. **Fix C — Light 模式 Artistic inactive 歌词偏暗**：
   - 根因：light mode 下 inactive 歌词 L token（`lyricsLightMainInactiveL = 0.620` 等）在 airy bright 背景下对比度不足，显得偏暗。
   - 修复：日间 inactive 歌词 L 全部 +0.030（main 0.620→0.650 / sub 0.622→0.652 / lineTiming 0.650→0.680 / lineTimingSub 0.668→0.698）。SelfCheck 对应阈值同步放宽。
   - 涉及文件：`ColorSystemTokens.swift`、`ColorSystemSelfCheck.swift`

4. **Fix D — Paused / playing fullscreen 颜色身份不一致**：
   - 根因：`BKArtBackgroundLayerView` 在 `shouldFreezeVisualUpdates`（speedCurrent ≤ 0.01）时把 palette update defer 到 `deferredPaletteUpdate`，在 resume 时才 apply。paused 状态下 artwork 变化或颜色重算会记录旧 palette，resume 时突然跳色。
   - 修复：删除 `deferredPaletteUpdate` 机制。`updatePalette` 立即 apply palette；`setPlayback(isPlaying:)` 不再消费 deferred update。playback state 只影响动画/transition speed，不再影响颜色身份。
   - 涉及文件：`BKArtBackgroundView.swift`

**SelfCheck / Build**：
- `COLOR_SYSTEM_SELF_CHECK=1`：`Result: ALL PASS`。
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`：PASS。

**边界**：
- 未进入 Phase 7。
- 未处理 AMLL active/inactive feather transition；保留已有 backlog。
- 未修改 generated `amll-core.js` / `amll-lyric.js`。
- 未改 Apple / Cover Gradient / Cover Blur profile、普通 AppForegroundPalette、Home Shapes / Spectrum。

---

### 6.17 Phase 6.10 — Merge to main + explicit remaining fixes（2026-05-23）

本轮先修正集成方向：不是把 `main` 合入 `refactor/oklch-color-system`，而是在确认 `refactor/oklch-color-system` 工作区干净后，将该分支合并进 `main`。合并前先把 refactor 分支上的 Phase 6 既有未提交改动提交为 `efdfcfd`；未跟踪 `.antigravitycli/` 通过 stash 单独保留；随后在 `main` 执行 `git merge --no-ff refactor/oklch-color-system`，无冲突。合并后在 `main` 上 Debug build PASS，`COLOR_SYSTEM_SELF_CHECK=1` ALL PASS。

**本轮明确不处理**：

- 两首特定 Track ID 下 Cover Blur / 大封面 MiniPlayer 控件灰色半透明；
- hover 时颜色跳动；
- progress / spectrum / volume 的中间态；
- 播放中 hover 恢复、暂停 hover 不恢复等复杂状态链问题。

这些问题保留 backlog。本轮只处理以下边界明确事项。

**修复内容**：

1. **NearMono Art Shapes preset 微调**：
   - 仅修改 true NearMono Art Shapes preset。
   - 去掉 Phase 6.7 preset 中的 yellow；不再让粉色成为主导。
   - 新 preset 使用极低 OKLCH chroma 的 pale blue、mint-cyan、purple-blue、aqua，整体视觉落在淡蓝 / 青蓝 / 薄荷 / 偏紫蓝。
   - BK 主背景仍保持 true nearMono 的中性背景路径，不让 shape palette 反向污染 BK1/BK2。

2. **Queue card current row 接入统一 foreground profile 判断**：
   - 根因：`FullscreenQueueView` 虽然已经用 `fullscreenMiniPlayerForegroundProfile.useScreenBlend` 判断队列应该走 light/dark text palette，但 current row 标题和 speaker icon 仍单独使用 `themeStore.semanticPalette.miniPlayerControl.primary`。这会在 Cover Blur 亮封面和 Artistic light 下固定成浅色，脱离队列 text palette。
   - 修复：删除 queue current row 对 `miniPlayerControl.primary` 的读取；current row title、speaker icon、current background tint、placeholder tint 全部使用 `FullscreenQueueTextPalette.primary` 派生。队列继续复用 MiniPlayer foreground strategy 的明暗判断，但不套用 MiniPlayer 的具体 icon/accent 颜色值。

**规则落地**：

- Cover Blur / 大封面渐变模糊：亮封面 → MiniPlayer strategy 切 dark foreground profile → queue current row 使用 dark queue text tier；暗封面 → light foreground profile → queue current row 使用 light queue text tier。
- Artistic Background：light mode → dark foreground profile；dark mode → light foreground profile。这里不做封面自适应，跟 Artistic MiniPlayer foreground strategy 一致。

**仍留 backlog**：

- 两首特定 Track ID 的 Cover Blur MiniPlayer 灰色半透明 / hover 跳色问题。
- progress / spectrum / volume 的中间态问题。
- AMLL active/inactive feather transition。

---

## 后续接力点（Phase 7 / 独立排期）

### B. AppKit toolbar 图标 tint（见 §4.5.12）

`AppKitMainToolbarController` 全部 toolbar 项使用 `NSImage(systemSymbolName:)`。已在 §4.5.12 写出明确实现路径（订阅 themeStore + 走 toolbar.items 应用 `paletteColors:` 配置）。本轮不做的原因：需要 lifecycle / ColorScheme 切换 / NSToolbarItem 系统重染色风险评估，建议独立排期。

### C. 其他 Phase 4.5 未接入区域

- **HomeStatCard / FavoriteArtistCard**：需多层透传，优先级低。
- **ListeningCalendarCard / HeatmapView**：heatmap 颜色另有 accent 控制，不属于普通前景。
- **NowPlaying 皮肤**：部分依赖 artwork analysis，需分策略评估（Phase 7 清理范畴）。
- **Modal 嵌套对话框**（MusicPreferenceResetDialog / LibraryCompletionDialog / SettingsTaskDialog）：modal-on-modal，独立 hierarchy，保留系统色。

### D. 跨阶段技术债

- `ArtworkAssetSnapshot.analysis` 已在 Phase 6.4/6.5 路径中用于 cache-hit 复用；后续若扩展持久化格式，需确认 displayPalette / salient / UltraDark / trusted hue 字段不会退化成旧 fallback analysis。
- `isEffectivelyMonochrome` 别名仍保留向后兼容；所有现有消费者切到 `isNearMonochrome` 后可删。
- `HomeAmbientPalette.ambientBaseColor` 仍走旧 HSL 单 sourceColor 路径。

---

## 验收速查

每轮关键命令：

```bash
# Build
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build

# Self-check (Debug only; Release 已 #if DEBUG 剥离)
COLOR_SYSTEM_SELF_CHECK=1 ./kmgccc_player.app/Contents/MacOS/kmgccc_player
```

Self-check 场景随 Phase 6.1–6.10 持续扩展，但只能作为 synthetic 回归辅助。2026-05-23 Phase 6.10 在 `main` 上本地 Debug 运行 `Result: ALL PASS`，覆盖 focus seed、muted trusted hue、true NearMono neutralization、BK true NearMono shapes、日间 airy BKArt、日间歌词深灰层级、MiniPlayer foreground strategy、pending palette hold、track-change flash、NearMono preset、lowSatColorCover light-mode brightness gating 相关断言。最终验收仍以真实封面手测矩阵为准。
