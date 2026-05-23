# OKLCH 迁移前置调查 — 颜色系统逆向建模最终报告

> 调查目的：在不动代码的前提下，逆向建模 APP 当前基于 HSL/RGB 的颜色系统，为未来迁移到 OKLCH 提供决策依据，并把"未来颜色系统 2.0"的方向性结论落到文档上。\
> 调查方式：三轮并行子代理调查。\
> 标记约定：\
> \
> \
> **Round 1**：拆 6 个消费域并行（Color Engine / Home & Ambient / Lyrics / MiniPlayer & Skins / Library Header / LED & Settings & Fallback）。\
> **Round 2**：对 R1 的 8 个未确认项做定点核查并修正结论。\
> **Round 3**：补查"艺术取色决策引擎"内部机制（小面积高显著色 / Ultra Dark / 近黑白防假色 / 忠于 artwork vs UI 化重整 / LED 分级质量），并把"颜色分配 2.0"方向性结论正式补充进报告。\
> \
> \
> \
> ✔ 后续轮次确认结论无需修正\
> ✱ 后续轮次修正了早先判断\
> ⚠ 仍存在不确定点或值得后续验证\
> ☆ 方向性结论（用户设计判断，不是单纯代码事实）\
> **R1 / R2 / R3** 标注新发现源自哪一轮

***

## 0. 写作说明

本报告同时承担四个功能：

1. **架构快照**：作为 OKLCH 迁移前 APP 颜色系统的"原始系统快照"留档。
2. **迁移依据**：为后续每个迁移阶段提供边界判断与风险点。
3. **设计资产清单**：把代码中 30+ 个隐性 magic number 抽象成"系统正在遵守的颜色哲学"，避免在迁移中误伤设计。
4. **颜色系统 2.0 方向书**：把"频谱真实多色优先 / Home Shapes 真实多色 / 歌词决策上收 Swift / Artwork Readability Profile 统一 / Tone Ladder"等设计方向作为后续重构的纲领。

报告共 14 节。`A`–`G` 是系统建模；`H` 是 R2 的 8 项定点核查结果；`I` 给出 R2 后的迁移路线结论；`J` 是 R3 的艺术决策引擎深度逆向（J.1 / J.2 已含 R4 修订）；`K` 是 R3 加入的"颜色系统 2.0"方向性结论（K.2 已含 R4 修订）；`L` 是 R3 整合的当前系统问题清单（R4 增加 #2b）；`M` 是 R3 改版后总结的迁移路线最终纲领；`N` 是 R3 / R4 changelog。

报告中"代码事实"与"设计方向"严格分开。**代码事实**有 `文件:行号` 引用；**设计方向**统一以 `☆` 前缀标出，明确表示"系统目前还不是这样，是未来要走的方向"。

***

## A. 颜色系统总览

整套系统是一个 **单源头、多角色派生、跨 Swift/Web 双层** 的"配色分发器"，并非简单的"主题色 + 各处使用"。

**核心特征：**

- **唯一动态颜色源头**：当前播放曲目的 artwork。所有动态色都从 `ArtworkColorExtractor.analyze()` 产出的 `ArtworkColorAnalysis` 派生。
- **三层分工架构**：
  1. `ArtworkColorExtractor` — 候选色生成器。像素扫描、过滤、聚类、加权排序、对比度迭代。
  2. `ColorMath` — 纯数学层。HSL/HSB/luminance 互转与钳制原语。
  3. `SemanticPalette` **+** `SemanticPaletteFactory` — 美学约束 + 角色分配层。
- **唯一发布层**：`ThemeStore` 单例。把 `SemanticPalette` 拆成 10+ 个 `@Published` 字段给 SwiftUI；同时把扁平化的 `ThemePalette` 序列化给 `LyricsSurfaceManager` → WebView。
- **两条独立的并行派色管线**：
  - `HeaderColorExtractor`（Library 详情页 Header）—— 各 Header artwork 独立分析。
  - `HomeHeroView.heroPalette` / `HomeAmbientPalette`（Home 视图）—— Home 首页卡片 / Ambient Shapes 独立分析。
- **已 OKLCH 化的孤岛**：`LEDColorResolver`。色相感知 chroma 封顶 + 明度浅深分支，最末才转回 NSColor。整个仓库迁移的现成范例。
- **跨 Swift/Web 的色彩管线**：歌词系统是唯一一条 "Swift 派色 → RGB(A) 字符串 → CSS 变量 → AMLL Core JS + CSS filter / mix-blend-mode 再加工" 的双层路径。Web 层独立持有 `plus-lighter` / `plus-darker` 不被 Swift 感知的二次着色。

**架构特点小结：**

1. 美学约束在 `SemanticPaletteFactory` 中以 30+ magic number 收敛，远比想象的集中。
2. 但 **消费端仍有局部 HSL 二次修正**（`MiniPlayer` 控件、`FullscreenPlayer` 歌词、`HomeAmbientPalette`），这些是迁移期最敏感的点。
3. 玻璃 UI 走 `GlassPillView` / `GlassStyleTokens` 的三层叠加（accent tint × 中性遮罩 × glass effect + 白边）。其中 accent tint 是唯一彩色层，opacity 极低（0.026–0.045）。
4. 缓存版本号机制存在 **覆盖漏洞**（详见 H.7）：ThemeStore 内存缓存包含版本前缀，`ArtworkAssetStore` 快照缓存不包含。这是真正影响 OKLCH 迁移的架构 bug。

***

## B. 真实代码链路图

### B.1 主链路：Artwork → ThemeStore → UI

```typescript
Track / artwork data
   │
   ▼
ThemeStore.updateTheme(for:)
   ├─ checksum (FNV-1a) → dominantColorCache 命中？
   │      命中 → 直接 refreshPalette(reason: "track_artwork_cached")
   │      未命中 → 双阶段提取：
   │
   ├─ Stage 1: ArtworkColorExtractor.quickAccentSample(18px, <50ms)
   │      → 仅写入 rawDominantColor，analysis 仍是 .neutralFallback ✱
   │      → refreshPalette(reason: "quick")
   │      → 第一波 @Published 触发（约 50ms 内）
   │
   └─ Stage 2: extractionQueue（QoS.userInitiated）
          ├─ ArtworkColorExtractor.dominantColor(56px)
          ├─ ArtworkColorExtractor.analyze(64px, 48 hue buckets)
          │     · 像素过滤 α<0.08
          │     · 面积/饱和度加权: area × toneWeight × satWeight
          │     · 噪声门槛 area<3% / 高饱和小面积<3%
          │     · usesDarkForeground = HSL>=0.58 || (HSL>=0.52 && WCAG>=0.48) ✱ 双门槛
          │     · 文本对比度迭代 (≤10 轮 / 目标 7:1 WCAG AAA)
          │     · 输出 ArtworkColorAnalysis
          ├─ ArtworkAssetStore snapshot 写回（注意：缓存键无版本前缀 ✱）
          ├─ token / checksum 失效检查
          └─ refreshPalette(reason: "extracted")
                  │
                  ▼
SemanticPaletteFactory.make(analysis, scheme, userFallbackAccent, useArtworkTint)
   ├─ optimizedAccent(analysis, scheme)
   │     ├─ 13 个色相带饱和度天花板（0.46–0.68 浅 / 0.32+ 深）
   │     ├─ 色相感知最小明度（黄≥0.66 / 绿≥0.70 / 蓝紫≥0.74-0.76）
   │     ├─ 暖色色相卫士（avg∈[0.07,0.20] 主动回正棕→红粉漂移）
   │     ├─ 低色彩 / 低色相置信度 saturation 上限收紧
   │     ├─ 黑白封面 nearMonochromeAccent（伪 hue 0.58 冷 / 0.10 暖）
   │     └─ softShoulder 平滑天花板（softness=0.10）
   │
   └─ 派生 16 个角色色（见 D 节与 C.1）
   │
   ▼
ThemeStore.refreshPalette()
   ├─ withAnimation(.easeInOut(0.20))
   ├─ 发布 @Published: accentColor, accentNSColor, baseColor,
   │   artworkBaseNSColor, palette, semanticPalette, analysis,
   │   selectionFill, paletteTrackID, paletteChecksum, themeGeneration
   └─ LyricsSurfaceManager.applyTheme(ThemePalette)
                  │
                  ▼
            UI 消费层（见 C 节）
```

### B.2 第二条链路：歌词跨 Swift / Web

```javascript
ThemeStore.semanticPalette
   ↓
ThemePalette（扁平化 RGBA 字符串结构）
   ↓
LyricsSurfaceManager.applyTheme(palette)
   ↓
LyricsWebViewStore（每个 surface 角色一个 store）
   ├─ 维护 baseThemePalette / overrideThemePalette
   ├─ JS 调用排队（WebView 未就绪时）
   └─ applyEffectiveTheme()
          ↓
WKWebView.evaluateJavaScript(setProperty(...))
   ↓
注入 6 个 CSS 变量：
   --amll-bg        ← Web 层不消费 ✱（死字段）
   --amll-text      ← 已用 (line 5367 → --amll-lp-color)
   --amll-active    ← 已用 (index.html L138/264/315/355/367)
   --amll-inactive  ← 已用 (index.html L114/123/130 等)
   --amll-accent    ← Web 层不消费 ✱（死字段）
   --amll-shadow    ← Web 层不消费 ✱（A/B 测试后强制 textShadow="none"）
   ↓
（Web 层）index.html / style.css / bridge.js / amll-core.js
   ├─ 6 变量 → 行内文字 / 副歌词
   ├─ Cover Blur 模式：另一组 CSS 写死变量
   │     --amll-cb-main-glow = rgb(255,255,255) 或 rgb(0,0,0)
   ├─ mix-blend-mode: plus-lighter / plus-darker（Swift 不感知）
   ├─ filter: drop-shadow(...)（写死白色）
   ├─ text-shadow: 0 0 0.035em var(--amll-cb-sub-glow)（变量+写死灰）
   └─ opacity 0.3 / 0.4 / 1.0 形成活跃 / 非活跃层级
```

***

## C. 模块级调查表

### C.1 颜色源头与全局发布

| 项                     | 内容                                                                                                                                                                                                                    |
| --------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 入口                    | `ArtworkColorExtractor.analyze(data:)`                                                                                                                                                                                |
| 像素预处理                 | 缩放至 64×64（full）或 18×18（quick）；α<0.08 跳过                                                                                                                                                                               |
| 候选色生成                 | 48 通道 hue 量化 + 面积加权：`area × toneWeight × satWeight`；toneWeight 在 B≈0.5 处 +20%                                                                                                                                         |
| 噪声门槛（R3）              | `ArtworkColorExtractor.swift:270-271`：`minimumBucketWeight = total × 0.030`、`noiseFloor = total × 0.012`                                                                                                              |
| 小面积高彩过滤（R3）           | L293：`areaShare < 0.030 && bucketSat > 0.55 → 移除`；L298-308：在 `isNearMono` 下三档收紧：`bucketSat>0.22 && areaShare<0.18` / `bucketSat>0.35 && areaShare<0.24` / `bucketSat>满足 saturationOutlierThreshold && areaShare<0.22` |
| `isNearMono` 触发条件（R3） | L276-279：`avgSat<0.14 \|\| vividness<0.10 \|\| (isExtremeTone && avgSat<0.18 && vividness<0.16)`                                                                                                                      |
| 输出                    | `ArtworkColorAnalysis`：dominant / average / topPalette / richPalette / bestTextSourceColor / usesDarkForeground / colorfulness / avgHue / avgSat / dominantHueConfidence / **isEffectivelyMonochrome**（R3 强调）         |
| 缓存                    | `dominantColorCache`（50 条 LRU，键含版本前缀）+ `ArtworkAssetStore`（键无版本前缀 ✱）                                                                                                                                                  |
| 去重                    | `extractionToken` (UUID) 失效旧请求 + `lastProcessedChecksum` 跳过同源                                                                                                                                                         |
| 浅/深分支                 | 不在 Extractor 内；ColorScheme 在 `SemanticPaletteFactory.make` 入口分流                                                                                                                                                       |
| Quick vs Extracted ✱  | quick 仅设 rawDominantColor，**不更新 analysis**；analysis 在 extracted 阶段才写入                                                                                                                                                 |

**R3 关键发现：topPalette 与 richPalette 的小面积色保留能力截然不同**

| 指标         | topPalette (`uiThemePalette`) | richPalette (`uiThemePaletteRich`)             |
| ---------- | ----------------------------- | ---------------------------------------------- |
| 噪声门槛       | totalWeight × 0.012           | totalWeight × 0.006（更激进）                       |
| 饱和加权       | `0.90 + sat×0.20`             | `0.70 + 0.30×sat`（高彩更突出）                       |
| 色相间隔       | ≥ 0.08                        | ≥ 0.05（更密集）                                    |
| 容量         | ≤ 4                           | ≤ 8                                            |
| 高饱和补救轮（R3） | 无                             | L478-489 显式第二轮：`saturationValue ≥ 0.45` 候选优先补位 |

