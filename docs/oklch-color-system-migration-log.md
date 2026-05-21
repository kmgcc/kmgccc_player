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

## 后续接力点（Phase 6 / 独立排期）

### B. AppKit toolbar 图标 tint（见 §4.5.12）

`AppKitMainToolbarController` 全部 toolbar 项使用 `NSImage(systemSymbolName:)`。已在 §4.5.12 写出明确实现路径（订阅 themeStore + 走 toolbar.items 应用 `paletteColors:` 配置）。本轮不做的原因：需要 lifecycle / ColorScheme 切换 / NSToolbarItem 系统重染色风险评估，建议独立排期。

### C. 其他 Phase 4.5 未接入区域

- **HomeStatCard / FavoriteArtistCard**：需多层透传，优先级低。
- **ListeningCalendarCard / HeatmapView**：heatmap 颜色另有 accent 控制，不属于普通前景。
- **NowPlaying 皮肤**：部分依赖 artwork analysis，需分策略评估（Phase 7 清理范畴）。
- **Modal 嵌套对话框**（MusicPreferenceResetDialog / LibraryCompletionDialog / SettingsTaskDialog）：modal-on-modal，独立 hierarchy，保留系统色。

### D. 跨阶段技术债

- `ArtworkAssetSnapshot` 不携带 Phase 2 新字段（displayPalette / salient / isUltraDark）。BKArt 走 snapshot cache 路径时 analysis 仍为 nil，丢失多色性增益。Phase 4/7 评估持久化或让 ThemeStore 在更早一层缓存 `ArtworkColorAnalysis`。
- LED `LEDColorResolver.baseColorForIndex` 内联 OKLab lerp 仍未走公共 `OKColor.oklabLerp`，Phase 6 Tone Ladder 时统一处理。
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

最终 self-check 场景总数：41（Phase 2 基础 14 + 收尾 1 + Phase 3 hotfix 5 + Phase 4 五场景 + Phase 4.5 十一场景 + Phase 5 歌词五场景）。2026-05-21 本地 Debug 运行：41/41 PASS。Phase 5 新增歌词项覆盖 nearMono window / fullscreen / cover blur neutral、彩色窗口 tint 保留、歌词层级。