**richPalette 在代码中显式承担"保留封面真实多色"职责，但** `optimizedAccent` **/** `globalAccent` **不读 richPalette，只读** `analysis.dominantColor` — 这是当前小面积高显著色无法进入 accent 的根本原因。详见 J.1。

### C.2 Home / Ambient Shapes / Hero

| 项                         | 输入                                                                                         | 处理                                                                                                                                  | 输出                                                    | 浅/深分支                                       | OKLCH 风险                                                    |
| ------------------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------- | ------------------------------------------- | ----------------------------------------------------------- |
| Home 全屏底色                 | `semanticPalette.ambientSurface` → 经 `HomeAmbientPalette.ambientBaseColor` ✱               | 深色：sat clamp(s×0.30, 0.03–0.22)，brightness clamp(b×0.18, 0.07–0.13)；浅色：sat clamp(s×0.16, 0.05–0.13)，L clamp(0.94+l×0.03, 0.93–0.97) | layer.backgroundColor                                 | 深 7–13% / 浅 93–97%                          | L 极端区域 OKLCH 色相易失稳                                          |
| Ambient Shapes 调色板        | `HomeAmbientPalette.makePalette(sourceColor, analysis, scheme)` — **不依赖 ambientSurface** ✱ | 6 色：主色 + 5 个 ±18/24/38/46/68° 色相偏移；HSL 钳制                                                                                           | `[NSColor]` 6 项                                       | 深色低色 sat 0.045–0.13 / 高色 0.13–0.38；浅色 ≤0.25 | 低饱和度域 OKLCH C 映射易失精度                                        |
| 单 shape 色分配               | `spec.colorIndex = id + rng.nextInt(0...3)`，循环取模                                           | 不分配多色；shape 10 = ultra（极大）；shape 11 = featuredLarge                                                                                 | NSColor                                               | 不分支                                         | —                                                           |
| Shape 二次加工                | 直接 fill，无 opacity 层、无 blur layer                                                           | 完全靠 HSL 钳制控制视觉重量                                                                                                                    | —                                                     | —                                           | OKLCH 下"克制感"需重新校准                                           |
| Hero 卡片色                  | `HomeHeroView.heroPaletteCache` 本地 `SemanticPaletteFactory.make(heroAnalysis)`             | 与全局 ThemeStore 并行                                                                                                                   | `palette.coverGradientDominant` + `coverGradientText` | factory 内部分支                                | 同一封面在 Home Hero / 详情页 Header / 全局 ThemeStore 可能产生 3 个略不同派生色 |
| Hero blur                 | `CoverGradientBlurConfig`（blurRadius 240–560，colorOverlayOpacity 0.46）                     | LinearGradient overlay：深 black 0.34→0.16 / 浅 black 0.08→0.02                                                                        | UIView blur + overlay                                 | 显式分支                                        | overlay 在 OKLCH 中需重测                                        |
| 玻璃卡片（播放列表 / 艺人 / 专辑 / 统计） | 无主题色 tint                                                                                  | 仅 `glassEffect` + `darkNeutralOverlay`（深 black 0.18 / 浅 clear） + hairline border                                                    | —                                                     | 分支                                          | 与 accent 解耦，迁移影响最小                                          |

✱ **修正**：第 1 轮报告中 `ambientSurface` 被怀疑为冗余字段。实际上它是 Home 全屏 **底层背景色** 的唯一来源（不参与 shape 着色，但驱动 base layer）。详见 H.1。

### C.3 歌词 / AMLL / Fullscreen / Cover Blur

| 项                            | 输入                                                                                                           | 处理                                                                                                                    | 输出                        | OKLCH 风险                                                                        |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------- | ------------------------- | ------------------------------------------------------------------------------- |
| Swift→Web 注入                 | `ThemeStore.palette` (ThemePalette)                                                                          | 序列化成 `rgb()` / `rgba()` 字符串                                                                                           | 6 个 CSS 变量                | 当前不产出 `oklch()`；Swift 侧需补 OKLCH 字符串生成                                           |
| 主窗口 surface                  | `palette.windowLyricActive/Inactive`                                                                         | 直发                                                                                                                    | rgb 字符串                   | 低                                                                               |
| 全屏标准 surface                 | `palette.fullscreenLyricBase/InactiveBase` + `FullscreenPlayerView.makeFullscreenLyricsColorSet()` 二次 HSL 调整 | active L∈[0.95, 0.98]；inactive L∈[0.52, 0.66]（再按 ultraDark 减 0.08–0.22）；S=clamp(s×0.70+0.06, 0.10, 0.58）；浅色 S 系数 0.48 | rgb                       | **高**：6 个 magic number 直接基于 HSL L/S，迁 OKLCH 必须重新感知校准                            |
| Cover Blur surface           | 同上 + `FullscreenCoverBlurBlendProfile` 判定 ✱                                                                  | 阈值 = `hslComponents(themeColor).lightness > 0.72` ? darker : lighter；themeColor 来自 averageColor                       | rgb + profile             | **高**：profile 切换 + CSS `mix-blend-mode: plus-lighter/plus-darker` 在 OKLCH 中行为未测 |
| Cover Blur main glow（CSS 写死） | 无（CSS 常量）                                                                                                    | `--amll-cb-main-glow: rgb(255,255,255)` 或 `rgb(0,0,0)`                                                                | text-shadow / drop-shadow | **A 类**设计基础：必须保留白/黑；迁 OKLCH 可改写 `oklch(100%/0%)` 但需测 blend                      |
| 副歌词 glow（写死灰）                | `--amll-cb-sub-glow: rgb(200,200,200)`                                                                       | 写死                                                                                                                    | text-shadow               | **B 类技术债**：应跟随主题亮度                                                              |
| 强调词高亮                        | `--amll-player-time` 时钟驱动 + clip-path / mask                                                                 | 不直接改色（位置/可见性）                                                                                                         | —                         | 中：插值空间需评估                                                                       |
| 非活跃层                         | opacity 0.3–0.4 写死                                                                                           | CSS 层                                                                                                                 | —                         | OKLCH 不变                                                                        |

✱ **死字段确认**（详见 H.3）：

- `--amll-bg` / `--amll-accent` / `--amll-shadow` 三个 CSS 变量被 Swift 推送但 Web 层完全不消费。`--amll-shadow` 是经过 A/B 测试后的明确设计决策（注释："root-level static text-shadow was visibly heavy in light mode"），其他两个无文档说明。

### C.4 MiniPlayer / NowPlaying Skin / 玻璃控件

| 元素                                         | 颜色源                                                                   | 浅/深行为                                                                            | 固定色等级             |
| ------------------------------------------ | --------------------------------------------------------------------- | -------------------------------------------------------------------------------- | ----------------- |
| MiniPlayer 标题 / 副标题                        | `.primary` / `.secondary`                                             | 系统自适应                                                                            | —                 |
| MiniPlayer 控件 icon (`controlPrimaryColor`) | `themeStore.accentColor` 经局部 HSL 修正                                   | 深色 L≥0.70；浅色 L≤0.45（`enforceMinimumHslLightness` / `enforceMaximumHslLightness`） | 跟随主题              |
| 进度条 fill                                   | `controlPrimaryColor × 0.88`                                          | 自适应                                                                              | —                 |
| 进度条 track                                  | `controlPrimaryColor × opacity(深 0.24 / 浅 0.18)`                      | 显式分支                                                                             | —                 |
| 玻璃描边                                       | `Color.white.opacity(0.15)`（深）/ `Color.primary.opacity(0.07)`（浅）      | 显式分支                                                                             | **A 类**（玻璃必白边）    |
| 玻璃 pillOverlay                             | `Color.black.opacity(深 0.30 / 浅 0.14)`（darkGlass material）            | 显式分支                                                                             | **A 类**（材质强化）     |
| 玻璃 accent tint                             | `themeStore.accentColor × opacity(0.024–0.045)` 按 prominence / scheme | 显式分支                                                                             | 跟随主题              |
| 悬停 artwork 遮罩                              | `Color.black.opacity(0.18)` + `Color.white.opacity(0.95)` icon        | 不分支                                                                              | **A 类**（封面对比始终需要） |
| RotatingCover 旋转高光                         | `NSColor.white @ 0.52/0.66/0.90/1.0`                                  | 不分支                                                                              | **A 类**（光学真实感）    |
| ClassicLEDSkin 阴影                          | `Color.black.opacity(0.35)`                                           | 不分支                                                                              | **B 类**（浅色下偏重）    |
| FullscreenCoverGradient 箭头                 | `Color.white.opacity(0.5)`                                            | 不分支                                                                              | **B 类**（应跟随主题）    |
| 各 Skin LED tint                            | `context.theme.artworkAccentColor`（共享）                                | —                                                                                | 跟随主题              |
| MiniPlayer Spectrum AppKit ✱               | 由父视图传入 `spectrumUsesDarkForeground` 参数；NSView 不自感知                    | 外层 SwiftUI 重新调用 updateNSView                                                     | 设计模式              |
| Skin 切换                                    | `SkinManager` 直接切换                                                    | —                                                                                | ⚠ 切换瞬间可能撞色        |

A 类 = 设计必须固定；B 类 = 应自适应但写死（潜在 bug）；C 类 = 无所谓。

### C.5 Library 详情页 Header

| 项                              | 内容                                                                                                                          |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------------------- |
| 入口                             | `HeaderColorExtractor.extractInBackground()`                                                                                |
| 缓存                             | 独立 32 条目缓存（**不复用 dominantColorCache**）                                                                                      |
| 颜色源                            | 该 Header 自己的 artwork → `ArtworkColorExtractor.analyze` → `SemanticPaletteFactory.make(useArtworkTint: true)`                |
| 三种 detail 是否共享路径               | **是**。Playlist / Album / Artist 走同一 `LibraryDetailHeaderView` 和同一 extractor；唯一差异是 artwork shape（Circle vs RoundedRectangle） |
| Header 背景渲染                    | **无 blur background**（不同于 Home Hero）                                                                                        |
| 文字色                            | `.secondary` / `.tertiary` SwiftUI 系统色，**不读 readableTextOnArtwork**                                                         |
| `headerSemanticPalette` 字段消费 ✱ | **Library 详情页 UI 中 0 处字段级读取**。该 palette 整体未被消费（详见 H.2）                                                                      |
| OKLCH 风险                       | 中等。Header palette 整体未被消费，但 extractor 本身仍跑完整流程；迁移时可考虑跳过派色或仅迁 globalAccent                                                    |

### C.6 LED / 频谱 / 可视化

| 项                | 内容                                                                                                             |
| ---------------- | -------------------------------------------------------------------------------------------------------------- |
| 入口               | `LedMeterView` → `LEDColorResolver`                                                                            |
| 颜色源（已 OKLCH 化）   | 优先 `palette.uiAccentOnDark/Light`；无 palette 时降到 `accentNSColor`；最后中性 OKLCH(L=0.82/0.46, C=0.010/0.008, H=0.60) |
| 中性回退             | `nearNeutralVolumeSourceColor()` 在低 colorfulness / avgSat 时从 averageColor 衍生                                   |
| 发光参数（OKLCH）      | 色相感知 chroma 封顶：黄 0.092–0.105，蓝 0.128–0.150；明度：深 0.81–0.86 / 浅 0.44–0.49                                        |
| 动态调整             | 每帧基于 `metrics.leds[]` 取离散 brightness level；opacity 0.15–0.95                                                   |
| 呼吸动画             | 0.32s hold + peak + 0.32s fall（isPlaying 时常驻）                                                                  |
| 最终输出             | `OKColor.okLCHToNSColor()` 转 sRGB                                                                              |
| ColorScheme 响应 ✱ | `LedMeterView` 通过 `@Environment(\.colorScheme)` 主动监听；不同于 `MiniPlayerSpectrumView` 走父视图参数传递                     |
| OKLCH 适用性        | **绿灯**——已完成。整个仓库 OKLCH 迁移可借鉴此结构                                                                                |

### C.7 Settings / Fallback / AccentColor 优先级

| 模块                          | 优先级链                                                                                                                |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------- |
| `LedMeterView`              | `palette.uiAccentOn*` → `accentColor` → 中性 OKLCH fallback                                                           |
| `ThemeStore.refreshPalette` | analysis ≠ neutralFallback && `globalArtworkTintEnabled` → optimizedAccent；否则 → `AppSettings.accentColor` (#E6C799) |
| `Header`                    | 同上但缓存独立                                                                                                             |
| `MiniPlayerSpectrumView`    | 显式 accent 参数 → `NSColor(white:0.7)` ⚠ 与主 fallback 不一致                                                               |
| UI 系统层                      | `Color.primary/.secondary/.tertiary`（与主题无关）                                                                         |

| 资源                              | RGB                             |
| ------------------------------- | ------------------------------- |
| `AccentColor.colorset` 深色       | (1.000, 0.784, 0.471) = #FFCC78 |
| `AccentColor.colorset` 浅色       | (0.900, 0.780, 0.600) = #E6C799 |
| `AppSettings.accentColorHex` 默认 | #E6C799                         |
| `ThemeStore.defaultBlueNS`      | #E6C799                         |

用户开关：仅 `globalArtworkTintEnabled`（默认 true）控制是否启用 artwork 派色。

ColorScheme 切换：`AppKitMainSplitPanes` 监听 `.onChange(of: colorScheme)` → `themeStore.colorScheme = newScheme` → `refreshPalette(reason: "swiftui_colorScheme_changed")`。覆盖完整。

***

## D. 当前颜色规则与美学规范清单

将代码中分散的 magic number 抽象成"系统正在遵守的设计哲学"。

### D.1 明度规则

- **深色 accent 不暗于背景上下文**：`L ≥ 0.66`（`SemanticPalette.swift:131`）
- **浅色 accent 不亮到失去 accent 感**：`L ≤ 0.50`（`:167`）
- **色相感知最小明度**：黄 ≥ 0.66 / 绿 ≥ 0.70 / 蓝紫 ≥ 0.74–0.76（`:121–125`）。把"绿色感知亮度低于 RGB 亮度"这个事实编进了规则
- **黑白封面强行落到中间区**：深色 [0.66, 0.74]；浅色 [0.32, 0.42]
- **全屏歌词活跃行近白**：`L ∈ [0.95, 0.98]`
- **全屏歌词非活跃行**：`L ∈ [0.52, 0.66]`（再按 ultraDark 减 0.08–0.22）
- **Home 深色底色**：`brightness ∈ [0.07, 0.13]`（艺术底板"沉下去"）
- **Home 浅色底色**：`L ∈ [0.93, 0.97]`（"轻但不失存在感"）
- **Ambient Shape 深色**：`L ∈ [0.16, 0.30]`；浅色 `L ∈ [0.66, 0.84]`
- **Cover Gradient 主色**：`L ∈ [0.22, 0.78]`（绝不极端）
- **控件 icon**：深色 L ≥ 0.70 / 浅色 L ≤ 0.45（比 accent 更极端，确保按钮可见）
- **Cover Blur profile 切换阈值 ✱**：`hslComponents(themeColor).lightness > 0.72` → `.darker`，否则 `.lighter`

### D.2 彩度规则

- **浅色 accent 饱和度天花板按色相分级**：约 0.46（粉/紫）–0.68（黄/橙）
- **深色 accent 饱和度地板**：`S ≥ 0.32`
- **黑白封面饱和度极低**：严格单色 `S ∈ [0.07, 0.08]`，近单色 `S ∈ [0.12, 0.14]`
- **低色彩 / 低色相置信度封面**：`S ≤ [0.18, 0.40]`
- **全屏歌词饱和度**：`S = clamp(s × 0.70 + 0.06, 0.10, 0.58)`
- **Cover Gradient 饱和度**：`S = clamp(s × 0.92, 0.10, 0.62)`
- **Ambient Shape 饱和度**：深色低色 0.045–0.13；高色 0.13–0.38；浅色 ≤0.25
- **softShoulder 平滑钳制**：仅在浅色 accent 天花板处使用（softness=0.10），其他都是硬 clamp ⚠ 不一致点
- **可读文本**：`S ∈ [0.04, 0.34]`，按浅 / 深分支

### D.3 色相规则

- **色相忠于封面，绝不大幅旋转**：除黑白封面外无主动 hue rotate
- **暖色色相卫士**：`avgHue ∈ [0.07, 0.20]` 时主动"回正"，避免棕色封面在 HSL 中漂移到红/粉
- **黑白封面伪 hue 注入**：无可用色相时强制 0.58（冷灰）或 0.10（温纸黄）
- **聚类候选色 hue 间隔**：UI palette ≥ 0.08（28.8°）；rich palette ≥ 0.05（18°）
- **shape 色变体**：±18/24/38/46/68° 偏移构成 6 色环
- **LED 色相感知 chroma**：黄色 hue 区 cap 0.092–0.105，蓝色 0.128–0.150（OKLCH）

### D.4 对比度 / 可读性规则

- **文本对比度迭代**：最多 10 轮，目标 WCAG AAA（7:1）。`bestTextSourceColor` 由 ArtworkColorExtractor 内部循环达成
- `usesDarkForeground` **双门槛 ✱**：`HSL >= 0.58 || (HSL >= 0.52 && WCAG >= 0.48)`。两个指标联合验证。HSL 用于美学，WCAG 用于无障碍。设计分工明确，**不是历史混用**
- **文本颜色派生**：深色前景 L=0.18±0.10；浅色前景 L∈[0.88, 0.985]
- **歌词非活跃层**：opacity 0.3–0.4 + 亮度压暗 0.08–0.22（层级双重锁定）
- **玻璃描边永远白色 0.15**：与玻璃光学不可分割

### D.5 角色分配规则

- **结构**：一个源色 → 1 个 accent 角色 + 2 个背景角色 + 4 个文本角色 + 4 个歌词角色 + 2 个 cover gradient 角色 + 3 个工具角色（共 16）
- **背景类**（`ambientSurface`, `artBackgroundPrimary/Secondary`）：直通 averageColor / topPalette，几乎不二次处理
- **交互类**（`globalAccent`, `uiAccentOnDark/Light`）：13 个色相带规则 + 黑白特殊路径
- **装饰类**（`coverGradientDominant`）：比 accent 多一道 S×0.92 + L 钳到 [0.22, 0.78]
- **发光类**（LED, 玻璃描边）：要么 OKLCH 色相感知 cap（LED），要么直接固定白（玻璃）
- **可视化类**（LED）：独立 OKLCH 路径，与 SemanticPalette 解耦但读取相同 ThemeStore

### D.6 审美目标（系统真正追求的"颜色哲学"）

代码中没有显式注释，但是隐式约束：

1. **不脏、不闷、不灰、不廉价**——通过浅色 accent 天花板 + 暖色卫士 + 中间调权重提升实现
2. **浅色不发白、深色不发艳**——浅色 accent L ≤ 0.50 防止 pastel；深色 accent S ≥ 0.32 防止灰雾
3. **背景与 accent 不打架**——背景类直通 average；shape 比 accent 多一档去饱和
4. **从封面来，但比封面更适合界面**——黑白伪 hue、低色彩低 sat、暖色色相卫士、对比度迭代，都是"修正而非复刻"
5. **同源但有层次**——Home / 歌词 / MiniPlayer 都从同一 SemanticPalette 取色，但分别走不同角色色字段
6. **接近极端处用软钳，常规处用硬钳**——只有浅色 accent 天花板用 softShoulder ⚠

### D.7 极端封面保护机制（R3 完整盘点）

代码中没有出现 `Ultra Dark` 字面量进入 `SemanticPaletteFactory` 主链路。R3 在仓库内追踪到 **两套并存的"极端封面保护"**：

**A. 字面量 Ultra Dark（仅作用于 Fullscreen 歌词与 BKArtBackground 视觉层）**

- 定义位置：`BKArtBackgroundView.swift:296-300` `isUltraDarkPalette(_:)`
  - 条件 A：`imageCoverLuma < 0.36 && areaDominantB < 0.30`（彩色暗图，如夜空蓝）
  - 条件 B：`imageCoverLuma < 0.30 && grayScore > 0.70`（暗灰图，如黑白胶片）
- 视觉层独立判定：`BKArtBackgroundView.swift:1708` `isUltraDarkCover = imageCoverLuma < 0.22` → `ultraDarkOverlayOpacity = 0.50`（叠加 50% 黑蒙版）
- 歌词消费：`FullscreenPlayerView.swift:3143` 通过 `bkController.isUltraDarkActive` 锁定 `lockedFullscreenLyricsUltraDark`，再在 L3462-3471 的 `makeFullscreenLyricsColorSet` 内对非活跃行 lightness 额外下压 0.17–0.22、活跃行下压 0.06–0.10、非活跃饱和度缩到 0.34–0.40

**B. 隐性极暗 / 黑白保护（系统级，在** `SemanticPaletteFactory.optimizedAccent` **主链路内）**

不是显式 ultraDark 标志，而是通过 `analysis.isEffectivelyMonochrome` 触发 `nearMonochromeAccent`（`SemanticPalette.swift:95-96, 186-225`）：

- 触发条件（`ArtworkColorAnalysis.swift:230-238`）：4 个 OR 分支，最关键的 `isExtremeTone = avgHslL<0.18 || avgHslL>0.86` + 低彩条件
- 进入后强制：
  - 深模式 `lightness ∈ [0.66, 0.74]`（极暗封面被强行提亮到 ≥0.66）
  - 浅模式 `lightness ∈ [0.32, 0.42]`（极亮封面被强行压暗到 ≤0.42）

**结论**：

1. 字面量 Ultra Dark **不进入** `SemanticPaletteFactory`、`HomeAmbientPalette`、Cover Blur profile，**只走 Fullscreen 歌词**与 BKArtBackground 视觉层。
2. 系统级的极暗保护实际上是 `isEffectivelyMonochrome → nearMonochromeAccent` 路径。极暗封面被这套机制提亮到 L≥0.66，**牺牲了原封面的"压暗、沉静、夜色感"**。
3. 当前缺一个真正的"系统级 ultraDark 但仍允许暗 accent"路径。详见 J.2 与 ☆ K.2。

### D.8 小面积高显著色机制（R3 现状）

R3 推演 3 个典型场景（基于 `ArtworkColorExtractor.swift:270-323` + `SemanticPalette.swift:91-184`）：

| 场景                | bucket 权重 | 噪声/3% 过滤                                                                     | isNearMono                                                          | 进入 topPalette | 进入 richPalette | 进入 globalAccent            |
| ----------------- | --------- | ---------------------------------------------------------------------------- | ------------------------------------------------------------------- | ------------- | -------------- | -------------------------- |
| 95% 黑灰 + 5% 鲜黄    | ≈ 0.05    | L293 不触发 (0.05>0.03)；但 isNearMono 触发 → L298 (`sat>0.22 && area<0.18`) **过滤** | true (avgSat<0.14)                                                  | ✗             | ✗（同样被噪声门槛压下）   | ✗（accent 只读 dominantColor） |
| 90% 深蓝绿 + 10% 明橙  | ≈ 0.10    | 不触发                                                                          | false（蓝绿有 sat）                                                      | ✓             | ✓              | ✗（dominant 仍是蓝绿）           |
| 80% 低饱暗色 + 20% 红色 | ≈ 0.20    | 不触发                                                                          | 取决于 avgSat：若 avgSat<0.14 → 触发 L301 (`sat>0.35 && area<0.24`) **过滤** | 概率失败          | 概率失败           | ✗                          |

**核心问题（R3 确认）**：

1. `optimizedAccent` **不读 richPalette / topPalette**，只读 `analysis.dominantColor`。即使 richPalette 已经识别出小面积高彩色，accent 也不会取它。
2. `isNearMono` **下三档过滤**对低饱和环境中的"5% 鲜黄、10–20% 高彩点睛色"非常严厉，几乎一概清除。
3. **richPalette 第二轮高彩补救**（`ArtworkColorExtractor.swift:478-489`）是当前唯一保留"小面积真实多色"的代码位置，但其消费方目前为 0（无 UI 直接读取 richPalette）。

**结论**：当前小面积高显著色机制 **已明显弱化**，仅在 `richPalette` 中保留了真实多色采样能力，但下游派色没人消费。这与"颜色系统 2.0"方向直接冲突——详见 ☆ K.1（频谱真实多色）与 ☆ K.3（Home Shapes 真实多色）。

***

## E. 散落逻辑与架构风险清单

### E.1 已收敛的部分

- 单一 artwork 入口（`ArtworkColorExtractor.analyze`）
- 美学约束几乎全部集中在 `SemanticPaletteFactory.optimizedAccent` 与 `coverGradientDominant` 中
- LED 链路完整 OKLCH 化，且已经把"源色选择"与"发光参数化"清晰分层
- ColorScheme 切换 → `refreshPalette` 链路单一确定
- artwork 缓存（`dominantColorCache` + `ArtworkAssetStore`）、token / checksum 去重已具备工业级防护

### E.2 仍然散落的部分

- `MiniPlayerView` **控件 icon 的 HSL 修正**（`enforceMinimumHslLightness` 深 0.70 / `enforceMaximumHslLightness` 浅 0.45）— 散在 View 层
- `FullscreenPlayerView.makeFullscreenLyricsColorSet` 的 6 个 magic number — 歌词最敏感视觉规则散在 View 中
- `HomeAmbientPalette.makePalette` **+** `.ambientBaseColor` — Home 域完全独立的二次派色管线
- `HomeHeroView.heroPalette` + `HeaderColorExtractor.headerSemanticPalette` — 两套独立的 `SemanticPaletteFactory.make` 副本，与全局 ThemeStore 并行
- `MiniPlayerSpectrumView` **fallback (0.7 灰)** 与全局 fallback (#E6C799) 不一致
- `FullscreenCoverGradient` **箭头** `Color.white.opacity(0.5)`、`ClassicLEDSkin` **阴影** `Color.black.opacity(0.35)` — B 类潜在 bug
- **AMLL CSS** 层的 `--amll-cb-sub-glow: rgb(200,200,200)`（应跟随主题）

### E.3 重复但暂不应动的

- `HomeHeroView.heroPalette` 与 `ThemeStore.semanticPalette` 看似冗余，但 Hero 显示首页顶部卡片当前 artwork，不一定等于当前播放。**正当并行**
- `HeaderColorExtractor` 同理 — 详情页用的是该列表 / 专辑 / 艺人的 artwork
- 玻璃描边的固定白、cover blur main glow 的固定白 / 黑 — **设计基础，不要动**
- 旋转封面光环 (`NSColor.white` 0.52–1.0) — 光学真实感的核心

### E.4 死代码与字段冗余清单 ✱

第 2 轮新发现：

| 字段                                                | 状态         | 说明                                                              |
| ------------------------------------------------- | ---------- | --------------------------------------------------------------- |
| `--amll-shadow` CSS 变量                            | **明确死代码**  | Web 侧 textShadow 强制 "none"，A/B 测试后保留为旧契约（index.html L5383-5391） |
| `--amll-bg` CSS 变量                                | **死代码无注释** | Swift 推送但 Web 完全不消费                                             |
| `--amll-accent` CSS 变量                            | **死代码无注释** | 同上                                                              |
| `ThemePalette.shadow` Swift 字段                    | 部分死字段      | Swift 仍在计算并序列化                                                  |
| `headerSemanticPalette` 14 个字段                    | **整体未消费**  | Library 详情页 UI 0 处字段级读取（详见 H.2）                                 |
| `SemanticPalette.globalAccent` 直接读取               | 仅间接消费      | UI 通过 `ThemeStore.accentColor / accentNSColor` 间接读取             |
| `SemanticPalette.coverGradientText` 直接读取          | **未消费**    | factory 完整返回但无 UI 读取                                            |
| `SemanticPalette.secondaryTextOnArtwork` 直接读取     | **未消费**    | 同上                                                              |
| `SemanticPalette.windowLyricActive/Inactive` 直接读取 | 仅间接消费      | 通过 `ThemePalette` → CSS 变量消费                                    |

### E.5 最容易在 OKLCH 迁移中"误伤"的点

1. **HSL L 与 OKLCH L 的非线性映射**。30+ magic number 都需要按色相重新校准
2. **CSS** `mix-blend-mode: plus-lighter / plus-darker`。RGB 加法混合，OKLCH 颜色空间下行为未测；建议保留 RGB 字符串注入
3. `relativeLuminance(c) ≥ 0.58` **+ HSL 双门槛**（`usesDarkForeground`）。WCAG 权重必须保留；HSL 阈值才可能换 OKLCH L
4. `softShoulder` **仅在浅色 accent 天花板使用**。若 OKLCH 后所有钳制都改用软肩，会改变多个角色色的视觉过渡
5. `HomeAmbientPalette` **的 6 色变体 ±18–68° hue 旋转**。OKLCH 在低 chroma 下色相敏感度下降
6. **黑白封面伪 hue 0.58 / 0.10**。在 OKLCH 中 chroma=0 时 hue 无意义；需明确改用 `oklch(L 0 0)`
7. `FullscreenPlayerView` **的 active L≥0.95 / inactive L∈[0.52, 0.66]**。OKLCH L 范围与 HSL L 完全不等价
8. `colorExtractionCacheVersion` **仅控制** `dominantColorCache`**，无法失效** `ArtworkAssetStore` **快照** ✱。详见 H.7，这是真正的架构 bug

***

## F. 面向 OKLCH 的迁移边界判断

### F.1 应优先迁移（高收益、低风险）

- `SemanticPaletteFactory.optimizedAccent` **中的色相感知饱和度天花板**——OKLCH chroma 的色相敏感性远优于 HSL saturation，是这部分逻辑的天然归宿
- `globalAccent` **/** `uiAccentOnDark` **/** `uiAccentOnLight`——核心交互色，消费方都通过 ThemeStore 间接读取，可以在源头切换
- `ColorMath` **数学层**——加 OKLCH 等价函数（不替换现有 HSL 函数）
- `HeaderColorExtractor` **与** `HomeHeroView.heroPalette`——都是同一 factory 的副本，跟随主源头切换即可
- `coverGradientDominant`——大面积模糊层的颜色钳制在 OKLCH 中更直观
- `HomeAmbientPalette.makePalette`——shape 调色板的 6 个变体在 OKLCH 中色相旋转的稳定性更好

### F.2 可以迁移但必须谨慎验证

- `FullscreenPlayerView.makeFullscreenLyricsColorSet`——6 个 magic number 需逐项重新感知校准
- `MiniPlayer enforceMin/MaxHslLightness`——参数化为 OKLCH 等价后，需对比深浅模式所有 skin 的视觉
- **歌词 Swift→Web 注入**——Swift 侧产出 `oklch()` 字符串可行，但需先确认目标 macOS WebKit 对 `oklch()` 的支持
- **CSS** `mix-blend-mode` + `drop-shadow` + `text-shadow`——需要实测 OKLCH 颜色在这些 filter 下的渲染
- `HomeAmbientPalette.ambientBaseColor` **极端浅色域（L 0.93–0.97）**——OKLCH 高 L 区域 chroma 易失稳
- `FullscreenCoverBlurBlendProfile` **阈值 0.72**——若改用 OKLCH，需视觉对照确定等价阈值
- `usesDarkForeground` **HSL 阈值 0.58**——可换 OKLCH L，但 WCAG 那条副条件必须保留

### F.3 不宜粗暴迁移

- `ArtworkColorExtractor.analyze` **的像素聚类与加权**——图像采样运行在 sRGB / linear RGB 上有性能与精度优势。聚类**应保留 RGB**，只在输出 `ArtworkColorAnalysis` 时再转 OKLCH
- **CSS** `mix-blend-mode: plus-lighter / plus-darker`——RGB 加法物理模型，OKLCH 下行为未定义；保留 RGB
- **CSS** `filter: drop-shadow`**、**`backdrop-filter`——浏览器实现层，迁不动
- **玻璃描边 / 旋转光晕 / 悬停白 icon**——A 类设计基础色，可注释标记 `// MARK: - Liquid Glass design system (sRGB white invariant)`
- **LED 已经是 OKLCH**——保持
- `relativeLuminance`**（WCAG）**——必须保留用于无障碍判定（详见 H.6）
- `MiniPlayerSpectrumView` **的 0.7 灰 fallback**——纯灰色 OKLCH 没意义（保留即可，但应改为 #E6C799 与全局一致）

***

## G. 阶段性迁移建议

### 第 0 阶段：审计与基础设施

- 把本报告作为 OKLCH 迁移规范文档归档
- 把 `SemanticPaletteFactory` 的所有 magic number 提取到 `SemanticPaletteTokens.swift`（常量化）。提取后行为不变，仅为后续单点替换做准备
- 增加色彩回归视觉测试：选 20 张代表性封面（暖色 / 冷色 / 黑白 / 极暗 / 极亮 / 高饱和 / 低饱和 / 杂色），渲染所有关键 UI 状态并存基线截图
- **架构清理（必须先做）**：
  - 清理 `ThemePalette.shadow` 与 `--amll-shadow` 死字段，或删除 Swift 侧序列化以减少误导
  - 清理 `--amll-bg` / `--amll-accent` 两个无文档的死字段
  - 修复 `MiniPlayerSpectrumView` 的 0.7 灰 fallback → 改为 `#E6C799` 与全局一致
  - 修复 `ClassicLEDSkin` 阴影 / `FullscreenCoverGradient` 箭头两个 B 类潜在 bug

### 第 1 阶段：OKLCH 数学层

- 在 `ColorMath` 中新增 OKLCH ↔ NSColor / RGB 转换函数（不要替换现有 HSL 函数）
- 复用 `LEDColorResolver` 内的 `OKColor` 工具，提升为公共工具
- 提供 `oklchClampLightness` / `oklchClampChroma` / `oklchSoftShoulder` / `oklchHueAwareChromaCap` 等等价原语
- 给所有原语写 unit test（覆盖典型 RGB ↔ OKLCH 来回稳定性）

### 第 2 阶段：主题源头与 SemanticPalette

- 复制 `SemanticPaletteFactory` 为 `SemanticPaletteFactoryOKLCH`，按 token 表逐角色用 OKLCH 等价规则重写
- 用 feature flag (`AppSettings.useOKLCHPalette`) 切换；默认关闭，给开发者打开
- 在 30+ token 上做 visual diff。重点关注：暖色色相卫士、黑白伪 hue、13 色相带 chroma cap 是否能复现 HSL 版的"克制感"
- **同时升级缓存版本号机制**：把 `colorExtractionCacheVersion` 也作用到 `ArtworkAssetStore` 的缓存键（详见 H.7），否则 OKLCH 派色完成后旧 snapshot 仍会回流

### 第 3 阶段：装饰类（Home / Header / Cover Gradient）

- 迁移 `HomeAmbientPalette.makePalette` / `ambientBaseColor`、`coverGradientDominant` 到 OKLCH
- 迁移 `HeaderColorExtractor` 和 `HomeHeroView.heroPalette`（跟随第 2 阶段）
- 注意 ambient base color 浅色域 L 0.93–0.97 的边界处理
- 视觉回归测试覆盖 Home、各 Library 详情页、加载中占位

### 第 4 阶段：交互类（MiniPlayer、玻璃 tint、Skin LED 色源）

- 把 `MiniPlayer.enforceMin/MaxHslLightness` 改为 OKLCH 等价
- 玻璃 tint 保持 accent 来源（已经走 ThemeStore），但 tint opacity 不变
- Skin 的 `artworkAccentColor` 跟随 ThemeStore 迁移即可
- 验证 NowPlaying 所有 skin 在浅 / 深、艺术 tint 开 / 关下的视觉

### 第 5 阶段：歌词跨 Swift / Web

- Swift 侧增加 OKLCH 字符串生成；以双轨注入，先验证 WebKit 支持
- 把 `FullscreenPlayerView.makeFullscreenLyricsColorSet` 的 6 个 magic number 改为 OKLCH 等价（最敏感步骤）
- `FullscreenCoverBlurBlendProfile` 阈值改为 OKLCH 等价（建议引入 `OKColor` 工具统一计算）
- Cover Blur profile 切换不动；`mix-blend-mode` 暂保留（仍接收 rgb 字符串）
- 验证主窗口 / 全屏标准 / 全屏 cover blur / 高亮 surface / 预览 surface 五个 surface
- 收尾把 `--amll-cb-sub-glow` 改为 Swift 注入

### 第 6 阶段：评估 LED / glow / blur 边界

- LED 已在 OKLCH——无变更
- CSS `mix-blend-mode` 保持 RGB 字符串注入，不强迁
- 旋转光晕 / 玻璃描边 / cover blur main glow 保留 sRGB 白 / 黑，标 A 类常量

### 第 7 阶段：清理

- 标记 `ColorMath` 中仅 HSL 的函数为 deprecated；新增代码强制 OKLCH 入口
- 评估 `headerSemanticPalette` 是否要继续生成（当前 14 个字段全部未被消费），可考虑只产 globalAccent
- 把已废弃的 Swift→Web 死字段从 ThemePalette 移除

***

## H. 第 2 轮定点核查 8 项详细发现

### H.1 SemanticPalette.ambientSurface 真实消费路径 ✱

**结论**：实际被消费，但仅驱动 Home 全屏的 base layer 背景色，不参与 shape 着色。

**完整调用链**：

1. `HomeView.swift:293` 读取 `themeStore.semanticPalette.ambientSurface`
2. 传给 `HomeAmbientShapesBackground(sourceColor:)` 参数
3. `updateNSView()` 调用 `nsView.update(sourceColor:...)`
4. `HomeAmbientRootView.update()` → `updateBaseLayerColor()`
5. `updateBaseLayerColor()` 调用 `HomeAmbientPalette.ambientBaseColor(from: sourceColor, ...)`（`HomeAmbientShapesBackground.swift:708-750`）
6. 经深 / 浅模式分支二次派色（sat clamp(s×0.30, 0.03–0.22) / brightness clamp(b×0.18, 0.07–0.13) 等）
7. 设置到 `baseLayer.backgroundColor`（CoreAnimation layer）

**关键观察**：

- `HomeAmbientPalette.makePalette()` 生成的 6 色 shape 调色板 **不依赖 ambientSurface**，而是直接读 `sourceColor` 和 `analysis`
- 因此 `ambientSurface` 的职责被精确限定在"Home 全屏背景底色"

**对第 1 轮判断的修正**：

- 第 1 轮判断"冗余或预留" → **错误**
- `ambientSurface` 是 base layer 的实际驱动字段，**必须迁移**

**OKLCH 迁移影响**：

- 必须迁移
- 注意 `ambientBaseColor()` 内极端浅色域（L 0.93–0.97）的 OKLCH 等价
- 浅 / 深模式分支必须保留

### H.2 HeaderColorExtractor 输出角色色的真实消费 ✔（部分修正）

**结论**：`headerSemanticPalette` 整体在 Library detail UI 中 **未被任何字段级读取**。但 `ThemeStore.semanticPalette` 的部分字段在其他 UI 中有实际消费。

`headerSemanticPalette` **调查结果**：

- 写入：`PlaylistPageController.swift:896, 912, 1015`
- 读取：**0 处字段级读取**

`ThemeStore.semanticPalette.*` **字段消费表（全仓 Grep）**：

| 字段                            | 直接消费点                                                                                | 间接消费路径                                                  |
| ----------------------------- | ------------------------------------------------------------------------------------ | ------------------------------------------------------- |
| `globalAccent`                | 0                                                                                    | ✓ 经 `ThemeStore.accentColor / accentNSColor` 间接消费（主要路径） |
| `ambientSurface`              | HomeView:293                                                                         | 见 H.1                                                   |
| `readableTextOnArtwork`       | ExpandableVolumeControl:153, FullscreenMiniPlayerView:428, FullscreenPlayerView:2104 | —                                                       |
| `artBackgroundPrimary`        | FullscreenMiniPlayerView:457                                                         | —                                                       |
| `artBackgroundSecondary`      | FullscreenMiniPlayerView:458                                                         | ✓ LedMeterView → LEDColorResolver                       |
| `fullscreenLyricBase`         | FullscreenPlayerView:3829                                                            | —                                                       |
| `fullscreenLyricInactiveBase` | FullscreenPlayerView:3862                                                            | —                                                       |
| `coverGradientDominant`       | FullscreenCoverGradientBlurSkin:84, 121                                              | ✓ LEDColorResolver:255                                  |
| `coverGradientText`           | **0**                                                                                | 无消费                                                     |
| `secondaryTextOnArtwork`      | **0**                                                                                | 无消费                                                     |
| `windowLyricActive`           | 0                                                                                    | ✓ 经 `ThemePalette` → CSS 变量 `--amll-active`             |
| `windowLyricInactive`         | 0                                                                                    | ✓ 经 `ThemePalette` → CSS 变量 `--amll-inactive`           |
| `uiAccentOnDark/Light`        | ✓ LEDColorResolver                                                                   | —                                                       |

**对第 1 轮判断的修正**：

- 第 1 轮判断"`globalAccent` 在 UI 中被消费" → **精确化**：是经 `ThemeStore.accentColor` 间接消费，没有直接读 `semanticPalette.globalAccent`
- `headerSemanticPalette` 整体未消费 → **确认**
- 全局 `semanticPalette` 中 `coverGradientText`、`secondaryTextOnArtwork` 完全未消费 → **新发现**

**OKLCH 迁移影响**：

- `headerSemanticPalette` 整体可考虑延迟迁移或标 deprecated
- `coverGradientText` 和 `secondaryTextOnArtwork` 可在迁移时一并清理
- Header 的 `optimizedAccent` 13 色调带逻辑虽未直接消费，但跟随主源头自动迁移即可

### H.3 Lyrics shadowColor 与 Web 死字段 ✱

**结论**：`shadowColor` 是 **明确的设计决策性死代码**（非历史遗留）。另发现 `--amll-bg` 和 `--amll-accent` 两个无文档的死字段。

`shadowColor` **全链路定位**：

| 位置                                  | 性质                   | 行号              | 状态                                                                 |
| ----------------------------------- | -------------------- | --------------- | ------------------------------------------------------------------ |
| `ThemeStore.swift` refreshPalette 内 | 计算初始值                | 408 / 427 / 430 | 按 isDark 计算（暗 0.3/0.5；浅 0.1/0.15）                                  |
| `ThemePalette` Swift 结构体            | `let shadow: String` | 30              | 字段定义                                                               |
| `LyricsWebViewStore.swift`          | bridge 打包            | 1323            | `"shadowColor": palette.shadow` 发往 WebView                         |
| `LyricsWebViewStore.swift`          | CSS 变量注入             | 1341            | 注入 `--amll-shadow`                                                 |
| `index.html`                        | Web 侧 config 接收      | 5383-5391       | **检查** `hasOwn("shadowColor")` **但强制 textShadow="none"** |

`index.html` 的注释说明：

> "root-level static text-shadow was visibly heavy in light mode and contributed no measurable performance benefit when removed (A/B 1)"

emphasis glow 现由 per-character emphasize-word 动画管理，不再依赖 root-level text-shadow。

**Swift↔Web 颜色字段对账表**：

| 字段                                         | Swift 推 | Web 用 | 状态                                   |
| ------------------------------------------ | ------- | ----- | ------------------------------------ |
| `palette.background` (`--amll-bg`)         | ✓       | ✗     | **死字段（无注释）**                         |
| `palette.text` (`--amll-text`)             | ✓       | ✓     | 已使用，通过 `--amll-lp-color` (line 5367) |
| `palette.activeLine` (`--amll-active`)     | ✓       | ✓     | 已使用                                  |
| `palette.inactiveLine` (`--amll-inactive`) | ✓       | ✓     | 已使用                                  |
| `palette.accent` (`--amll-accent`)         | ✓       | ✗     | **死字段（无注释）**                         |
| `palette.shadow` (`--amll-shadow`)         | ✓       | ✗     | **死字段（A/B 1 设计决策）**                  |

**对第 1 轮判断的修正**：

- 第 1 轮判断"`shadowColor` 可能是死代码" → **确认且强化**：A/B 测试后的明确弃用
- **新发现**：`background` 与 `accent` 同样是 Swift 推 Web 不用的死字段，但无文档

**OKLCH 迁移影响**：

- 必须迁移：`text`、`activeLine`、`inactiveLine`（仅这 3 个 Swift→Web 字段）
- 建议清理：`background`、`accent`、`shadow`
- **关键收益**：减少 Web 层注入字段后，Swift 侧改 oklch() 字符串生成时只需关心 3 个字段，大幅降低迁移面

### H.4 MiniPlayerSpectrumView 对 colorScheme 切换的响应 ✔

**结论**：**不是 bug**。设计模式是 SwiftUI 父视图通过参数传递 `spectrumUsesDarkForeground`，`updateNSView` 在父视图重渲染时被重新调用。AppKit NSView 不自感知 effectiveAppearance 变化。

**关键代码**（`MiniPlayerSpectrumView.swift`）：

- 行 24-25：`MiniPlayerSpectrumView` 是 SwiftUI struct
- 行 98-105：fallback `NSColor(white: 0.7, alpha: 1.0)`（与全局 #E6C799 fallback 不一致 ⚠）
- 行 110：`MiniPlayerSpectrumContainer` 是 **NSViewRepresentable**
- 行 134-144：`updateNSView` 传递 `accentColor` / `artworkColors` / `usesDarkForeground` 三个参数
- 行 166+ `MiniPlayerSpectrumHostView` 是 NSView 子类
  - **无** `viewDidChangeEffectiveAppearance` **重写**
  - **无** `effectiveAppearance` **KVO 观察**
  - 仅有 `updateColors()` 方法供外层调用

**与** `LedMeterView` **的对比**：

- `LedMeterView` 行 17：`@Environment(\.colorScheme) private var colorScheme` 主动监听
- 行 53：传给 `LEDColorResolver` 的 colorScheme 来自环境
- 这是另一种设计模式：SwiftUI 直接监听 colorScheme，间接传给 OKLCH 计算

**对第 1 轮判断的修正**：

- 第 1 轮疑问"`MiniPlayerSpectrumHostView` 是否在 colorScheme 切换时刷新" → **确认非 bug**
- 外层 SwiftUI 重新调用 `updateNSView` 保证颜色刷新
- AppKit NSView 不主动感知 appearance

**OKLCH 迁移影响**：

- 无变更需求（已通过外层参数传递保证）
- 但应统一两种模式：建议未来 spectrum 也用 `@Environment(\.colorScheme)` 与 LED 一致，减少架构差异

### H.5 FullscreenCoverBlurBlendProfile 判定阈值 ✔

**结论**：阈值是 `hslComponents(themeColor).lightness > 0.72`。`themeColor` 来源是艺术品 `averageColor`（经 `resolveCoverBlurThemeColor` 解析）。

**核心源码**（`FullscreenPlayerView.swift:3772-3789`）：

```swift
let themeHSL = hslComponents(from: themeColor)
let profile: FullscreenCoverBlurBlendProfile = themeHSL.lightness > 0.72
    ? .darker
    : .lighter
```

`hslComponents(from:)` 在行 3934-3970，使用 NSColor 的标准 HSL 转换：`L = (max(R,G,B) + min(R,G,B)) * 0.5`

**视觉目标**：

- 封面亮（L > 0.72）→ `.darker` → CSS `mix-blend-mode: plus-darker` 压暗叠加的歌词
- 封面暗（L ≤ 0.72）→ `.lighter` → CSS `mix-blend-mode: plus-lighter` 提亮歌词
- 在全屏 cover blur 模式下保证歌词与背景的视觉对比度

**对第 1 轮判断的修正**：

- 第 1 轮疑问"判定阈值未确认" → **确认 0.72**
- 第 1 轮疑问"是否基于 `brightnessComponent`" → **修正**：实际是 HSL lightness，不是 HSB brightness

**OKLCH 迁移影响**：

- 二分判定，精度要求不高，**短期可保留 HSL L > 0.72**
- 长期建议改用 OKColor 计算 OKLCH L（与 LED 路径一致），等价阈值约 0.56
- 也可考虑改为 WCAG 相对亮度，反映"用户感知到的封面整体亮度"更准确
- **不是迁移路径上的高优先级项**

### H.6 textPalette() WCAG luminance 与 HSL lightness 双指标 ✔

**结论**：**刻意分工，非历史混用**。HSL lightness 用于"品味层"（美学决策），WCAG luminance 用于"合规层"（无障碍）。

`textPalette()` **完整流程**（`ArtworkColorExtractor.swift:494-609`）：

| 行号        | 指标                                                                                                           | 用途               |
| --------- | ------------------------------------------------------------------------------------------------------------ | ---------------- |
| 519       | 同时计算 HSL lightness 与 WCAG luminance                                                                          | 为后续加权使用          |
| 533-534   | 两个指标都参与面积加权汇总                                                                                                | weighted average |
| 540       | HSL lightness 用于 **midToneBoost**：`abs(hslLightness - 0.52) * 1.7`                                           | 中调像素优先（品味）       |
| 554-560   | **usesDarkForeground 双门槛**：`coverHslLightness >= 0.58 \|\| (coverHslLightness >= 0.52 && coverLuma >= 0.48)` | 前景深 / 浅决策        |
| 574-585   | 仅用 HSL lightness 调整亮度（lightPressure / darkPressure）                                                          | 生成文本颜色（品味）       |
| 595 + 809 | 仅用 WCAG luminance 做对比度循环（≤10 轮，目标 7:1）                                                                       | WCAG AAA 合规      |

**职责边界**：

| 指标             | 职责                                                            | 行号                     |
| -------------- | ------------------------------------------------------------- | ---------------------- |
| HSL lightness  | (1) 中调像素加权; (2) 前景色深/浅的**初步判断**; (3) 生成文本颜色亮度调整               | 519, 540, 554, 574/580 |
| WCAG luminance | (1) 前景色深/浅的**确认条件**（副条件）; (2) 对比度循环的唯一判断依据; (3) WCAG 7.0:1 强制 | 519, 555, 595, 809     |

**对第 1 轮判断的修正**：

- 第 1 轮疑问"是否历史混用" → **修正为协作设计**
- 两个指标在 OKLCH 迁移后**必须并存**

**OKLCH 迁移影响**：

- **WCAG luminance 必须保留**（行 519, 595, 809）— 无障碍规范硬要求
- HSL lightness 可改 OKLCH L：
  - 行 540（midToneBoost）→ `abs(oklchL - 0.52)` 语义等价但需校准阈值
  - 行 574/580（压力系数）→ 同上
- `usesDarkForeground` 双门槛保留：HSL（或 OKLCH L）+ WCAG 两个独立维度

### H.7 colorExtractionCacheVersion 版本机制 ✱

**结论**：存在 **真实的架构 bug**。版本号仅作用于 `dominantColorCache`，**不作用于** `ArtworkAssetStore` 快照缓存。OKLCH 迁移完成后，必须同时修复缓存键架构，否则旧 snapshot 会回流。

**字符串定义**（`ThemeStore.swift:74, 537-540`）：

```swift
private let colorExtractionCacheVersion = "semantic-near-mono-v2"

private func makeCacheKey(artworkIdentity: String?, checksum: UInt64) -> String? {
    guard let artworkIdentity, checksum != 0 else { return nil }
    return "\(colorExtractionCacheVersion)-\(artworkIdentity)-\(checksum)"
}
```

**缓存架构图**：

```typescript
ThemeStore.dominantColorCache (NSCache)
    key:   "semantic-near-mono-v2-{artworkIdentity}-{checksum}"
    value: (color: NSColor, analysis: ArtworkColorAnalysis)
    bump version 后 → 旧键失效 ✓

ArtworkAssetStore.cache (NSCache)
    key:   "{trackID}-{checksum}"  ← 无版本前缀 ✱
    value: ArtworkAssetSnapshot { dominantColor, accentColor, palette,
                                  richPalette, averageColor, ... }
    bump version 后 → 旧 snapshot 继续返回 ✗
```

**ThemeStore.swift:242-244** 显示即使 ThemeStore 主缓存键失效，代码仍会尝试从 ArtworkAssetStore 获取 `averageColor`：

```swift
averageColorCache = await ArtworkAssetStore.shared
    .get(trackID: assetTrackID, artworkChecksum: checksum)?
    .averageColor
```

**对第 1 轮判断的修正**：

- 第 1 轮疑问"如何与 git 联动" → **修正问题方向**：实际问题不是与 git 联动，而是**版本号覆盖不完整**
- bump 字符串本身有效，但只能失效 `dominantColorCache` 一半；`ArtworkAssetStore` 完全绕开

**OKLCH 迁移影响**：

- **必须**在迁移过程中升级缓存键架构
- 两种解决方案：
  1. **方案 A**：在 `ArtworkAssetStore.cacheKey` 拼接 `colorExtractionCacheVersion`
  2. **方案 B**：`ArtworkAssetSnapshot` 结构体新增 `cacheVersion: String` 字段，查询时校验

⚠ 这是 **本次调查发现的最重要的架构 bug**，不仅影响 OKLCH 迁移，平时任何调色逻辑变更都可能被旧 snapshot 静默覆盖。

### H.8 Quick → Full 两阶段视觉闪变 ✱

**结论**：**不是离散跳变，而是渐进精化**。Quick 阶段不构造完整 SemanticPalette（analysis 仍为 `.neutralFallback`），用户看到的只是"先有 baseColor，再有派生色"。

**Quick vs Extracted 字段写入对比**：

| 字段                       | quick 阶段                                                        | extracted 阶段                                               |
| ------------------------ | --------------------------------------------------------------- | ---------------------------------------------------------- |
| `rawDominantColor`       | ✓ 写入（18px 快样本）                                                  | ✓ 写入（64px full）                                            |
| `analysis`               | ❌ **不变（仍为** `.neutralFallback`**）**                        | ✓ 写入（48-bucket 完整分析）                                       |
| `hasArtworkThemeColor`   | ✓ 改为 true                                                       | ✓ 改为 true                                                  |
| `usesFallbackThemeColor` | ✓ 改为 false                                                      | ✓ 改为 false                                                 |
| `@Published` 字段更新        | baseColor, accentColor, **semanticPalette（基于 neutralFallback）** | baseColor, accentColor, **semanticPalette（基于真实 analysis）** |

**两次 refreshPalette 调用都包在** `withAnimation(.easeInOut(duration: 0.20))`（ThemeStore.swift:393）

**判定**：

- 0ms：用户看到 quick baseColor（18px 快样本）+ 基于 neutralFallback 的中性派生色
- 0-200ms：第二次 refresh 触发，SwiftUI 中断第一次动画，启动新动画
- 用户看到的是 "快色 baseColor → 完整派生色"的 0.20s 缓动过渡
- **如果 quick 与 extracted 在 HSL 空间差异 > 0.15**（hue 0.1→0.35 或 sat 0.10→0.45），可被察觉

**对第 1 轮判断的修正**：

- 第 1 轮判断"可能跳变" → **修正为渐进精化**
- 不是"突然变化"，而是 200ms 动画内的"颜色调整"
- 缓存命中时不产生两阶段；快速切歌由 token 失效保证不撞色

**OKLCH 迁移影响**：

- OKLCH 派色计算速度可能略低于 HSL，可能让 extracted 阶段延迟 50-100ms
- 但 OKLCH 颜色空间在感知上更线性，"颜色调整"的动画过渡反而更平滑
- 总体迁移不会加重闪变
- 建议在迁移过程中观察 `refreshPalette` 实际耗时

***

## I. 最终结论：OKLCH 迁移路线是否需要调整

经过 2 轮调查与定点核查，**第 1 轮提出的迁移路线大体保持，但有 4 处必须调整**。

### I.1 路线确认（无需修改）

- 三层架构（ColorMath → SemanticPalette → ThemeStore）的迁移顺序正确
- LED 作为 OKLCH 范例与孤岛保持
- HSL/RGB 在图像采样（`ArtworkColorExtractor.analyze`）保留
- WCAG luminance 在文本对比度判定保留
- CSS `mix-blend-mode` / `filter` 保留
- A 类固定色（玻璃描边、悬停白、旋转光晕）保留
- 30+ magic number 在迁移前 token 化

### I.2 必要调整（4 项）

**调整 1：第 0 阶段新增"架构清理"**

第 0 阶段必须先做架构清理，再开始 OKLCH 工作，避免迁移期把死代码也一起翻译：

- 清理 `--amll-shadow`（已是 A/B 测试后的明确弃用）
- 清理 `--amll-bg` 与 `--amll-accent`（Web 不消费的死字段）
- 修复 `MiniPlayerSpectrumView` 0.7 灰 fallback 与全局 fallback 不一致
- 修复 `ClassicLEDSkin` 阴影与 `FullscreenCoverGradient` 箭头两个 B 类潜在 bug
- 评估 `headerSemanticPalette` 是否要继续生成（14 个字段无消费）

**调整 2：第 2 阶段必须同时修复缓存版本号架构**

这是本次调查发现的 **最严重架构 bug**：

- `colorExtractionCacheVersion` 仅作用于 `dominantColorCache`，不作用于 `ArtworkAssetStore` snapshot 缓存
- 若不修复，OKLCH 迁移完成后旧 snapshot 会回流，导致部分曲目颜色仍是旧算法
- 必须在 `ArtworkAssetStore.cacheKey` 拼接版本号或在 snapshot 内嵌 cacheVersion 校验

**调整 3：**`usesDarkForeground` **双门槛设计需写入迁移规范**

第 1 轮把这个看作"混用嫌疑"，第 2 轮确认是 **协作设计**：

- HSL 用于品味层（美学决策）
- WCAG 用于合规层（无障碍）
- 迁移后必须保留 WCAG，可换 HSL 为 OKLCH L
- 不是减少指标，是替换其中一个

**调整 4：第 5 阶段新增** `FullscreenCoverBlurBlendProfile` **阈值评估**

阈值 0.72 是基于 HSL lightness 的二分判定：

- 短期保留 HSL（精度够用）
- 长期建议改 OKLCH L（约等价 0.56）或 WCAG luminance
- 在歌词迁移时一并评估

### I.3 第 1 轮 → 第 2 轮的关键修正汇总

| 序号 | 第 1 轮判断                                    | 第 2 轮修正                                                                                        |
| -- | ------------------------------------------ | ---------------------------------------------------------------------------------------------- |
| 1  | `ambientSurface` 可能冗余                      | **必须迁移**，是 Home 全屏背景底色                                                                         |
| 2  | `headerSemanticPalette` 仅 globalAccent 被消费 | **整体未消费**；其他 SemanticPalette 字段有消费，但通过 `ThemeStore.semanticPalette` 而非 `headerSemanticPalette` |
| 3  | `shadowColor` 可能死代码                        | **确认死代码**；新发现 `--amll-bg` / `--amll-accent` 也是死字段                                              |
| 4  | MiniPlayer Spectrum 可能颜色滞后                 | **不是 bug**，外层 SwiftUI 保证刷新                                                                     |
| 5  | CoverBlur profile 基于 `brightnessComponent` | **修正为 HSL lightness > 0.72**                                                                   |
| 6  | textPalette 混用 WCAG 与 HSL 嫌疑               | **协作设计，非历史混用**；OKLCH 后必须并存                                                                     |
| 7  | cacheVersion 缺少 git 联动                     | **真正问题是** `ArtworkAssetStore` **缓存绕过版本号**                                            |
| 8  | quick→full 可能闪变                            | **修正为渐进精化**；quick 阶段不构造独立 SemanticPalette                                                      |

### I.4 仍需观察的不确定点

- ⚠ `softShoulder` 仅在浅色 accent 天花板使用，其他都是硬 clamp — 是设计选择还是历史一致性问题？建议在 token 化后评估推广
- ⚠ `MiniPlayerSpectrumView` 与 `LedMeterView` 的 colorScheme 监听模式不同（参数传递 vs `@Environment`）— 是否应统一架构
- ⚠ Hero / Header / ThemeStore 三套 `SemanticPaletteFactory.make` 副本对同一封面会产生略不同派生色 — 当前是正当并行（artwork 不同），但未来如果有"hero 显示当前播放"的需求会暴露此分歧
- ⚠ AccentColor.colorset 资源在代码中似乎未被直接读取，仅 AppSettings.accentColorHex 默认 #E6C799 真正生效 — Asset 的作用域需要核实

> **注**：I 节是 R2 完成时的迁移路线。R3 在 J–M 中对其中"小面积高彩、Ultra Dark、忠实度、Spectrum / Home Shapes / 歌词决策位置"等做了关键修正与方向扩展，请以 M 节为最终纲领。

***

## J. R3 深度逆向：艺术取色决策引擎内部机制

R3 重点回答"前 2 轮报告未查透"的 6 类问题，并修正若干此前的笼统结论。所有结论代码行号有据。

### J.1 小面积高显著色机制：直接消费端为 0，但通过加权平均与饱和加分仍间接进入歌词（R4 修订）

> ✱ **R4 修订**：R3 原文给出的"派色完全丢失 / 消费端为 0"过于绝对。R4 专项追踪歌词颜色完整反向数据流后，把 J.1 拆为两半 — 直接消费层与间接渗透层 — 并修正 R3 的笼统结论。

#### J.1.a 采样与直接消费层（R3 原结论保留）

**代码事实**：

| 位置                                    | 内容                                                                                                        |
| ------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `ArtworkColorExtractor.swift:270-271` | `minimumBucketWeight = total × 0.030`、`noiseFloor = total × 0.012`                                        |
| `ArtworkColorExtractor.swift:293`     | `areaShare<0.030 && bucketSat>0.55` 直接弃用（水印 / 标签噪声）                                                       |
| `ArtworkColorExtractor.swift:276-279` | `isNearMono` 触发条件：`avgSat<0.14 \|\| vividness<0.10 \|\| (isExtremeTone && avgSat<0.18 && vividness<0.16)` |
| `ArtworkColorExtractor.swift:298-308` | `isNearMono` 下 3 档高彩小面积过滤（最严`sat>0.22 && area<0.18`）                                                      |
| `ArtworkColorExtractor.swift:478-489` | `richPalette` 第二轮显式补救：`saturationValue ≥ 0.45` 候选填补空位                                                     |
| `SemanticPalette.swift:99`            | `optimizedAccent` 直接读 `analysis.dominantColor`，**不读 topPalette / richPalette**                            |

**直接消费层结论**：

- `richPalette` 的字面 UI 消费端 **为 0**：没有任何角色色直接读它，`optimizedAccent` 锁死 `dominantColor`。
- `dominantColor` 是 48 桶面积加权最高桶质心，**小面积单独高显著色无法成为 dominantColor**。R3 三场景表（95/5 黑黄、90/10 蓝绿橙、80/20 暗红）这一点仍成立。
- 因此 **以 accent 链路独走的 UI（频谱主轴、Home Shapes、Library Header、Hero、MiniPlayer 控件）小面积色现身概率极低** — ☆ K.1 / K.3 仍需成立。

#### J.1.b 间接渗透层：歌词颜色完整反向数据流（R4 新增）

**核心代码事实**：歌词四个角色色的真实数据源（`SemanticPalette.swift:270-296`）

| 角色色                           | 直接公式                                          | 真实底层字段                                                | 是否携带小面积色信号               |
| ----------------------------- | --------------------------------------------- | ----------------------------------------------------- | ------------------------- |
| `windowLyricActive`           | `adjustedAccent(from: averageColor)`          | `analysis.averageColor`（像素加权 RGB 平均）                  | ✓ 通过加权平均色相                |
| `windowLyricInactive`         | `windowLyricActive × 0.35 alpha`              | 同上                                                    | ✓ 同上                      |
| `fullscreenLyricBase`         | 条件分支                                          | 高彩高自信 → `dominantColor`<br>否则 → `bestTextSourceColor` | ✓✓ bestTextSourceColor 路径 |
| `fullscreenLyricInactiveBase` | 直接                                            | `analysis.averageColor`                               | ✓ 通过加权平均色相                |

**关键反查 1：`averageColor` 携带小面积色信号**

`ArtworkColorAnalysis.swift:241-246` 定义：
```swift
let averageColor = NSColor(
    deviceRed: weightedR / totalWeight,
    green:  weightedG / totalWeight,
    blue:   weightedB / totalWeight,
    alpha:  1
)
```

像素权重在 `ArtworkColorExtractor.swift:117-122` 由 `areaWeight × toneWeight × satWeight` 构成，**纯黑/纯白被 `sat<0.04 → weight *= 0.82` 降权 18%**。这意味着：

- 95% 纯黑 + 5% 鲜黄场景：纯黑实效权重 0.95×0.685 ≈ 0.651，黄色实效 0.05×1.013 ≈ 0.051。`averageColor = (0.073, 0.066, 0)` — **极暗 RGB，但色相是黄棕**。
- `adjustedAccent` 在 dark mode 下钳制 `sat∈[0.08, 0.22]`、`brightness∈[0.98, 1.0]`，但 **HUE 完全不变**（`ArtworkColorExtractor.swift:78-85`）。
- 结果：**windowLyric 看起来仍是接近纯白，但带一抹冷暖偏移** — 即"虽然只有 5%，但歌词颜色里能感觉到"。

**关键反查 2：`bestTextSourceColor` 显式偏好高饱和**

`ArtworkColorExtractor.swift:786` 评分公式：
```swift
let score = bucket.weight * (0.82 + saturationValue(of: color) * 0.36)
```

这是 **饱和度加分系统**。50% 灰 (sat≈0.05) vs 50% 彩 (sat≈0.85) 时：
- 灰：0.50 × 0.90 × 0.838 = 0.377
- 彩：0.50 × 1.07 × 1.126 = 0.603 → 彩色胜出

且 `bucket.weight > totalWeight * 0.01` 的桶都参评（仅 1% 门槛，比 palette 的 3% 噪声门槛宽松三倍）。`bestTextSourceColor` 会在 `fullscreenLyricBase` 的低彩 fallback 分支中被直接消费。

**关键反查 3：`fullscreenLyricBase` 的条件分支放行小面积色**

`SemanticPalette.swift:284-291`：
```swift
if analysis.colorfulness >= 0.20 && analysis.dominantHueConfidence >= 0.20 {
    return analysis.dominantColor
}
return analysis.bestTextSourceColor
```

- 当封面是 30% 蓝紫 + 70% 暗灰类（colorfulness ≈ 0.20-0.30），`dominantColor` 进入，蓝紫的色相直接出现在全屏当前行歌词。
- 当封面是 5% 鲜黄 + 95% 黑（colorfulness ≈ 0.05），fallback 到 `bestTextSourceColor`，黑桶仍以面积压制黄桶，无小面积色。
- 但当封面是 20% 红 + 80% 中灰（colorfulness ≈ 0.20，但中灰不被 sat<0.04 降权），red 在 textSource 评分中以满 satBonus 反超灰：0.20×1.07×1.126=0.241 vs 0.80×0.94×0.838=0.629，灰仍胜，但只要红比例升到 ~30% 就会反超。这条边界确实让 **小到中面积、强饱和、中亮度** 的副色进入歌词。

**间接渗透层结论**：

- 歌词 4 个角色色都对 averageColor / bestTextSourceColor / dominantColor 敏感，**这三个字段都携带不同程度的小面积色信号**：
  - `averageColor`：纯加权平均，小面积色的色相按面积比例线性参与（极强的衰减，但保留方向）。
  - `bestTextSourceColor`：satBonus = 0.36，让面积 30-50% 的强饱和副色能反超大面积低饱和主色。
  - `dominantColor` 在 `colorfulness ≥ 0.20 && confidence ≥ 0.20` 时进入全屏歌词当前行。
- **用户观察到"歌词中能看到小面积高显著色"是真实的**，路径正是 averageColor 色相 + textSource satBonus。
- 但需要强调：
  - 这种渗透是 **被强烈衰减的** — 在 dark mode 下 sat 钳到 [0.08, 0.22]，几乎只剩"色温感"。
  - 它发生在 **歌词链路** 而不是 accent 链路 — 频谱、Home Shapes、Library Header 仍然不消费 richPalette。

#### J.1.c 修正原 R3 结论

- ✱ R3 原文"派色完全丢失" → 修订为 **"accent 链路完全丢失、歌词链路通过 averageColor / bestTextSourceColor 仍间接渗透"**。
- ✱ R3 原文"消费端为 0" → 修订为 **"richPalette 字面消费端为 0；但小面积色相通过 averageColor 渠道间接到达歌词"**。
- ☆ K.1（频谱真实多色）、☆ K.3（Home Shapes 真实多色）的结论 **依然成立**，因为它们针对的是 **accent 链路独走的 UI**，而非歌词链路。
- ☆ K.6（歌词决策上收 Swift）的优先级 **不变**，因为现状是"间接渗透"，不是"主动选择"，未来仍应有意识地决定歌词颜色规则。

### J.2 Ultra Dark 与 Near Monochrome：两个正交维度，主链路无独立 Ultra Dark 分支（R4 修订）

> ✱ **R4 修订**：R3 原文"系统级真正承担极暗保护的是 nearMonochromeAccent"在概念上把两个独立维度并成一个。R4 重新分离 — Ultra Dark 处理"封面整体极暗 / 夜色感 / 明度保真"，Near Monochrome 处理"封面缺乏可信色相 / 接近灰阶黑白 / 防止假粉假紫"。两者在代码中已是独立判定，但主链路缺少独立的 Ultra Dark 分支。

#### J.2.a 概念定义（必须分离建模）

| 维度                  | 关注问题                          | 输入指标                                              | 期望行为                                       |
| ------------------- | ----------------------------- | ------------------------------------------------- | ------------------------------------------ |
| **Ultra Dark**      | 整体极暗 / 夜色感 / 明度保真             | luma、areaDominantB、avgHslLightness（**亮度类**指标）     | accent / 文本允许 L 仍偏暗，仅保证 WCAG 对比度，不强制提亮     |
| **Near Monochrome** | 缺乏可信色相 / 接近灰阶黑白 / 防止假粉假紫     | colorfulness、avgSat、largestHighSatArea（**色度类**指标） | 注入伪 hue（0.10 暖 / 0.58 冷）、严格收紧 sat 上限、防止假色 |

四个角点：

| (UltraDark, NearMono) | 典型封面                | 期望颜色策略                                |
| --------------------- | ------------------- | ------------------------------------- |
| (T, T)                | 极暗黑白盘、夜空灰阶          | 中性 + 极低 sat + 暗 L（但 WCAG 合规）          |
| **(T, F)**            | **极暗鲜彩封面**（深夜蓝、暗酒红） | **保留色相、保留暗 L、仅做 WCAG 钳制 — 当前缺失的关键分支** |
| (F, T)                | 中亮纯白/纯灰封面、素描        | 伪 hue 注入 + 收紧 sat                     |
| (F, F)                | 正常彩色封面              | 普通 optimizedAccent 路径                 |

#### J.2.b 代码事实：两者在判定上已是独立的

**Ultra Dark 字面判定（亮度主导）**：

| 位置                                                             | 判定条件                                                                                | 涉及色度指标？                |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------- | ---------------------- |
| `BKArtBackgroundView.swift:296-300` `isUltraDarkPalette`       | `(luma < 0.36 && areaDominantB < 0.30) \|\| (luma < 0.30 && grayScore > 0.70)`      | 第一支不涉及，**允许"极暗彩色"通过**  |
| `BKArtBackgroundView.swift:1107-1111` `updateUltraDarkOverlay` | `imageCoverLuma < 0.22`                                                             | 不涉及，纯亮度                |
| `BKArtBackgroundView.swift:1708-1713` `isUltraDarkCover`       | 同 isUltraDarkPalette 公式                                                             | 同上                     |
| `FullscreenPlayerView.swift:3143, 3458-3477`                   | `lockedFullscreenLyricsUltraDark = bkController.isUltraDarkActive`                  | 间接，沿用 BKArt 判定         |

**Near Monochrome 字面判定（色度主导）**：

| 位置                                       | 判定条件                                                                                                                                                                                                                                                                | 涉及亮度指标？                                |
| ---------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `ArtworkColorAnalysis.swift:230` `isMono` | `colorfulness < 0.04 && avgSat < 0.10`                                                                                                                                                                                                                              | 不涉及                                    |
| `ArtworkColorAnalysis.swift:233-238` `isEffectivelyMonochrome` 5 条 OR | 1. `isMono`<br>2. `colorfulness<0.10 && avgSat<0.16 && largestHighSat<0.12`<br>3. `avgSat<0.105 && colorfulness<0.14 && largestHighSat<0.16`<br>4. `isExtremeTone && avgSat<0.18 && colorfulness<0.16 && !hasStrong`<br>5. `dominantSat<0.18 && colorfulness<0.16 && avgSat<0.18` | **第 4 支引入 isExtremeTone（亮度）作为加权耦合维度** |
| `SemanticPalette.swift:95-96 → 186-225` `nearMonochromeAccent` | 由 `isEffectivelyMonochrome` 触发                                                                                                                                                                                                                                       | 内部 L 钳制 [0.66, 0.74] 是 UI 可读性，不是分类输入   |

**核心代码事实**：

- ✓ `isUltraDarkPalette` 仅出现在 BKArtBackground + Fullscreen lyrics，**不进入 SemanticPaletteFactory 主链路**。
- ✓ `isEffectivelyMonochrome` 进入主链路，但它是 **色度分类器**，不是"极暗保护器"。
- ✓ 两者代码上 **已经独立**：BKArt 的 UltraDark 第一支 `luma<0.36 && areaDominantB<0.30` 允许"极暗彩色"通过；isEffectivelyMonochrome 不直接读 luma。
- ✗ **但 isEffectivelyMonochrome 第 4 支 `isExtremeTone && avgSat<0.18 && colorfulness<0.16 && !hasStrong` 把亮度耦合进了色度分类**，这是唯一的潜在边界混淆点（详见 J.2.d）。

#### J.2.c 主链路"极暗 accent 被提亮"的真实归因

**修正 R3 原文的归因错误**：R3 说"系统级承担极暗保护的是 nearMonochromeAccent"。正确说法是：

`SemanticPalette.swift:118-128` 定义 `darkMinL` — 这是 **dark scheme 下任何 accent 的通用亮度地板**，hue-aware：

```swift
let darkMinL: CGFloat = {
    switch h {
    case 0.10..<0.18: return 0.66   // yellow / orange
    case 0.18..<0.42: return 0.70   // green
    case 0.42..<0.72: return 0.74   // cyan / blue
    case 0.72..<0.85: return 0.76   // violet
    default:           return 0.72  // red / magenta / pink
    }
}()
```

这条规则 **应用于所有 dark scheme accent**，包括极暗彩色封面（如深夜蓝）。结果就是：

- 95% 深夜蓝（luma~0.10，sat~0.45，colorfulness~0.20）封面：
  - `isEffectivelyMonochrome` 大概率为 false（avgSat 0.45 > 任何 OR 分支阈值）
  - 走 `optimizedAccent` 正常路径
  - hue 落在 0.65 蓝带，dark scheme → `l = max(l, 0.74)` → accent L 被强提到 0.74
  - **"极暗夜色感"丢失，不是 nearMonochromeAccent 的副作用，而是 darkMinL 的副作用**。

**修正后归因**：

- nearMonochromeAccent 仅在 isEffectivelyMonochrome=true 时触发，是 **近黑白防假色机制**。其 L≥0.66 钳制是为了"灰图当 accent 用时不要变成深灰难辨"。
- **极暗彩色封面 accent 被提亮的真实原因是 `darkMinL` 这条 UI 可读性地板**。
- 真正的"系统级 Ultra Dark 保真分支"在主链路中 **不存在**：既没有"if Ultra Dark, relax darkMinL"，也没有任何字段说"允许 accent 留在暗调"。

#### J.2.d 极暗彩色封面被 nearMono 误接管的风险

`isEffectivelyMonochrome` 第 4 支：

```swift
(isExtremeTone && avgSat < 0.18 && colorfulness < 0.16 && !hasStrong)
```

`isExtremeTone = avgHslL < 0.18 || avgHslL > 0.86`。

**误接管边界**：当极暗封面同时满足 `avgSat < 0.18` 与 `colorfulness < 0.16`，无论它的"主色相是否真实存在"，都会被判为 mono。举例：

- 90% 极深紫（luma=0.08，单像素 sat=0.40 但平均 sat 受暗度拖低到 0.17）+ 10% 中灰 → avgSat 0.16，colorfulness 0.12，hasStrong=false（因为 sat>0.50 的桶面积可能<18%）→ **判 mono，accent 被强行落入 [0.66,0.74] 灰蓝带**。
- 真实色相（深紫）丢失，被替换成 nearMonoAccent 的 0.58 冷或 average.h（如 average.h 凑巧偏紫则保留方向，但 sat 已严格收紧到 ≤0.14）。

**结论**：极暗 + 中低饱和 的彩色封面 **确实有被 nearMono 误接管的风险**，这是色度分类器与亮度耦合不当造成的，应在颜色系统 2.0 中拆开。

#### J.2.e 修正原 R3 结论

- ✱ R3 原文 **"系统级真正承担'极暗保护'功能的是 nearMonochromeAccent"** → 修订为 **"主链路没有独立的 Ultra Dark 分支；nearMonochromeAccent 是色度分类器（近黑白防假色），不是极暗保护机制；极暗 accent 被提亮源自 `darkMinL` 通用地板"**。
- ✱ R3 原文"nearMono 副作用是把极暗 accent 提到 L≥0.66" → 修订为 **"darkMinL 把所有 dark scheme accent 提到 L≥0.66~0.76（hue-aware）；nearMonoAccent 的 L≥0.66 是它自己内部的边界，与 darkMinL 是两条独立规则"**。
- ✱ R3 笼统的"两者关系" → 修订为 **"Ultra Dark 与 Near Monochrome 是两个正交维度，需分离建模；极暗彩色封面应允许 `UltraDark=T, NearMono=F`"**。
- 字面 `ultraDark` 路径（BKArt + Fullscreen 歌词）的盘点 **保持有效**。

### J.3 近黑白封面防假色机制：完整且严格

**代码事实**：

| 检测                      | 位置                                   | 阈值                                                                              |
| ----------------------- | ------------------------------------ | ------------------------------------------------------------------------------- |
| 严格单色                    | `ArtworkColorAnalysis.swift:230`     | `colorfulness<0.04 && avgSat<0.10`                                              |
| 极端亮度                    | `ArtworkColorAnalysis.swift:231`     | `avgHslL<0.18 \|\| avgHslL>0.86`                                                |
| 高彩仅噪声                   | `ArtworkColorAnalysis.swift:232`     | `largestHighSaturationAreaShare<0.12`                                           |
| isEffectivelyMonochrome | `ArtworkColorAnalysis.swift:233-238` | 5 个 OR 分支，覆盖 `colorfulness<0.10` / `avgSat<0.105` / `dominantSaturation<0.18` 等 |
| 伪 hue 注入                | `SemanticPalette.swift:191-199`      | avgSat<0.055 时：暗 → 0.58 冷 / 亮 → 0.10 暖                                          |
| 严格单色 sat ceiling        | `SemanticPalette.swift:206-208`      | strictMono：深 0.08 / 浅 0.07；非严格 mono：深 0.14 / 浅 0.12                             |
| sat floor               | `SemanticPalette.swift:211`          | 深 0.035 / 浅 0.025                                                               |
| lightness 范围            | `SemanticPalette.swift:217-223`      | 深 [0.66, 0.74] / 浅 [0.32, 0.42]                                                 |

**结论**：

- 机制 **完整**，灰图 → 0.58 冷蓝灰、近黑白 → 收到 sat≤0.08。
- **唯一可能漏掉的边界**：`avgSat ∈ [0.055, 0.105]` 且 hue 强烈但面积小的"近假色"封面，hasUsableAverageHue=true 时仍信任 average.h，可能造成微弱方向性偏移。设计上是有意（保留原图轻微色温），可不修。

### J.4 16 角色色的真实"忠实度"评分

R3 子代理基于代码事实给出每个角色的忠实度（0=完全 UI 主导，10=完全直通 artwork）：

| 角色                            | 忠实度 | 代码依据                                                                              | 倾向               |
| ----------------------------- | --- | --------------------------------------------------------------------------------- | ---------------- |
| `ambientSurface`              | 9   | `SemanticPalette.swift:232` 直通 `analysis.averageColor`                            | 强忠实              |
| `artBackgroundPrimary`        | 9   | `SemanticPalette.swift:239` 直通 `topPalette[0]`                                    | 强忠实              |
| `artBackgroundSecondary`      | 9   | `SemanticPalette.swift:246` 直通 `topPalette[1]`                                    | 强忠实              |
| `fullscreenLyricInactiveBase` | 9   | `SemanticPalette.swift:296` 直通 `averageColor`                                     | 强忠实              |
| `fullscreenLyricBase`         | 7   | `SemanticPalette.swift:284-291` 条件直通（高彩封面用 dominantColor）                         | 强忠实              |
| `globalAccent`                | 5–7 | `SemanticPalette.swift:99-184` 经 13 色相带 sat cap + 暖色卫士 + 低色彩安全网                   | UI 主导            |
| `uiAccentOnDark`              | 6   | 同上 + L≥0.66 强制                                                                    | UI 主导            |
| `uiAccentOnLight`             | 5   | 同上 + softShoulder + `L = min(l×0.78, 0.50)`                                       | UI 主导            |
| `coverGradientDominant`       | 6   | `SemanticPalette.swift:305-307` `s×0.92` + `L ∈ [0.22, 0.78]`                     | 中等               |
| `readableTextOnArtwork`       | 4   | `SemanticPalette.swift:250-264` sat 钳到 [0.10, 0.34]、L 固定 0.12 / 0.92              | UI 主导            |
| `windowLyricActive`           | 6   | `SemanticPalette.swift:274` 经 `adjustedAccent`：暗模式 S∈[0.08, 0.22]+B≥0.98；浅 L=0.22 | UI 主导            |
| `windowLyricInactive`         | 6   | windowLyricActive + 0.35 alpha                                                    | UI 主导            |
| `coverGradientText`           | 4   | sat 钳到 [0.18, 0.36]、L 固定 0.16 / 0.94                                              | UI 主导            |
| Home `ambientBaseColor`       | 2   | `HomeAmbientShapesBackground.swift:708-750` 深 sat×0.30, B×0.18；浅 sat×0.16         | 完全 UI 主导         |
| Home shapes palette           | 3   | `HomeAmbientShapesBackground.swift:775-843` ±18/24/38/46/68° hue 旋转构造 6 色环        | 完全 UI 主导         |
| LED centerColor               | 5   | `LEDColorResolver.swift` OKLCH chroma cap + 固定 L                                  | UI 主导（OKLCH 已迁移） |

**关键结论**：

- 背景类（ambient / artBackground / fullscreen inactive）**强忠实**，几乎直通。
- 交互类（accent 全家、文本、歌词）**UI 主导重整**，舒适度优先于忠实度。
- 装饰类（Home base、Home shapes）**完全 UI 主导**，与原图气质关系疏远 — 这是 ☆ K.3 要解决的核心问题。

### J.5 失真风险（基于代码逻辑的 5 类推演）

A. **高饱和封面被压温吞**（`SemanticPalette.swift:138-166`）：鲜红原 S=1.0 → softShoulder(1.02, 0.46, 0.10) ≈ 0.465；L=0.5 → min(0.5×0.78, 0.50) = 0.39。视觉上明显不如原色生动。

B. **极暗封面被强行提亮**（`SemanticPalette.swift:217-219`）：纯黑夜景（avgHslL=0.08）→ `lightness = clamp(0.66 + 0.81×0.08, 0.66, 0.74) ≈ 0.7248`。提亮 9 倍，完全失去"夜色"。

C. **极亮封面被强行压暗**（`SemanticPalette.swift:167, 221-222`）：白纸（avgHslL=0.95）→ 浅色 accent `L = min(0.95×0.78, 0.50) = 0.50`；单色浅色路径甚至下到 L=0.32。压暗到深灰。

D. **暖色色相被强行回正**（`SemanticPalette.swift:107-114`）：`avgHue ∈ [0.07, 0.20]` 时若 dominantHueConfidence ≥ 0.16 且 dominant 偏离 > 0.06，**强制 h = avg**。可能把"棕底 + 小面积粉花"封面强行重设为棕色 accent。

E. **冷暖色相约束不对称**：暖色色相卫士仅作用于 hue ∈ [0.07, 0.20]；冷色无对称约束。

### J.6 LED 中间档色彩层次不够明显（R3 新发现，回应用户隐忧）

**代码事实**（`LEDColorResolver.swift:302-329`）：

```swift
let l = baseLCH.l - 0.020 * oneMinusT + 0.010 * t   // L 总变化 0.03
let c = baseLCH.c * (0.94 + 0.06 * t)               // C 总变化 6%
let h = ColorMath.normalizedHue(baseLCH.h + hueShift(baseLCH.h) * oneMinusT)
```

深色基础 L ∈ [0.81, 0.86]；档位插值范围 [baseL - 0.020, baseL + 0.010]，**总变化 0.03，低于 OKLCH 感知 JND**。Chroma 变化 6% 同样小。

**质量评估**：

- L 变化过小，中间档位用户难以感知差异。
- C 仅 6% cap，在 chroma=0.066–0.155 范围下相对变化更小。
- H 的 hueShift 反而是三者中最显著的变化（per hue ±0.014）。

**改进方向（保留 OKLCH，但放大档位差异）**：

- 扩大 L 插值到 ±0.03 / 0.02（总变化 0.05）
- C 改用非线性提升 `0.94 + pow(t, 1.2) * 0.06`
- 详见 ☆ K.10（Tone Ladder）

### J.7 SemanticPaletteFactory 内部审美哲学（R3 整理的 9 条规则）

| # | 规则                                       | 类别       | 代码位置                                                      | OKLCH 后保留 / 重新表达                          |
| - | ---------------------------------------- | -------- | --------------------------------------------------------- | ----------------------------------------- |
| 1 | WCAG 7:1 对比度迭代                           | 合规       | `ArtworkColorExtractor.swift:795-830`                     | 保留（OKLCH 后 luminance 仍需 WCAG 数学）          |
| 2 | 深色 accent L≥0.66                         | 可读性      | `SemanticPalette.swift:131`                               | 保留，重新标定 OKLCH L 阈值                        |
| 3 | 13 色相带 S 上限                              | 审美       | `SemanticPalette.swift:138-159`                           | 保留，**逐色相重新测定 OKLCH C 上限**                 |
| 4 | 暖色色相卫士                                   | 历史补丁     | `SemanticPalette.swift:107-114`                           | **建议在 OKLCH 中重测必要性**（OKLCH hue 定义可能消除原问题） |
| 5 | 黑白伪 hue 0.58 / 0.10                      | 审美选择     | `SemanticPalette.swift:196, 198`                          | 保留语义，**OKLCH 中应表达为 chroma=0**（hue 数值无意义）  |
| 6 | softShoulder 软肩                          | 审美       | `SemanticPalette.swift:161-165 + ColorMath.swift:105-112` | 直接迁到 OKLCH C                              |
| 7 | 三层低彩保护                                   | 可读性 + 防伪 | `SemanticPalette.swift:173-181`                           | 保留三层结构，重新标定 chroma 阈值                     |
| 8 | 色相感知最小明度（黄 0.66 / 绿 0.70 / 蓝紫 0.74-0.76） | 审美       | `SemanticPalette.swift:121-125`                           | **关键**：OKLCH L 与 HSL L 非线性，必须逐色相重测        |
| 9 | Hero / Header / LED 各自独立的审美子系统           | 审美       | 多文件                                                       | 保留独立性，但 LED 是参考实现                         |

详见 ☆ M.1：迁移期 token 化时必须先做这 9 条规则的 OKLCH 等价校准。

***

## ☆ K. 颜色系统 2.0 方向性结论（R3 新增）

以下所有结论以 ☆ 标注，表示"系统目前还不是这样，是未来颜色系统重构方向"，与"代码事实"严格分开。

### ☆ K.1 频谱颜色源应从单色派生转向真实封面多色优先

**当前状态（代码事实）**：

- `MiniPlayerSpectrumView` 接受 `accentColor` + `artworkColors` 数组参数（`MiniPlayerSpectrumView.swift:110, 134-144`）。
- `artworkColors` 数组来源未追踪到上层（待 R4 补查），但即便有 palette 数组，spectrum 内部仍以单 accent 为主轴。
- LED 已 OKLCH 化但仍是"单源色 + 浅深分支 + 呼吸动画"，详见 J.6。

**方向性结论**：

1. **频谱**应优先消费 `analysis.richPalette`（或未来重构出的 `artworkDisplayPalette`），让封面真实存在的多种显著色直接驱动各频段。
2. 仅当封面 richPalette 候选不足（如黑白封面、色差过小）时，才启用"补色 / 扩色 fallback"，由当前 `optimizedAccent` 的色相旋转规则担任。
3. **LED 保持单色主轴 + 互补呼吸灯**是合理的"仪表器件语言"。LED 的中间档分级问题（J.6）通过 ☆ K.10 Tone Ladder 解决，不改其单色架构。
4. 后处理统一在 Swift 侧完成：明度调节、彩度钳制、深浅模式适配。Web/CSS 不参与频谱颜色决策。

**影响**：频谱体验从"主题色派生的两三色渐变"升级为"真实封面的多色发光";LED 中间档色彩科学变化更明显。

### ☆ K.2 Ultra Dark 与 Near Monochrome 作为两个正交维度进入决策引擎（R4 重写）

> ✱ **R4 修订**：原 K.2 把"极暗保护"归因到 nearMonochromeAccent 的副作用。J.2 的 R4 重写已分离两个维度，此处把方向性结论改写为"两个正交维度共同决策"。

**当前状态**（J.2 R4 修订后的事实）：

- BKArtBackground 已有独立 `isUltraDarkPalette`（亮度类指标，luma/areaDominantB/grayScore），但不进入主链路。
- ArtworkColorAnalysis 已有独立 `isEffectivelyMonochrome`（色度类指标，colorfulness/avgSat），但第 4 支 OR (`isExtremeTone && ...`) 把亮度耦合进色度分类，造成"极暗中低饱和彩色封面被 nearMono 误接管"的边界风险（J.2.d）。
- 主链路 accent 被提亮的真实原因是 `darkMinL` 通用地板，不是 nearMonoAccent。

**方向性结论**：

1. **概念分离原则（最重要）**：
   - `UltraDark` 仅描述"封面整体极暗 / 夜色感 / 明度保真"问题 — 由亮度类指标决定。
   - `NearMonochrome` 仅描述"封面缺乏可信色相 / 接近灰阶黑白 / 防止假粉假紫"问题 — 由色度类指标决定。
   - 两者必须可以同时为真、同时为假、或单独为真。

2. **抽取到 ArtworkReadabilityProfile**（☆ K.7）作为两个独立 bool / 等级字段：
   - `readability.ultraDark: Bool`（或 `darknessTier: enum {normal, dark, ultraDark}`）输入为 OKLCH L + WCAG relativeLuminance。
   - `readability.nearMonochrome: Bool`（或 `chromaConfidence: enum`）输入为 OKLCH C + colorfulness。
   - 两条字段相互独立，分别由 SemanticPaletteFactory 在不同决策点消费。

3. **重整 isEffectivelyMonochrome 第 4 支**：当前 `isExtremeTone && avgSat<0.18` 把亮度耦合进色度分类，应拆为：
   - 单纯色度分类：仅保留 avgSat / colorfulness / largestHighSat 维度。
   - 极暗 + 中低饱和彩色封面（如深紫、夜蓝）应被分到 `(UltraDark=T, NearMono=F)` 而非 `(F, T)` 或 `(T, T)`。

4. **主链路 accent 派色按四个角点分支**：

| 角点      | 现状 accent                  | 目标 accent                            |
| ------- | -------------------------- | ------------------------------------ |
| (T, T)  | nearMonoAccent (L ∈ 0.66~0.74，中性 hue) | 维持现状（极暗黑白盘本就该 neutral + 浅 L 才能读出）   |
| **(T, F)** | **darkMinL 强提到 0.66~0.76**（J.2.c 已确认） | **新分支：保留原色相、L 下沉到 0.50~0.58，仅做 WCAG 钳制** |
| (F, T)  | nearMonoAccent (L ∈ 0.66~0.74) | 维持现状                                 |
| (F, F)  | optimizedAccent 正常路径       | 维持现状                                 |

5. **可读性边界**继续由 WCAG 对比度迭代守护，不靠 L 阈值兜底 — 这样 (T, F) 分支才能真的把 L 放低而不破坏可读性。

6. **命名澄清**：未来重构中，nearMonochromeAccent 应严格命名为 **"近黑白防假色机制"**（anti-fake-color），不再让"极暗保护"这一概念与之挂钩。"极暗保护"应有自己的独立分支与命名（如 `ultraDarkAccentDarkScheme`）。

### ☆ K.3 Home Shapes / Art BK 应改为"真实封面多色分发"

**当前状态**：`HomeAmbientShapesBackground.swift:775-843` 的 6 色 shapes palette 是 ±18/24/38/46/68° hue 旋转 + sat/L 钳制构造的，**与封面真实色无对应**。Art BK 同理。

**方向性结论**：

1. 优先从封面真实存在的多色候选（richPalette 或重构后的 `artworkDisplayPalette`）中挑色。
2. 这些颜色经过"背景化处理"：降低侵略性、深浅模式适配、控制 chroma 不压过内容。
3. **扩色 fallback 仅作用于条件**：候选色全部过于接近、色差不足、几乎只剩一个可用色、或极端低彩。这时复用 K.1 的"克制补色规则"。
4. 系统从"单色 accent 派生"转向"真实 artwork palette 分发"。
5. **会影响**：Home Shapes、Art BK 背景图形系统，以及未来可能加入的其他装饰图形。

### ☆ K.4 Home Hero 颜色分叉是正当的，不应改成"跟随当前播放"

**当前状态**：`HomeHeroView.heroPalette` 与 `ThemeStore.semanticPalette` 是两套独立的 `SemanticPaletteFactory.make` 副本，前者基于 Hero 卡片展示曲目的 artwork，后者基于当前播放曲目。

**方向性结论**：

1. Hero 展示哪首歌就用那首歌的 artwork 分析，是**正当分叉**，不应改为跟随当前播放。
2. 但需要关注 Hero 自身颜色 与 Home 全页背景 / shapes 当前播放色之间的视觉协调（视觉测试，不通过代码强制）。
3. ☆ K.3 落地后，Home Shapes 改为真实多色分发，Hero 与 Home 整体的色相关系会更"自然差异化"，而不是"统一主题色但卡片是另一首"。

### ☆ K.5 MiniPlayer 控件色应升级为正式语义色

**当前状态**：`MiniPlayer` 控件 icon / 进度条 / track 在 View 层做 HSL 二次修正（深 L≥0.70，浅 L≤0.45）。视觉目标合理，但 **结构上散在 View 中**。

**方向性结论**：

1. 在 SemanticPalette 新增正式角色：`controlAccentOnDark` / `controlAccentOnLight` / `interactiveControlPrimary` / `progressFill` / `progressTrack`。
2. View 层只读语义角色色，不做二次 HSL 修正。
3. **视觉行为完全保留**，只是把派色规则从 View 移到 SemanticPaletteFactory。
4. 这是 R3 报告中"局部分叉应收敛"的典型案例。

### ☆ K.6 歌词颜色决策应统一到 Swift 侧，Web 只保留渲染

**当前状态**：

- Swift 注入 6 个 CSS 变量到 WebView，其中 `--amll-shadow` / `--amll-bg` / `--amll-accent` 是死字段（R2 H.3）。
- `--amll-cb-sub-glow: rgb(200,200,200)` 在 CSS 中硬编码（B 类技术债，R2 C.3）。
- Cover Blur main glow 在 CSS 中硬编码白 / 黑（A 类设计基础）。
- Cover Blur profile 切换基于 themeColor HSL > 0.72（R2 H.5）。

**方向性结论**：

1. **应统一到 Swift 侧的**：
   - 主歌词色、副歌词色、active/inactive 角色色
   - glow 色（包括 cover blur sub glow）
   - cover blur 中需要的所有颜色输入
   - 不同皮肤对应的歌词配色策略
   - 背景明暗判定（由 ☆ K.7 Readability Profile 统一计算）所引出的颜色决策
2. **Web/CSS 层保留**：
   - `mix-blend-mode: plus-lighter / plus-darker`
   - `opacity` 参与层级（仅 Apple 风格皮肤，详见 ☆ K.8）
   - `text-shadow` / `filter: drop-shadow` 结构（颜色来自 Swift，filter 行为留在 CSS）
   - AMLL 渲染动画
3. **窗口歌词**当前观感良好，结构优化时不应破坏视觉结果。可以做收敛，但不要因为架构洁癖推翻观感。

### ☆ K.7 引入"Artwork Readability Profile"统一封面明暗判定

**当前状态**：以下多个模块各自做类似事情：

- Home Hero UI 文字 / 图标的可读性
- 全屏 MiniPlayer 文字 / 图标
- Cover Gradient 歌词皮肤 lighter / darker profile 切换（HSL L > 0.72）
- `usesDarkForeground` 双门槛（HSL + WCAG）
- BKArtBackground 的 `isUltraDarkPalette` / `isUltraDarkCover`

**方向性结论**：

1. 抽象为统一的 `ArtworkReadabilityProfile`（或同类概念）。
2. 该 Profile 集中输出：
   - 背景属于 bright / dark / mixed 哪一类
   - 推荐 light foreground 还是 dark foreground（沿用 R2 H.6 的协作设计：WCAG 合规 + HSL/OKLCH L 美学）
   - foreground primary / secondary / icon 的建议色
   - cover blur blend profile 是否 lighter / darker
   - 是否触发 ☆ K.2 的"系统级 Ultra Dark"分支
   - 必要时提供更细的背景可读性等级（如 5 级）
3. 输入指标固定为 WCAG relativeLuminance + OKLCH L + colorfulness，避免 HSL/HSB 多套指标并存。
4. 当前散在 `FullscreenPlayerView` / `BKArtBackgroundView` / `usesDarkForeground` / Cover Blur profile 的判定全部上收到该 Profile，由 SemanticPaletteFactory 在派色时一次产出。

### ☆ K.8 全屏歌词应按皮肤类型分别采用不同层级策略

**方向性结论**：

**A. Apple 风格 / Cover Gradient 皮肤**：

- 继续使用 opacity 表示活跃 / 非活跃层级（沿用当前实现）。
- Cover Gradient 仍按封面明暗切换 profile（由 ☆ K.7 提供）。
- 但 **副歌词 glow 固定灰色 (200,200,200) 不理想**，建议未来改为：
  - 选项 a：纯白 / 纯黑（与 main glow 一致，简化逻辑）
  - 选项 b：Swift 注入主题驱动的 glow 色（推荐，与 ☆ K.6 一致）

**B. 艺术背景类皮肤（背景复杂、杂乱）**：

- **不应**依靠透明度表示层级。
- 应采用"不透明，但明度 / 彩度不同"的层级逻辑：
  - 当前行更亮、彩度更高、对比度更强
  - 非当前行更暗 / 更低彩，但仍**实体存在**（opacity = 1.0）
- 层级来自色彩本身，而非透明度叠加。
- 这是 ☆ K.10 Tone Ladder 的直接应用场景之一。

### ☆ K.9 Library 详情页 Header 颜色路径应缩减

**当前状态（R2 H.2）**：`headerSemanticPalette` 整体在 Library detail UI 中 **0 处字段级读取**，但 `HeaderColorExtractor` 仍跑完整 `ArtworkColorExtractor.analyze` + `SemanticPaletteFactory.make` 流程。

**方向性结论**：

1. 评估当前 Header UI 真正消费的字段。如果只是 globalAccent，Header 路径应缩减为只产 `globalAccent`，跳过 16 个角色色派生。
2. 不必为 Header 完整生成大量未消费角色色。
3. 若未来要把 Header 改成封面驱动色背景，再另行扩展。
4. 这是 R3 报告中"应收敛 / 应瘦身路径"的典型案例。

### ☆ K.10 引入"Tone Ladder"——艺术化明度层级

**方向性结论**：

未来颜色系统在做"同一颜色从亮到暗"或"层级分级"时，不应只调 L 值，而是 L / C / H 三维联动：

- chroma 应按色相族联动（如黄色暗化时 chroma 衰减更慢，蓝色暗化时 chroma 衰减更快）
- hue 可做细微艺术化漂移：
  - 黄系变暗时偏向琥珀 / 橙
  - 蓝系变暗时略偏靛 / 紫
  - 红 / 绿 / 青 / 紫各有专业 tone 曲线
- 与"理论绝对正确"无关，是 APP 的艺术化色彩策略，由色彩专业知识 + 视觉测试制定。

**应用场景**：

- LED 中间档分级（解决 J.6 的层次不明显问题）
- 艺术背景类歌词皮肤的活跃 / 非活跃层级（☆ K.8 选项 B）
- 任何"主色 → 多档变体"的场景（包括频谱、Home Shapes 的克制补色 fallback）

**实施**：作为 OKLCH 数学层的扩展能力（在 ☆ M.2 的第 1 阶段中提供 `oklchToneLadder(base:level:hueFamily:)` 原语）。

***

## ☆ L. 当前系统问题清单（R3 整合）

以下问题在 R1 / R2 / R3 中都有提及，R3 把它们整合在一处，便于后续重构作 issue 列表：

| #  | 问题                                                  | 严重度  | 根本原因                       | 解决方向                      |
| -- | --------------------------------------------------- | ---- | -------------------------- | ------------------------- |
| 1  | `optimizedAccent` 不读 richPalette                    | 🔴 高 | accent 与采样脱节               | ☆ K.1 / K.3 真实多色分发        |
| 2  | 极暗彩色封面 accent 被强提亮（夜色感丢失）                          | 🟡 中 | `darkMinL` 通用地板 + (T,F) 分支缺失（J.2 R4 修订） | ☆ K.2 Ultra Dark / NearMono 正交化 |
| 2b | isEffectivelyMonochrome 第 4 支耦合亮度，极暗彩色被误判为 mono | 🟡 中 | 色度分类器吸入亮度指标（J.2.d）         | ☆ K.2 拆解第 4 支              |
| 3  | Home Shapes 是凭空 hue 旋转                              | 🟡 中 | 与 artwork 关系疏远             | ☆ K.3 真实多色分发              |
| 4  | MiniPlayer 控件色散在 View 层                             | 🟢 低 | 缺正式语义角色                    | ☆ K.5 控件语义化               |
| 5  | 歌词色决策跨 Swift / Web 散乱                               | 🟡 中 | 历史架构                       | ☆ K.6 Swift 化             |
| 6  | 多套封面明暗判定并存                                          | 🟡 中 | 历史架构                       | ☆ K.7 Readability Profile |
| 7  | LED 中间档分级不明显                                        | 🟢 低 | L 插值 ±0.03 < JND           | ☆ K.10 Tone Ladder        |
| 8  | `headerSemanticPalette` 0 消费但跑完整 factory            | 🟢 低 | 历史架构                       | ☆ K.9 Header 路径瘦身         |
| 9  | `ArtworkAssetStore` 缓存绕过版本号                         | 🔴 高 | 架构 bug                     | R2 调整 2（必须先修）             |
| 10 | `--amll-shadow` / `--amll-bg` / `--amll-accent` 死字段 | 🟢 低 | A/B 测试历史                   | R2 调整 1（已列入第 0 阶段）        |

***

## ☆ M. R3 修订后的迁移路线最终纲领

R3 不推翻 R2 在 G 节的 7 阶段架构，而是 **在每个阶段补充新职责**。下表给出最终纲领：

| 阶段                                        | R1/R2 原本                                         | R3 补充                                                                                                                                               |
| ----------------------------------------- | ------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| **0. 架构清理**                               | 清死字段、修 fallback、token 化、修复 ArtworkAssetStore 缓存键 | **新增**：评估 ☆ K.9 Header 路径瘦身；评估 R3 LED 档位扩展是否独立先行                                                                                                    |
| **1. OKLCH 数学层**                          | 增加 OKLCH ↔ NSColor / RGB 原语 + softShoulder 等     | **新增**：`oklchToneLadder` 原语（☆ K.10）；`artworkReadabilityProfile` 原语（☆ K.7）                                                                           |
| **2. SemanticPalette 主源头**                | 复制 factory 为 OKLCH 版本、用 feature flag 切换          | **新增**：J.7 的 9 条审美规则逐项 OKLCH 等价校准；新增 ☆ K.2 系统级 Ultra Dark；新增 ☆ K.5 controlAccent / progressFill 等正式角色；新增 `artworkDisplayPalette` 字段供 ☆ K.1 / K.3 消费 |
| **3. 装饰类（Home / Header / CoverGradient）** | OKLCH 等价；Header 跟随主源头                            | **替换**：Home Shapes / Art BK 改为真实封面多色分发（☆ K.3）；Header 缩减路径（☆ K.9）                                                                                    |
| **4. 交互类（MiniPlayer / 玻璃 / Skin LED）**    | OKLCH 等价 enforceMin/MaxL                         | **替换**：MiniPlayer 控件色读语义角色而非 View 二次修正（☆ K.5）；频谱改读真实多色（☆ K.1）；LED 中间档应用 Tone Ladder（☆ K.10）                                                         |
| **5. 歌词跨 Swift / Web**                    | OKLCH 字符串 + magic number 改写                      | **新增**：歌词颜色决策全面上收 Swift（☆ K.6）；全屏歌词按皮肤类型分别走 opacity 分层 / Tone Ladder 分层（☆ K.8）；Cover Blur sub glow 改 Swift 注入                                       |
| **6. 评估边界（LED / glow / blur）**            | LED 已 OKLCH；CSS filter 保留 RGB                    | 不变（LED 已经是参考）                                                                                                                                       |
| **7. 清理**                                 | deprecate HSL 函数；评估 headerSemanticPalette        | **加深**：HSL 函数仅保留作为图像采样 / WCAG 中间步；其他派色全 OKLCH                                                                                                       |

### ☆ M.1 OKLCH 等价校准（最复杂的一步）

J.7 列出的 9 条审美规则在 OKLCH 后必须重新标定。R3 强烈建议：

1. **不要机械替换数字**（HSL S 0.72 不等于 OKLCH C 0.72）。
2. 选 20 张代表性封面，分别用 HSL 当前规则与 OKLCH 候选规则跑出 globalAccent，做 visual diff（Delta E < 5）。
3. 重点关注：黄色 (h≈0.15) 在 OKLCH 中的"鲜度感知"；蓝紫色 (h≈0.7) 在 OKLCH L=0.5 vs HSL L=0.5 的视觉差异；暖色色相卫士在 OKLCH 中是否仍必要。

### ☆ M.2 第 0 阶段清理工作（在 R2 附录 B 基础上补充）

R2 附录 B 的清理项全部保留。R3 追加：

- [ ] 评估 ☆ K.9 Header 路径瘦身实施时机（可与第 0 阶段同步，也可延迟到第 3 阶段）
- [ ] 评估 J.6 LED 档位扩展（L ±0.03 → ±0.05；C 非线性提升）是否作为独立 PR 先行
- [ ] 在 SemanticPaletteFactory 内打 TODO 标记，标出未来 ☆ K.1 / K.3 改"读 richPalette / artworkDisplayPalette"的位置
- [ ] 评估 MiniPlayer / FullscreenMiniPlayer 当前的 View 层 HSL 修正在何处（为 ☆ K.5 抽取做准备）

***

## N. Round 3 / Round 4 Changelog

R3 在 R1 / R2 报告基础上的关键修订与新增，R4 对 R3 的两条核心结论作小范围但关键的复核修正。

### N.0 Round 4 修订（小范围、关键）

R4 不扩展范围，只复核两处 R3 概念性结论：

1. **J.1 重写**：拆为直接消费层（J.1.a）+ 间接渗透层（J.1.b）+ 修正归因（J.1.c）。
   - 撤回 R3 "派色完全丢失 / 消费端为 0" 的绝对断言。
   - 新发现：歌词角色色（windowLyric*、fullscreenLyric*）通过 `averageColor` 加权平均色相与 `bestTextSourceColor` 的 satBonus 评分，**仍间接消费小面积高显著色**。用户观察到的"歌词能感觉到小面积色"现象有代码事实支撑。
   - accent 链路（频谱、Home Shapes、Header、Hero、MiniPlayer 控件）的"完全丢失"结论 **仍成立**，☆ K.1 / K.3 优先级不变。

2. **J.2 重写**：分离 Ultra Dark 与 Near Monochrome 为两个正交维度。
   - 撤回 R3 "系统级真正承担极暗保护的是 nearMonochromeAccent" 的归因。
   - 修正归因：主链路 accent 被提亮源自 `darkMinL` 通用地板（`SemanticPalette.swift:118-128`），不是 nearMonoAccent 副作用。
   - 新发现：`isEffectivelyMonochrome` 第 4 支 OR 把亮度耦合进色度分类，造成"极暗中低饱和彩色封面"被误接管为 mono 的风险（J.2.d）。
   - K.2 重写为四角点决策表：(UltraDark=T, NearMono=F) 是当前缺失的关键分支，应允许"保留原色相 + 暗 L"。
   - L 节问题清单新增 #2b，记录 isEffectivelyMonochrome 第 4 支耦合问题。

R4 不修改：A–I、J.3–J.7、K.1、K.3–K.10、L 其他行、M、附录 A/B/C。

### N.1 Round 3 重要修正（覆盖 R1 / R2 既有结论）

- ✱ R3 修正 R1 关于"系统大概仍保留小面积高显著色"的猜测：**采样保留 / accent 链路丢失（R4 进一步澄清：歌词链路仍间接渗透）**。
- ✱ R3 修正 R2 中"Ultra Dark 仅作用于 Fullscreen 歌词"的笼统结论：**字面 Ultra Dark 仅在 BKArt + Fullscreen 歌词；主链路 accent 提亮源自 darkMinL（R4 修正归因）**。
- ✱ R3 把 R1 笼统的"派色忠于封面"判断拆为 16 角色色的忠实度评分（J.4）：背景类强忠实，accent / 文本 / 歌词 UI 主导，Home 装饰几乎完全 UI 主导。
- ✱ R3 修正"近黑白防假色"在 R2 中的简单确认：**机制完整且严格**（J.3），但揭示 hasUsableAverageHue 在 avgSat ∈ [0.055, 0.105] 的小区间内仍保留方向性偏移（有意设计，不修）。
- ✱ R3 确认"LED 已 OKLCH 化"为事实，**但补充质量问题**：中间档 L 变化 0.03 < JND，C 变化 6%（J.6）。

**新增确认事实**：

- R3 在 `ArtworkColorExtractor.swift:270-323` 完整盘点噪声门槛与过滤规则。
- R3 完整列出 R3 子代理找到的隐性 Ultra Dark 路径：`BKArtBackgroundView.swift:296-300, 1107-1111, 1708` + `FullscreenPlayerView.swift:3143, 3462-3471`。
- R3 把 SemanticPaletteFactory 30+ magic number 归纳成 J.7 的 9 条审美哲学，逐条标注 OKLCH 后保留 / 重新表达。

**☆ 新增方向性结论（颜色系统 2.0）**：

- ☆ K.1 频谱真实多色优先
- ☆ K.2 极暗封面系统级 Ultra Dark
- ☆ K.3 Home Shapes / Art BK 真实多色分发
- ☆ K.4 Home Hero 颜色分叉是正当的
- ☆ K.5 MiniPlayer 控件色语义化
- ☆ K.6 歌词颜色决策 Swift 化
- ☆ K.7 Artwork Readability Profile 统一化
- ☆ K.8 全屏歌词按皮肤类型分别采用层级策略
- ☆ K.9 Library 详情页 Header 路径瘦身
- ☆ K.10 Tone Ladder 艺术化明度层级

**路径修正**：

- R1 / R2 报告中 `myPlayer2/Services/Theme/SemanticPalette.swift` 实际位于 `myPlayer2/Utilities/SemanticPalette.swift`。附录 A 已修正。
- 同理 `ArtworkColorExtractor.swift` 实际位于 `myPlayer2/Utilities/`，原报告正确；`ArtworkColorAnalysis.swift` 同位于 `Utilities/`（R3 新引用文件）。

**新增引用文件**：

- `myPlayer2/Utilities/ArtworkColorAnalysis.swift`（R3 重点）
- `myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift`（R3 引出的字面量 Ultra Dark 路径）
- `myPlayer2/Views/NowPlaying/BKColorEngine.swift`（HarmonizedPalette + veryDarkCover）

***

## 附录 A：关键代码位置索引

> 路径已 R3 核对至实际文件系统。原 R1 / R2 报告中 `Services/Theme/SemanticPalette.swift` 是错的，实际路径见下。

| 文件                                                         | 关键内容                                                                                                           |
| ---------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `myPlayer2/Services/Theme/ThemeStore.swift`                | 主题中枢，缓存键 74 行，refreshPalette 380+ 行                                                                            |
| `myPlayer2/Utilities/SemanticPalette.swift` ✱R3            | 16 角色色，optimizedAccent 91-184，nearMonochromeAccent 186-225，darkMinL 118-128 ✱R4，windowLyricActive 270-275 ✱R4，fullscreenLyricBase 284-291 ✱R4 |
| `myPlayer2/Utilities/ColorMath.swift`                      | HSL / WCAG 数学原语，softShoulder 105-112                                                                           |
| `myPlayer2/Utilities/LEDColorResolver.swift`               | OKLCH 范例，hueAwareChromaCap 152-160，level 插值 302-329                                                            |
| `myPlayer2/Utilities/ArtworkColorExtractor.swift`          | 像素采样 / 聚类 / 噪声门槛 270-323，textPalette 494-609，adjustedAccent 66-93 ✱R4，textSourceColor 769-793 ✱R4，sat<0.04 降权 121 ✱R4 |
| `myPlayer2/Utilities/ArtworkColorAnalysis.swift` ✱R3       | isEffectivelyMonochrome 233-238（第 4 支耦合亮度 ✱R4），usesDarkForeground 239-240，averageColor 241-246 ✱R4               |
| `myPlayer2/Services/Artwork/ArtworkAssetStore.swift`       | 第二层缓存（无版本号 ✱R2 关键 bug）                                                                                         |
| `myPlayer2/Views/Home/HomeAmbientShapesBackground.swift`   | ambientBaseColor 708-750，makePalette 775-843                                                                   |
| `myPlayer2/Views/Home/HomeHeroView.swift`                  | 独立 heroPalette                                                                                                 |
| `myPlayer2/Views/Library/PlaylistDetailView.swift`         | headerSemanticPalette 入口（0 消费）                                                                                 |
| `myPlayer2/Views/Lyrics/AMLLWebView.swift`                 | WebView 容器                                                                                                     |
| `myPlayer2/Services/Lyrics/LyricsWebViewStore.swift`       | applyEffectiveTheme 1323；CSS 变量注入 1341                                                                         |
| `myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift`    | makeFullscreenLyricsColorSet 3458+；CoverBlurProfile 3772-3789；lockedFullscreenLyricsUltraDark 3143 / 3462-3471 |
| `myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift`  | AppKit Spectrum 容器，134-144 updateNSView                                                                        |
| `myPlayer2/Views/NowPlaying/BKArtBackgroundView.swift` ✱R3 | isUltraDarkPalette 296-300；updateUltraDarkOverlay 1107-1111；isUltraDarkCover 1708                              |
| `myPlayer2/Views/NowPlaying/BKColorEngine.swift` ✱R3       | HarmonizedPalette + veryDarkCover                                                                              |
| `myPlayer2/Resources/AMLL/index.html`                      | Web 层颜色变量与 mix-blend-mode；shadowColor 死字段 5383-5391                                                            |
| `myPlayer2/Resources/AMLL/style.css`                       | Web 层基础样式                                                                                                      |

## 附录 B：迁移前必须执行的清理工作清单

> R3 在 R2 清单基础上补充，原项保留。

**R2 原清单（不变）**：

- [ ] 删除或注释 `ThemePalette.shadow` 与 Swift→Web `--amll-shadow` 序列化
- [ ] 删除或注释 Swift→Web `--amll-bg` 与 `--amll-accent` 序列化
- [ ] 修复 `MiniPlayerSpectrumView` fallback 0.7 灰 → `#E6C799`
- [ ] 修复 `ClassicLEDSkin` 阴影 0.35 黑 → colorScheme 自适应
- [ ] 修复 `FullscreenCoverGradient` 箭头 0.5 白 → 主题色派生
- [ ] 评估 `headerSemanticPalette` 是否要继续生成 14 个字段（与 ☆ K.9 联动）
- [ ] 提取 `SemanticPaletteFactory` 30+ magic number 到 `SemanticPaletteTokens.swift`
- [ ] **修复** `ArtworkAssetStore` **缓存键架构**（最高优先级）
- [ ] 在 docs 中标注玻璃 A 类常量为不可迁移基线

**R3 新增项**：

- [ ] 在 `SemanticPaletteFactory` 内打 TODO 标记，标出未来 ☆ K.1 / K.3 改"读 richPalette / artworkDisplayPalette"的位置
- [ ] 评估 J.6 LED 档位扩展（L ±0.03 → ±0.05；C 非线性提升）是否作为独立 PR 先行
- [ ] 评估 ☆ K.7 ArtworkReadabilityProfile 抽象的时机（先做接口，逐步收编散落的明暗判定）
- [ ] 评估 MiniPlayer / FullscreenMiniPlayer 当前的 View 层 HSL 修正在何处（为 ☆ K.5 抽取做准备）
- [ ] 评估 ☆ K.6 歌词决策上收 Swift 的范围（cover blur sub glow 是最低成本的起点）

## 附录 C：迁移成功标准

OKLCH 迁移完成后，下列指标应保持不变或更优：

**R2 原标准（不变）**：

1. 20 张代表性封面的 visual diff baseline 无明显偏差（Delta E < 5）
2. WCAG AAA 7:1 对比度保持
3. 黑白封面伪 hue 行为保持一致
4. 暖色色相卫士行为保持一致（注：R3 ☆ J.7 #4 建议在 OKLCH 中重测必要性）
5. 全屏歌词在 cover blur / 标准 / 浅 / 深四种模式下可读性不退化
6. LED / Spectrum / MiniPlayer 控件在浅 / 深切换瞬间无视觉延迟
7. 切歌时颜色刷新时延（quick → extracted）不超过 300ms
8. `ArtworkAssetStore` 缓存版本号机制可正确失效旧 snapshot

**R3 新增标准（颜色系统 2.0 阶段验收）**：

9. 95% 黑灰 + 5% 鲜黄类封面：频谱 / Home Shapes 中应有可见的"小面积色现身"（☆ K.1 / K.3 验收）
10. 极暗封面（avgHslL < 0.18）：accent 允许 L 下沉到 ≤0.58 且 WCAG 对比度仍达标（☆ K.2 验收）
11. MiniPlayer 控件色不再有 View 层 HSL 修正，全部读语义角色（☆ K.5 验收）
12. AMLL CSS 中不再有写死的灰色 / 黑色 / 白色（玻璃 A 类常量除外，☆ K.6 验收）
13. 全仓库只有 1 处"封面明暗判定"，被所有消费方共享（☆ K.7 验收）
14. LED 档位中间态视觉差异可被感知（L 变化 ≥ JND）（☆ K.10 验收）

***

**R1 调查完成**：2026-05-19 之前\
**R2 调查完成**：2026-05-19\
**R3 调查完成**：2026-05-19\
**R4 复核修订完成**：2026-05-19（小范围：J.1 歌词反向数据流 + J.2 Ultra Dark / Near Monochrome 概念分离）\
**调查范围累计**：四轮覆盖 6 个颜色消费域 + 8 个 R2 定点疑点 + 6 类 R3 决策引擎深度逆向问题 + 2 类 R4 概念修订\
**输出去向**：作为 OKLCH 迁移所有阶段的设计依据 + 颜色系统 2.0 重构纲领。本报告与代码同步保留；任何与本报告冲突的代码变更视为对原始系统快照的偏离，需在变更说明中标注。

**☆ 与代码事实的关系**：☆ 段落代表"系统目前不是这样，是未来要走的方向"。在 ☆ 落地前，代码中没有对应实现。落地节奏由后续每个阶段的 PR 决定，本报告不强制时间表。

***

## ⚠️ R5 — Phase 3 落地后用户手测暴露的近黑白伪 hue 遗留问题（2026-05-20）

Phase 3 完成（commit `b2faae1`）并经回修补丁（本节同期提交）后，用户手测仍发现 **2 个跨阶段问题**。它们不在 Phase 3 回修范围（且本轮严禁修复，以免污染 Phase 4 / Phase 5 的整体语义化），但必须在本调查报告留下显眼记录：

### R5.1 — 全屏 MiniPlayer UI 在近黑白封面下出现淡蓝 / 淡黄 / 轻微染色（Phase 4 接力）

- **现象**：纯黑白灰、近零饱和度封面下，全屏 mini player 的文字 / 图标 / 控件色出现淡淡偏蓝 / 偏黄 / 其他轻微伪色相。
- **根因方向**：`FullscreenMiniPlayerView.controlPrimaryNSColor` / `shouldUseDarkArtworkForeground` 仍从 SemanticPalette 旧路径 + averageColor 推导，没有 nearMono 中性化通道。即使 SemanticPalette accent 在 Phase 2 已识别 nearMono，accent 颜色本身仍可能携带 salient 的微弱 hue。
- **必须由 Phase 4 完成**：MiniPlayer 控件色语义化 + Artwork Readability Profile 必须把 `analysis.isNearMonochrome == true` 当作显式规则，强制 UI 主色 OKLCH `chroma ≈ 0`。
- **验收**：纯灰封面 UI 颜色 `chroma < 0.005` 且 `circularHueDistance < 0.01`（或退到 system label color）。
- **追踪**：`docs/oklch-color-system-migration-log.md` §3.12 Issue A；`docs/oklch-color-system-execution-plan.md` §Phase 4 接力项。

### R5.2 — 窗口 / 全屏歌词在近黑白封面下偏粉红（Phase 5 接力）

- **现象**：纯黑白灰、近零饱和度封面下，窗口歌词面板与全屏歌词面板的高亮 / 文字色均偏粉红。
- **根因方向**：歌词色彩链路（含 ThemeStore 与 LyricsWebViewStore 双写）部分仍走旧 HSL accent 路径，nearMono 时残留 hue 没有归零；窗口歌词当前整体观感虽好，但**近黑白这一边界场景必须修**；全屏歌词同步问题。
- **必须由 Phase 5 完成**：Swift 侧统一歌词色彩决策函数（含窗口 + 全屏两面），增加 `analysis.isNearMonochrome == true` → 歌词所有可见色 OKLCH `chroma ≤ 0.005` 规则。**两端同步验收**，避免单端修复造成割裂。
- **追踪**：`docs/oklch-color-system-migration-log.md` §3.12 Issue B；`docs/oklch-color-system-execution-plan.md` §Phase 5 接力项。

### R5.3 — 共性结论

R5.1 / R5.2 同样源自一个深层模式：

> Phase 2 已经把 nearMono 识别做对了（`analysis.isNearMonochrome` 在 R3 ☆ K.7 中确立为单一封面明暗判定），但**消费端仍有多处没有把 nearMono 翻译成 chroma 压制规则**。Phase 3 在 Home Shapes / BKArt / Spectrum 三处补齐了；MiniPlayer 控件层（Phase 4）与歌词层（Phase 5）仍在欠款列表。

后续 Phase 4 / 5 设计时，建议把"nearMono → chroma 中性化"作为**所有 UI 颜色决策的硬性规则**，而非每个消费端各自实现。可考虑在 `SemanticPalette` 层提供一个 `nearMonoNeutralizing(_:)` helper 强制所有消费端经此入口。这样后续新 UI（包括 Phase 6 Tone Ladder / LED）天然继承该保护。

***

## R6 — Phase 5 follow-up：Swift-owned lyrics color contract（2026-05-21）

Phase 5（commit `ae6210e` — `Converge lyrics color palette`）已落地 R5.2 的歌词修复，并把原报告中指出的歌词 Swift/Web 双层路径复杂问题收敛为长期 adapter contract。

结论更新：

- 原报告中 `☆ K.6 歌词颜色决策应统一到 Swift 侧，Web 只保留渲染` 已完成主体落地：歌词颜色决策上收到 Swift `SemanticPalette.lyrics`。
- 新 Swift 入口包括 `LyricsColorPalette`、`LyricsSurfaceColorSet`、`LyricsCoverBlurBlendProfile`，由 `SemanticPaletteFactory.lyricsPalette(...)` / `fullscreenLyricsColorSet(...)` / `coverBlurLyricsColorSet(...)` 统一派生。
- AMLL Web 层保留渲染职责：opacity、blend、mix-blend-mode、text-shadow / drop-shadow structure、line-state class 与兼容 fallback。
- `syncFullscreenDerivedColors()` 的 adapter rule 是优先消费 Swift 显式颜色，缺失时才 fallback 派生；Web 不再承担主要 hue 决策。
- nearMono lyrics neutralization 成为硬规则：`analysis.isNearMonochrome == true` 时，窗口 / 全屏 / cover blur visible lyrics colors 的 OKLCH chroma ≤ 0.005，避免黑白灰 artwork 下偏粉、偏蓝、偏黄。

后续维护规范：

- 未来 AMLL 升级、重建 `index.html` adapter 或修改 fullscreen lyrics CSS/JS 时，必须遵守 Swift-owned lyrics color contract。
- 不要把颜色决策重新搬回 Web / CSS；Web rendering-only / adapter contract 只允许保留渲染行为与兼容 fallback。
- Phase 6 Tone Ladder 可以优化艺术背景 fullscreen lyrics 的不透明明度 / 彩度层级，但必须替换 Swift 侧 surface color set 派生，而不是让 Web 重新选 hue。
