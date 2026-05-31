# OKLCH 颜色系统重构 — 总执行计划

> 本文档是 `docs/oklch-migration-color-system-investigation.md`（R1–R4 最终调查报告）的施工面落地版本。\
> \
> 报告负责"为什么"和"现状如何"；本文件只负责"按什么顺序施工 / 每一步的边界 / 验收标准"。\
> \
> 真实改动日志请记到 `docs/oklch-color-system-migration-log.md`。

***

## 1. 总体目标

调查阶段（R1–R4）已经把当前基于 HSL/RGB 的颜色系统逆向建模清楚。这一轮颜色系统升级要在不一次性 OKLCH 大迁移的前提下逐步推进，原则如下：

1. **先清理历史遗留与死字段。** 把没有消费者的契约删干净；把已经被新算法替代但还留有读路径的字段一次性收掉。**这一步本身不引入新算法、不变 UI 行为**。
2. **再建立颜色规则的 token 化基础与 OKLCH 公共数学层。** 这一步是迁移的"语言层"——所有后续阶段都依赖一个统一的颜色 token / 颜色空间转换层。
3. **再升级艺术取色决策引擎到 2.0。** 把当前散落在 `SemanticPaletteFactory` 中的 5+ 个 OR 分支重新拆成正交维度（Ultra Dark / Near Monochrome 等），并新增小面积高显著色 / 多色 palette 的结构化输出。
4. **再把装饰色与真正多色分发铺出去。** Home Shapes / BKArt / Spectrum 真正利用 artwork 多色，而不是单一 accent 渐变。
5. **再做交互可读性语义色。** MiniPlayer 控件色彻底语义化；Artwork Readability Profile 统一对外。
6. **再收敛歌词颜色体系。** Swift 侧颜色决策集中、不同 fullscreen skin 分策略、glow / layer 层级整理。
7. **最后做 Tone Ladder 与 LED / 歌词层级深化、清理旧 HSL 分叉、文档收尾与回归验证。**

每一阶段都要做到：

- 不为下一阶段"提前埋头"，保持每一步可以独立合并；
- 不在阶段边界以外重排 UI 视觉口径；
- 每一阶段完成后更新 `docs/oklch-color-system-migration-log.md`。

***

## 2. 阶段划分

### Phase 0 — 前置清理与迁移基础设施 ← **本轮**

目标：把"无消费的契约"和"潜在 B 类小 bug"一次性清掉。**不改算法、不改主视觉口径**。本阶段详情见 §3。

### Phase 1 — 颜色规则 token 化 / OKLCH 公共数学层

目标：

- 建立 OKLCH ↔ RGB / HSL 之间的公共数学层（`ColorMath` 的对偶层），按报告 K.3 / Appendix B 的方向铺路。
- 把分散在各处的"颜色 magic number"（accent 明度下限、近黑白阈值、对比目标等）整理成 token 化常量，集中在一处。
- **本阶段不切换任何 UI 颜色输出**：实现层加入 OKLCH 数学能力，但仍由现有 HSL 路径产生最终颜色。

退出条件：所有现有颜色决策都能以"等价 OKLCH 表达"被复述，并通过单元级数学对照（HSL 与 OKLCH 之间的等价转换）。

### Phase 2 — 艺术取色决策引擎 2.0

目标（对应报告 J / K 部分）：

- **Ultra Dark 与 Near Monochrome 分离**：把"明度低"和"色相不可信"作为两个正交维度独立判定（R4 J.2.d / K.2）。
- **小面积高显著色结构化输出**：在 `ArtworkColorAnalysis` 中新增 salient highlight palette（R4 J.1）。
- **多色 artwork palette 的基础能力**：把 topPalette / richPalette 重新组织成可被 UI 直接消费的多色 token。
- 收敛 `isEffectivelyMonochrome` 5 个 OR 分支，明确每条分支的物理含义；移除分支 4 的明度耦合（R4 J.2.c L#2b）。

退出条件：相同 artwork 输入下，旧引擎与新引擎的输出在"主流封面"上视觉一致；关键边界用例（极暗有色、近灰阶、纯黑、霓虹）行为符合 K.2 的四象限决策表。

### Phase 3 — 装饰色与真实多色分发

- Home Shapes：使用 artwork 多色而非单 accent 渐变。
- BKArt：保留 Ultra Dark 保护，但启用真正多色背景。
- Spectrum：使用 artwork 两色或多色填充，而不是 fallback 灰。

退出条件：在监听同一封面时，Home Shapes / BKArt / Spectrum 三处的颜色分布肉眼一致且能反映 artwork 多色性。

### Phase 4 — 交互与可读性语义色

- **MiniPlayer 控件色语义化**：去掉对 `themeStore.accentColor` 的硬读，改读 `controlPrimaryColor` / `controlSecondaryColor` 等显式角色。
- **Artwork Readability Profile**：把"在 artwork 上叠字"的可读性策略（`readableTextOnArtwork` / `usesDarkForeground`）统一到一处。
- **【接力自 Phase 3 回修】近黑白 artwork 下 Fullscreen MiniPlayer UI 不应出现淡蓝 / 淡黄 / 可感知伪 hue**。当前 `FullscreenMiniPlayerView.controlPrimaryNSColor` / `shouldUseDarkArtworkForeground` 仍从原 SemanticPalette accent / averageColor 推导，未走 nearMono 中性化通道。Phase 4 新增的 `MiniPlayerControlPalette` 必须在 `analysis.isNearMonochrome == true` 时强制把 UI 主色归到 OKLCH 中性轴（chroma ≈ 0），仅靠 L 区分。**验收**：纯灰封面下 UI 颜色 `chroma < 0.005` 且 `circularHueDistance < 0.01`（或直接降级到 system label color）。参见 `oklch-color-system-migration-log.md` §3.12 Issue A。

退出条件：同一 artwork 下，Home Hero / Library Header / Fullscreen Cover Gradient 三处的可读性策略一致；且近黑白封面下 Fullscreen MiniPlayer UI 不再出现伪 hue。

### Phase 4.5 — 全局淡彩前景色体系（Global Tinted Neutral Foreground Palette）

> **本阶段尚未实现，已于 Phase 4 完成后写入路线图。**

#### 目标

把当前 App 内大面积使用的纯白 / 纯黑 / 纯灰普通前景字体与图标，逐步纳入主题色体系，形成一种"高可读、乍看近似黑白灰、细看带有极低饱和度主题色"的全局前景色方案，类似 Material You 的 tonal neutral foreground 思路。

#### 新增语义角色

建立面向普通 App UI（非 artwork 压字场景）的前景色角色体系：

| 角色                     | 视觉目标                               |
| ---------------------- | ---------------------------------- |
| `foregroundPrimary`    | 主文字，视觉近似"亮白 / 深黑"，细看带极低 chroma 主题色 |
| `foregroundSecondary`  | 次级文字，视觉近似"浅灰 / 深灰"                 |
| `foregroundTertiary`   | 三级文字、辅助说明                          |
| `foregroundQuaternary` | 四级，非常弱的 hint / 占位符                 |
| `foregroundDisabled`   | 禁用状态                               |

#### 设计原则

- **可读性优先**：主文字对比度不得低于 WCAG AA；次级颜色不强制 AA，但不应偏色到影响辨识。
- **chroma 极低**：前景色不做"彩色文字"，只做"带一点主题气质的中性色"，chroma ≤ 0.02（OKLCH）。
- **深浅模式分开建模**：深色模式 primary 接近 off-white（OKLCH L≈0.96，C≤0.012）；浅色模式 primary 接近 near-black（OKLCH L≈0.14，C≤0.012）。
- **与 artwork 压字场景分开**：Phase 4 的 `ArtworkReadabilityProfile` 管"压在 artwork 上"的前景；Phase 4.5 管普通 App UI（materials、窗口背景、设置面板上的字体）。
- **保留固定光学常量**：纯光学白（登录按钮、高亮 fill）、纯光学黑（阴影、border）等设计常量不被"淡彩化"。
- **不暴力全局替换**：必须先审计所有字体和 icon 来源，区分"来自系统语义色（`.primary`）"、"来自 ThemeStore.accentColor"、"来自硬编码 `.white`/`.black`"三类，再分策略渐进接入。

#### 工作范围

Phase 4.5 应包含：

1. **全 App 字体 / 普通前景颜色审计**：列出使用 `.primary`/`.secondary`/`.tertiary`/`.white`/`.black`/`.gray` 等色的所有 View，标注语义类别（系统语义 vs. 主题强调 vs. 固定光学常量）。
2. **主题化 foreground palette 设计**：在 `ColorSystemTokens` 新增 `TintedNeutral` 命名空间，定义每个角色的 OKLCH L、C 目标值与深浅模式变体。在 `SemanticPalette` 新增 `appForeground: AppForegroundPalette`，由 `SemanticPaletteFactory` 从 `globalAccent` 极低 chroma 派生。
3. **渐进接入策略**：优先接入最常见的"中性文字"（artist 行、时间戳、描述文字），最后接入"强调 accent 文字"（selection 行等需保留 accent 气质的，留到后续）。
4. **可读性与视觉回归标准**：接入一处必须过"主文字对比度 ≥ 4.5:1、次级对比度 ≥ 3.0:1、颜色 chroma ≤ 0.02"三项断言，并更新 `ColorSystemSelfCheck`。

#### 与周边 Phase 的关系

- Phase 4.5 建立在 Phase 4 的 `ArtworkReadabilityProfile` 语义思路之后，沿用 OKLCH-first 的低彩色阶方法。
- Phase 5 歌词颜色收敛不应被 Phase 4.5 的全局 foreground palette 误伤——歌词色是 artwork-driven，不是 app-ui-neutral；两套 palette 完全正交。
- Phase 6 Tone Ladder 可借用 Phase 4.5 建立的低彩色阶思想，但 Phase 4.5 本身不是 Phase 6 的前置依赖。

#### 退出条件

> **首轮（Phase 4.5 第一批）已达成 — 2026-05-20**。

- [x] 全 App 普通文字审计报告完成（见 migration log §5.1）；
- [x] `ColorSystemTokens.AppForeground` 命名空间就位（L 目标、chroma cap、断言阈值）；
- [x] `AppForegroundPalette` 类型与 `SemanticPalette.appForeground` 字段就位；
- [x] `ThemeStore.appForegroundPalette` 便利属性就位；
- [x] `SemanticPaletteFactory.appForeground(analysis:globalAccent:isDark:)` 实现：hue from accent OKLCH + 极低 chroma，nearMono 时 chromaScale=0；
- [x] 三类代表性模块接入（SidebarView / HomeView / SettingsView `V2FeatureTipView`），共 23 处；
- [x] `ColorSystemSelfCheck` 增加 5 个 `AppForeground.*` 场景全部通过（30/30）；
- [x] Debug build 通过；
- [x] 第二批扩大接入（2026-05-20，§8）：TrackRowView / PlaylistDetailView 列表 / TrackInfoEditorCore / HomeCard 内文字 / Sidebar 列表行 / SettingsSidebar / FullscreenQueueView；
- [ ] 第三批（待）：AllAlbumsView / AllArtistsView / BatchTrackEditSheet / LDDCSearchSection / AppKit Toolbar 图标；
- [ ] 视觉在多种 artwork 下实机确认（需运行 App 手测）。

***

### Phase 5 — 歌词颜色体系收敛

- [x] **Swift 侧歌词颜色决策集中**：`SemanticPalette.lyrics` / `LyricsColorPalette` 统一输出窗口歌词、全屏歌词与 cover blur 歌词色；`ThemeStore` 与 `FullscreenPlayerView` 不再各自重做 nearMono / HSL 决策。
- [x] **不同 fullscreen skin 分策略**：普通 fullscreen 与艺术背景走 `fullscreenLyricsColorSet`；Apple / Cover Gradient cover blur 走 `coverBlurLyricsColorSet`，保留 lighter / darker profile 与 opacity 层级。
- [x] **nearMono lyrics neutralization**：`analysis.isNearMonochrome == true` 时，歌词可见色经 OKLCH 中性化，SelfCheck 锁定窗口 / 全屏 / cover blur OKLCH chroma ≤ 0.005。
- [x] **Swift-owned lyrics color contract**：Swift 明确下发 active / inactive / sub / line-timing / cover blur surface colors；Web rendering-only / adapter contract 只保留渲染、opacity、blend、shadow structure 与向后兼容 fallback。
- [x] **AMLL adapter contract**：`syncFullscreenDerivedColors()` 必须优先使用 Swift 显式颜色，缺失时才 fallback 派生；后续 AMLL adapter 或 bundle 升级必须同步更新 AMLL 文档，不得把 hue 决策搬回 Web/CSS。

退出状态（2026-05-21）：Phase 5 主体完成。已完成规范 / 后续维护规则：歌词颜色决策归 Swift；nearMono visible lyrics colors OKLCH chroma ≤ 0.005；AMLL Web 层只负责渲染结构与兼容 fallback；任何 AMLL adapter 修改必须同步 implementation log 与 patch registry。剩余不在本轮强做：艺术背景 skin 的不透明 Tone Ladder、glow token 更细粒度语义化、Web fallback 进一步瘦身。

### Phase 6 — Tone Ladder 与 LED / 艺术歌词层级深化（v3）

- [x] **Tone Ladder 正式作为系统级颜色派生方法**：`PerceptualToneLadder` 建立在 `OKColor` 之后、消费者之前；参数集中到 `ColorSystemTokens.ToneLadder`，负责 OKLCH L/C/H 联动、hue-family drift、nearMono 中性化 ceiling。
- [x] **LED Meter 接入 Tone Ladder（v3）**：dark L 0.620→0.945（v2 是 0.78→0.92，跨度从 0.14 拉到 0.33），light 0.340→0.640；`ledMidChromaBoost` 0.18→0.42，`ledShadowDriftScale` 0.80→1.25；自检阈值 `ledLightnessVisibilityAssertion` 0.080→0.180。这样 OKLCH 层在 opacity 0.08→1.00 之后仍可读出"低中高"色彩科学层级，而不是被 opacity 完全吃掉。
- [x] **艺术背景类 fullscreen lyrics 接入 Tone Ladder（v3，seed-trust）**：`PerceptualToneLadder.artisticLyricsTone` 在 `base.c ≥ lyricsSeedChromaPreferred` 时**忽略** `isNearMonochrome` 参数，走彩色 floor/cap 路径；`SemanticPaletteFactory.artisticFullscreenLyricsColorSet` 在 seed 有可视 chroma 时跳过尾部 `neutraliseLyricsSurfaceIfNearMono`。这两层是 v2 失败的双重 clamp，是用户屏幕上 `#808284` 灰的真正源头。
- [x] **翻译行 L 拉近主行**：`lyricsSubInactiveL` 0.505→0.585、`lyricsLineTimingSubInactiveL` 0.455→0.540；自检新增 `lyricsSubInactiveLightnessProximityAssertion` ≤ 0.060。
- [x] **诊断日志**：`FullscreenPlayerView.applyFullscreenLyricsTheme` 在艺术背景路径下用 `ColorSystemDiagnostic.describe(...)` 打印 highlight base / inactive base / 全 6 个 role 的 `#RRGGBB (L=… C=… H=…)`；开关 `COLOR_SYSTEM_LYRICS_DEBUG=1` 或自动（艺术背景启用且非 cover blur）。
- [x] **Apple / Cover Gradient / Cover Blur 保持原 profile**：`coverBlurLyricsColorSet(...)` 未接 Tone Ladder；Apple fullscreen 继续走 cover blur lighter profile；Cover Gradient Blur 继续 lighter/darker blend profile。
- [x] **nearMono 真正中性**：v3 契约下"analysis 标志 + seed 双重信号"才会触发中性化；nearMono+grey seed 仍输出 OKLCH chroma ≤ 0.005，LED ≤ 0.006。
- [x] **v3 失败兜底**：Phase 5 HSL 路径仍未改动；若 v3 再次失败，关闭 `usesArtisticBackground` 调用即可整体回退。

退出状态（2026-05-21 v3 修复）：Phase 6 v3 完成。SelfCheck 53 项 PASS（v2 → v3 新增 4 条回归门：`colourful seed survives isNearMonochrome=true`、`artistic path keeps colour under .neutralFallback analysis`、`sub-inactive L close to main-inactive L`、`LED low-level hue drift visible vs peak`）。剩余不在本轮强做：glow/shadow 单独 Swift 语义 token、Apple / Cover Gradient 的极轻量 tone-ladder 评估、旧 HSL fullscreen fallback 清理（保留作 fallback）。

### Phase 6.1 — 艺术背景 / 歌词层级 / 日间反相 修正

用户人工测试 Phase 6 v3 后反馈：夜间模式艺术背景歌词已经有色，但需要 (a) 高饱和封面 soft shoulder；(b) 中饱和 seed 不再意外塌到低彩；(c) active L 再抬高一档；(d) translation L 与 inactive L 同档；(e) 艺术背景 BK1/BK2、纯色背景的移动圆形、floating shapes 的 L/C 重新调整；(f) 日间模式重设为"亮背景 + 深色歌词"反相体系。本节是 v3 后的视觉修正，**不进入 Phase 7**。

- [x] **高饱和 seed 软压（chroma soft shoulder）**：`PerceptualToneLadder.artisticLyricsTone` 在彩色路径下不再直接 hard-clamp 到 hue-family cap，而是先对 `base.c * chromaScale` 做 `OKColor.chromaSoftShoulder(ceiling=0.095, softness=0.045)`，再 clamp 到 cap。中饱和 seed（`scaled < ceiling`）穿过原样不被压。新自检：`Phase 6.1: high-chroma seed soft-shouldered`、`mid-chroma seed survives the shoulder`。
- [x] **active L 抬高 + inactive 下沉 + translation 与 inactive 同档**：
  - `lyricsMainActiveL` 0.880 → 0.905；`lyricsSubActiveL` 0.780 → 0.830；
  - `lyricsMainInactiveL` 0.605 → 0.580；`lyricsSubInactiveL` 0.585 → 0.575（gap 0.005，紧贴 mainInactive）；
  - `lyricsSubInactiveLightnessProximityAssertion` 0.060 → 0.020（强约束 translation 必须与 inactive 同档）；
  - `lyricsLineTimingMainInactiveL` 0.560 → 0.555、`lyricsLineTimingSubInactiveL` 0.540 → 0.535；严格降序仍保持。
- [x] **seed selection 改为「dominant 优先 + 保守 salient gate」**：`SemanticPaletteFactory.artisticLyricsSingleSeed` / `fullscreenLyricBase` 流程：
  1. `analysis.isNearMonochrome` → 保留 preferred + 后续 neutralise；
  2. `pickSalientLyricSeed` 通过则用 `salientHighlightPalette.first`：要求 colorfulness ≤ 0.18、dominantHueConfidence ≥ 0.42、`largestHighSaturationAreaShare` ≤ 0.22、salient OKLCH chroma ≥ 0.09、与 dominant 的 hue 距 ≥ 0.08；
  3. 否则用 `analysis.dominantColor`（要求 OKLCH c ≥ `lyricsDominantSeedMinChroma = 0.025`）；
  4. dominant 太灰再回退 `topPalette.first` / `bestTextSourceColor` / `preferred`。
  新自检：`seed selection dominant-first on mid-sat`、`salient fires on uniform-dark + yellow`、`salient suppressed on multi-colour art`、`nearMono seed stays neutral`。
- [x] **`PerceptualToneLadder.artisticLyricsTone` 增加 `scheme: ColorScheme`**：默认 `.dark` 维持原行为；`.light` 时整套切换到反相 L 表（`lyricsLightMainActiveL = 0.150` 等，严格升序），并使用更小的 chroma shoulder ceiling（0.072）+ hue-cap 乘以 0.72，避免深色歌词带过亮的 hue。`SemanticPaletteFactory.artisticFullscreenLyricsColorSet` 透传 scheme；`FullscreenPlayerView` 已 wire `colorScheme` 进 `fullscreenLyricsColorSet`。日间不应用 `lyricsUltraDark*Trim`。
- [x] **`BKColorEngine.tierRanges` 调整**（艺术背景视觉层）：
  - 夜间普通：`bgB` 0.24…0.40 → 0.18…0.32；`fgB` 0.44…0.64 → 0.34…0.54；`dotB` 0.56…0.82 → 0.46…0.68（圆形仍 > bg，但低于 v3）；`bgS` / `fgS` / `dotS` 上限各 +0.02…0.04，用 chroma 补偿降亮带来的灰扑扑。
  - 夜间 veryDark / UltraDark：`fgB`、`dotB` 同向再降，浮动形状 / 圆形进一步压低。
  - 日间：`bgB` 0.78…0.85 → 0.88…0.95（背景大幅提高）；`fgB` 0.66…0.78 → 0.78…0.88；`dotB` 0.50…0.62 → 0.62…0.74；`bgS` / `fgS` / `dotS` 上限轻微下调，避免高 L 飘成 pastel。
  - BK1/BK2 = `bgVariants`，brightness 直接 clamp 到 `tier.bgB`，所以"BK 背景更暗"由上面的 bgB 收紧自动达成；saturation 由 `variantSRange`（推自 `tier.bgS`）控制，对应"略提高饱和度"。
- [x] **SelfCheck v3 → v3.1 扩展**：新增 9 项 `Phase 6.1` 段；既有 v3 项目（`ToneLadder v3: artistic lyrics L hierarchy + chroma floor`、`Lyrics v3: sub-inactive L close to main-inactive L`、`Lyrics v2: artistic fullscreen tone ladder hierarchy`、`hue identity preserved on colourful artwork`）在 Phase 6.1 token 下仍 PASS。
- [x] **AMLL CSS 变量与生成 bundle**：**未修改** `amll-core.js` / `amll-lyric.js` / `index.html` CSS 变量名。颜色仍按 v3 契约下发：`fullscreenActiveColor`、`fullscreenInactiveColor`、`fullscreenSubActiveColor`、`fullscreenSubInactiveColor`、`fullscreenBackgroundColor`（= `colorSet.subActive`）、`fullscreenLineTimingInactiveColor`、`fullscreenLineTimingSubInactiveColor`。Interlude dots 与 background lyric 行通过 fallback chain (`--amll-fs-main-active` / `--amll-fs-main-inactive`) 继承 Swift 下发的 active / inactive，因此日间反相会自动套用到 dots 与 background lyric。
- [x] **Apple / Cover Gradient / Cover Blur 保持原 profile**：`coverBlurLyricsColorSet` 路径未触；Phase 5 HSL fullscreen fallback 未触；只有 `artisticFullscreenLyricsColorSet` 这一条 surface 被新 token / scheme / shoulder 影响。

退出状态（2026-05-21 Phase 6.1）：build PASS。剩余不在本轮强做：Apple / Cover Gradient 是否需要并行 light-mode 反相、glow/shadow 是否要单独 token、BK1/BK2 是否需要独立于纯色背景的 sat tier。

### Phase 6.2 — 艺术背景歌词 / Seed 选择 / 日夜视觉最终化

人工测试 Phase 6.1 后用户反馈 (a) salient gate 太保守，重点色没被歌词捕捉到；(b) nearMono 把低饱和但仍有色的封面灰白化；(c) nearMono 下艺术背景 floating shapes 仍有淡粉残留；(d) 夜间高饱和封面 inactive 仍过饱和、active 不够亮、UltraDark inactive 不够暗、纯色 + 移动圆形里圆形太亮；(e) 日间艺术背景与 shapes 太暗，歌词死黑、glow 仍是白色 glow、MiniPlayer UI 没切 dark profile。

本轮做：

- [x] **重点色 seed selection（focus score v2）**：用连续 `focusScore = visualContrast × salience × fieldUniformity × designFocus - noisePenalty` 替代 Phase 6.1 的硬 AND gate，dominant 仍是默认值，salient 只有 score ≥ 0.55 才胜出。`visualContrast` 当 dominant 是真灰/真黑时把 hue distance 当作 max contrast，让 "黑底 + 5% 亮黄" 这种典型设计封面能稳定触发。
- [x] **`isNearMonochrome` 修正**：dominant / topPalette / salient 任一 OKLCH chroma ≥ `trustedHueChromaFloor=0.045` 即视为有可信色相，跳过 4-branch OR 的非严格分支；真灰封面仍中性化。
- [x] **BKColorEngine 艺术背景 shapes 反粉红**：在 true nearMono（且无 trusted hue 候选）下，对 bgStops / shapePool / dotBase / bgVariants 做 OKLCH chroma crush 到 ≤ 0.008，消除淡粉残留。
- [x] **夜间艺术歌词 retune**：`lyricsHighChromaShoulderTrigger=0.085` 让 mid-C seed 不再被压；active L 0.905 → 0.920；sub-active L 0.830 → 0.855；UltraDark inactive trim 0.060 → 0.095；active / sub-active chromaScale 0.92/0.96 → 0.98/1.00。
- [x] **夜间 BK tier 收紧**：`bgB` 0.18…0.32 → 0.14…0.28；`fgB` 0.34…0.54 → 0.28…0.46；`dotB` 0.46…0.68 → 0.40…0.58（圆形上限刚好等于 inactive L floor 0.580）；UltraDark 分支 `dotB` 拉到 0.28…0.46。
- [x] **日间艺术背景大幅提亮**：`bgB` 0.88…0.95 → 0.92…0.97；`fgB` 0.78…0.88 → 0.80…0.90；`dotB` 0.62…0.74 → 0.66…0.78；`bgS` 上限从 0.30 收到 0.22 避免 pastel。
- [x] **日间歌词 retune（alive but below bg）**：active L 0.150 → 0.215（不死黑）；sub-active 0.260 → 0.325；inactive 0.430 → 0.470；translation 0.435 → 0.475；line-timing inactive 0.470 → 0.510 / 0.500 → 0.540。严格升序保持；与 `bgB.lower=0.92` 的 gap ≥ 0.20 invariant 满足。
- [x] **glow / interlude dots / background lyric / translation 自动跟随**：通过 CSS fallback chain (`var(--amll-fs-main-active, …)` / `var(--amll-fs-main-inactive, …)` / `currentColor`) 由 Swift 下发的反相色自动传播，**不触 generated bundle**。
- [x] **FullscreenMiniPlayer UI**：日间艺术背景模式（`settings.fullscreenArtBackgroundEnabled && colorScheme == .light && themeStore.hasArtworkThemeColor`）下控件主色切到 `readabilityProfile.foregroundPrimary`（dark on light artistic glass）。
- [x] **AMLL highlight transition 审计**：fullscreen line-level transition 走 `transition: color .14s/.18s ease-out` 已经在 `index.html`，但 transition 内部的 RGB interpolation 颜色空间发生在浏览器，非 Swift 可控。per-word/character "seam" 由生成 bundle 的 mask-image / linear-gradient 内联在 `amll-core.js` 中，无现有 CSS 变量可注入 OKLCH 中间色 → **延期到 Phase 7 / AMLL backlog**，需要 fork core patch；已在 `docs/amll-custom-behavior-and-patch-registry.md` 和 `docs/amll-upgrade-implementation-log.md` 登记。
- [x] **SelfCheck 新增 20 个 Phase 6.2 场景**：focus-score 5 个、nearMono trust 3 个、art shape 反粉红 2 个、夜间 shoulder/active/UltraDark/moving circle 5 个、日间 bg/lyric/translation 4 个、MiniPlayer day-profile 1 个。同时修正 3 个 Phase 5/6 既有测试以反映 Phase 6.2 语义：Spectrum/HomeShapes nearMono synthetic 换为纯灰，Display salient priority 不再要求 nearMono=true，ToneLadder hue identity 在 sRGB gamut 极限下放宽 active.c floor。该阶段曾 `ALL PASS`，但后续 Phase 6.3 / 6.4 人工复测已证明 self-check 不能代表视觉验收。

退出条件：Debug build 通过；`COLOR_SYSTEM_SELF_CHECK=1` 自检全 PASS；用户手测七场景（夜间高饱、夜间中饱、黑底小亮色、多色封面、UltraDark、日间 + 艺术背景、日间 nearMono）按预期表现。AMLL highlight transition 留作 Phase 7 backlog。

### Phase 6.3 — Artistic Color System Stabilization

人工测试 Phase 6.2 后确认视觉仍未验收：小面积强焦点仍不稳、nearMono 误伤有色封面、true nearMono 下 floating shapes 仍可能偏粉、夜间艺术背景偏灰/偏亮、日间艺术背景与歌词仍偏暗、日间 fullscreen MiniPlayer UI 仍会随封面切黑白、切歌时颜色会短暂掉默认色、日间 emphasis glow 仍像白色 glow。高亮 feather / active-inactive transition 本轮明确不处理，继续留在 AMLL backlog。

本轮曾尝试以下方向，但 2026-05-23 人工复测确认 Phase 6.3 未通过。下列条目不能再作为完成结论，只能作为下一轮审计时的历史背景：

- [ ] **focus seed selection v3 未通过人工验收**：曾为 `salientHighlightPalette` 同步记录 `salientHighlightAreaShares`，并把 `focusScore` 改为感知距离 + ΔC + ΔL + Δhue + dominant-field confidence + competing-high-sat area + nonlinear area gate；但小面积强焦点仍不稳定。
- [ ] **nearMono / trusted hue 仍需重新调查**：曾把 nearMono 定义为“无可信 hue”，并扩展 trusted sources；但很多有色封面仍被误判成黑白。
- [ ] **true nearMono art shapes 防粉未完成**：曾对 true nearMono 无 trusted hue 的 BK 颜色做 OKLCH chroma crush；但淡粉问题有回归。保留“极淡低彩 tint 适配黑白”的方向，不得写成完全解决。
- [ ] **日间艺术背景仍偏暗**：曾把 light tier 改为高明度体系；但背景、BK1/BK2、floating shapes、moving circle 仍不够 bright / airy。
- [ ] **日间歌词仍偏暗阴沉**：曾提高 active / inactive / translation L；但日间 active / inactive 仍不够有生命。
- [x] **日间 emphasis glow dark profile 是正确方向**：Swift 新增 `fullscreenEmphasisGlowColor`，App adapter 消费此变量；后续要确认不要回退，但不要把 hue 决策放回 Web。
- [ ] **日间艺术背景 MiniPlayer fixed dark foreground 未完成**：主 MiniPlayer、左右按钮、音量、进度、文字路径仍分裂，并仍会随封面 / hover / expanded 状态变化。
- [ ] **切歌不掉默认色未完成**：仍会闪 default / neutral / 错误深浅色。下一轮必须从颜色状态机和所有消费者 fallback 入口重新审计。
- [ ] **SelfCheck / Debug 不等于验收**：Phase 6.3 self-check 曾通过，但不能覆盖人工失败结论。

退出状态修正（2026-05-23 文档止血）：Phase 6.3 是未通过人工验收的中间尝试。AMLL highlighter transition / feather 本轮不实现，继续保留 backlog；未进入 Phase 7。

### Phase 6.4 — 艺术背景颜色架构稳定化

人工验收 Phase 6.3 仍未通过后，Phase 6.4 不再继续零散调 token，而是收敛颜色状态链路：

- [ ] **日间艺术背景仍未通过**：虽然曾提高 high-B band 并尝试禁用日间 UltraDark，人工复测仍确认整体偏暗；UltraDark 是否仍通过其他路径影响日间需要重新调查。
- [ ] **日间歌词仍未通过**：active / inactive / translation 曾提亮，但人工复测仍偏暗、阴沉。
- [ ] **Fullscreen MiniPlayer fixed dark profile 未统一**：退出全屏按钮、标题/歌手、播放控制、播放顺序块、progress/time、volume、hover / expanded 状态仍需逐项审计颜色来源。
- [ ] **切歌 pending 不发布 default / neutral 未完成**：仍会闪 default / neutral / 错误深浅色；下一轮需审计 ThemeStore、snapshot、LyricsSurfaceManager、LyricsWebViewStore、BKColorEngine、AppForegroundPalette 等所有 fallback。
- [ ] **nearMono 误判仍未解决**：`ArtworkAssetSnapshot.analysis` 是一次尝试，但有色封面仍被误判黑白；不要把 cache-hit 修复当作真实根因已解决。
- [ ] **nearMono shapes 方向保留但防粉未完成**：允许极淡低彩 tint，不要回退死灰；但淡粉回归需要重新调查。
- [x] **AMLL glow contract 保持正确方向**：Phase 6.3 的日间 dark emphasis glow 不回退；本轮不改 generated AMLL bundle。后续只需确认视觉不回退。
- [ ] **SelfCheck / Debug 不等于验收**：Phase 6.4 自检通过不能覆盖人工失败结论。

退出状态修正（2026-05-23 文档止血）：Phase 6.4 未通过人工验收。当前进入下一轮应从架构审计开始，而不是继续基于“已完成”结论微调。高亮 feather / active-inactive 过渡继续保留 backlog；未进入 Phase 7。

### Phase 6.5 — Artistic Color System Architecture Repair

Phase 6.5 的施工原则：先审计颜色状态机与 fullscreen skin 前景色策略，再做系统性修复，不继续做单点 token 微调。

- [x] **统一 Fullscreen MiniPlayer foreground strategy**：新增 `FullscreenMiniPlayerForegroundStrategy` / `FullscreenMiniPlayerForegroundProfile`。Apple skin 固定 light profile；Cover Gradient Blur / cover blur 类 skin 统一根据 artwork readability 判断；Artistic day 固定 dark profile；Artistic night 固定 light profile。MiniPlayer 主体、左右按钮、播放控制、progress/time、queue/order pill、volume、hover / expanded 状态共用同一 profile。
- [x] **ThemeStore pending hold**：artwork loading / cache miss / full analysis pending 不再发布 default / `.neutralFallback` 中间态，保留上一套有效 semantic palette；checksum + loading 进入 watcher task id，确保新 artwork ready 后触发更新。
- [x] **消费者 fallback 收口**：Fullscreen lyrics palette、cover blur held theme、BKArt palette 在 pending 时保留旧色；只有真正 no artwork 才 fallback。
- [x] **nearMono trusted hue 修复**：trusted hue 不再只看平均饱和度或 fallback dominant；需要 palette/salient 或 dominant + real sampling support。muted coherent covers 保留颜色，true grey / true nearMono 保持中性。
- [x] **nearMono shapes 防粉**：BKArt、lyrics、MiniPlayer spectrum、SemanticPalette 使用统一 effective nearMono；true nearMono 下 shapes / moving circle OKLCH chroma crush，不能被 pseudo hue 染粉。
- [x] **日间艺术背景与歌词重设**：day BKArt high-B airy profile；日间 fullscreen 不叠黑色 dimming；歌词提升到干净深灰体系，translation 与 inactive 同层，emphasis glow 保持暗色方向。
- [x] **验证**：Debug build PASS；`COLOR_SYSTEM_SELF_CHECK=1` PASS。Self-check 仍只是 synthetic 回归，最终验收需按手测矩阵确认。

退出状态（2026-05-23）：Phase 6.5 架构修复已完成本地 build / self-check。AMLL active-inactive feather transition 不处理，继续保留 backlog；未进入 Phase 7。

### Phase 6.6 — BKArt / Lyrics Color Path Audit & State Chain Fixes（2026-05-23）

Phase 6.6 对 BKArt 和艺术歌词的完整颜色链路做全路径审计，确认 paused vs playing 不是颜色差异根因；并手术修复 4 个已发现的状态链问题：

- **Track-change default color flash**：`AppKitMainSplitPanes` + `ThemeStore` + `PlaybackCoordinator` 三处协调 hold，切歌 pending 时不再回退到 cold gray fallback 或 `.neutralFallback`。
- **Paused / playing 统一**：审计确认 `isPlaying` 不进入任何颜色决策链路，无需代码修改。
- **nearMono shapes 防粉**：`neutraliseCGColor` 把 warm residual hue 旋转到 cool neutral（~209°），避免 true nearMono shapes 呈 residual pink。
- **日间亮度 fine-tune**：`tierRanges` 中 `lowSatColorCover` 的 `fgB`/`dotB` brightness boost  gated 到 `isDark` only，防止 light mode 下 shapes / background 被推到纯白而不可见。

退出状态（2026-05-23）：build PASS；`COLOR_SYSTEM_SELF_CHECK=1` ALL PASS。最终验收仍以真实封面手测矩阵为准。

### Phase 6.7 — Artistic Color System Final Stabilization（2026-05-23）

Phase 6.7 对 Phase 6.6 后人工测试发现的 4 个剩余问题进行定点修复：

- **nearMono Art Shapes 粉色残留**：用 4 色预设 palette 替换 hue 旋转，避免 pink/magenta 泄漏。Phase 6.10 已确认其中 yellow 一路审美不成立并继续收敛。
- **Light BK1/BK2 UltraDark 压暗**：ultraDark overlay 限制为 `harmonized.isDark`，light mode 不再压暗。
- **Light inactive 歌词偏暗**：日间 inactive 歌词 L +0.030，SelfCheck 阈值同步放宽。
- **Paused/playing 颜色身份分裂**：删除 `deferredPaletteUpdate` 机制，palette 立即 apply，playback state 只控制动画不控制颜色。

退出状态（2026-05-23）：build PASS；`COLOR_SYSTEM_SELF_CHECK=1` ALL PASS。最终验收仍以真实封面手测矩阵为准。

### Phase 6.10 — Merge to main + bounded queue / NearMono fixes（2026-05-23）

本轮先把 `refactor/oklch-color-system` 合并进 `main`，再在 `main` 上继续修复。合并前工作区已清理；未跟踪 `.antigravitycli/` 已单独 stash 保留；`main <- refactor/oklch-color-system` 无冲突。合并后 Debug build PASS，`COLOR_SYSTEM_SELF_CHECK=1` ALL PASS。

本轮只处理明确问题，不继续追两首特定 Track ID 在 Cover Blur / 大封面皮肤下的 MiniPlayer 控件灰色半透明、hover 跳色、progress / spectrum / volume 中间态问题。这些复杂状态问题继续保留 backlog。

- [x] **NearMono Art Shapes preset 审美微调**：仅改 true NearMono Art Shapes preset。去掉 yellow；不再保留粉色主导路径；palette 收敛为极低 chroma 的淡蓝、青蓝、薄荷、偏紫蓝。BK 主背景仍走原有中性 nearMono 背景，不把 shape preset 回染到 BK1/BK2。
- [x] **Cover Blur queue current row foreground**：队列 current row 不再从 `miniPlayerControl.primary` 读取固定浅色 accent。`FullscreenQueueView` 继续复用 MiniPlayer foreground strategy 的明暗 profile 判断，但队列内部只切换自己的 text palette tier：亮封面走 dark queue foreground，暗封面走 light queue foreground。
- [x] **Artistic light queue current row foreground**：Artistic light 继承 MiniPlayer strategy 的 dark profile；Artistic dark 保持 light profile。普通 row 与 current row 使用同一套 queue text hierarchy，current row 仅通过 weight、speaker icon 和 current background 强调。

退出状态（2026-05-23）：Debug build PASS；`COLOR_SYSTEM_SELF_CHECK=1` ALL PASS。未进入 Phase 7。

### Phase 7 — 清理旧 HSL 分叉、文档收尾、回归验证

- 删除 HSL 分叉路径；保留 `ColorMath` 但只剩 OKLCH。
- 关闭所有 fallback / 兼容 shim。
- 对照报告 J / K / Appendix A 的"原始事实快照"做一次最终回归。

退出条件：搜索"`.usingColorSpace(.deviceRGB)` + 手算 HSL"应只剩调试 / 日志路径；UI 路径全部通过 OKLCH token。

***

## 3. Phase 0 详细执行表

本阶段的边界规则（**全部都要遵守**）：

- 不开始 OKLCH 主迁移；
- 不调整 `SemanticPaletteFactory` 的审美 magic numbers；
- 不修改 Ultra Dark / Near Monochrome 判定逻辑；
- 不实现 salient highlight palette；
- 不改 Home Shapes / BKArt / Spectrum 的真实多色方案；
- 不改 MiniPlayer 控件色语义化；
- 不改歌词颜色策略；
- 不改 Header 路径瘦身；
- 不做 Tone Ladder。

只做：**文档准备 + 前置清理 + 已确认遗留修复**。

### 0.1 修复 `ArtworkAssetStore` 缓存版本号漏洞

| 字段       | 内容                                                                                                                                                                                                                                                                                                                                                        |
| -------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题       | `ArtworkAssetStore` 的 in-memory snapshot 缓存 key 是 `"\(trackID.uuidString)-\(artworkChecksum)"`，**不包含颜色提取算法版本号**。`ThemeStore` 自己的 `dominantColorCache` 已经按 `colorExtractionCacheVersion` 命名，但走 `ArtworkAssetStore` 的路径绕过了这道防线。当颜色算法升级时（比如这次 R4 之后任何一次对 `analyze` 的修改），旧 snapshot 中的 `accentColor` / `dominantColor` / `palette` / `averageColor` 仍会被新逻辑读取。 |
| 根因       | `ArtworkAssetSnapshot.cacheKey`（`Models/ArtworkAssetSnapshot.swift:24`）以及 `ArtworkAssetStore.get(trackID:artworkChecksum:)` 的 key 都没把算法版本绑进 key 域。                                                                                                                                                                                                        |
| 修复目标     | 让 `colorExtractionCacheVersion` 成为 snapshot 缓存命中条件的一部分。算法版本一变，旧 snapshot 自动失效，**新 snapshot 仍能写入并复用**。                                                                                                                                                                                                                                                     |
| 预计涉及文件   | `myPlayer2/Models/ArtworkAssetSnapshot.swift`、`myPlayer2/Services/Artwork/ArtworkAssetStore.swift`、`myPlayer2/Services/Theme/ThemeStore.swift`（共享版本号常量）。                                                                                                                                                                                                  |
| 非目标      | 不重构 `ArtworkAssetStore` 的 actor 结构；不引入持久化缓存；不动 `LibraryDetailHeaderView` / `HomeHero` 各自的本地缓存键。                                                                                                                                                                                                                                                           |
| 验收标准     | (1) 算法版本字符串变更后，`get(trackID:artworkChecksum:)` 无法命中旧 entry；(2) 同版本下新 entry 仍能正常 cache / hit；(3) 不引入额外的 race（in-progress 合并仍工作）；(4) 不破坏现有异步取色 / hydration 路径。                                                                                                                                                                                              |
| 实现选择（备注） | 把 `colorExtractionCacheVersion` 抽到一个 module-level 静态常量（或 `ArtworkColorExtractor` 的 nonisolated static），然后在 `ArtworkAssetSnapshot.cacheKey` 上拼接前缀。理由：单点修改、所有 cache 自动跟随、零额外字段开销。**不**选"snapshot 内嵌 cacheVersion 字段"路线，那个方案要求每个 reader 主动校验，容易漏。                                                                                                            |

### 0.2 清理歌词 Swift → Web 颜色死字段

| 字段     | 内容                                                                                                                                                                                                                                                                                                                                                         |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | 报告 R3 J.1 / R4 J.1.c 已确认：CSS 变量 `--amll-bg` / `--amll-accent` / `--amll-shadow` 在 `index.html`、`style.css`、`amll-core.js`、`amll-lyric.js` 里**全部 0 消费**；迁移前残留的 `lyrics-renderer.js` 已在 2026-05-31 清理删除。`config.shadowColor` JSON 字段是经 A/B 测试明确弃用（`index.html:5383-5392` 只剩 `textShadow = "none"` 的善后分支）。`ThemePalette.shadow` 与 `ThemePalette.accent` 字段在 Swift 侧除"把它写给 web"以外无任何消费者。 |
| 根因     | 历史上歌词 web 层还有完整的"主题色"契约；新版 AMLL 渲染器改用 `--amll-active` / `--amll-inactive` / `--amll-lp-color` 后，旧契约一直没清。                                                                                                                                                                                                                                                   |
| 修复目标   | 把"无人消费 / 已弃用"字段彻底从类型 → 序列化 → JS 注入三层移除：① `ThemePalette.shadow` 字段；② `ThemePalette.accent` 字段；③ `applyEffectiveTheme` 中的 `--amll-bg` / `--amll-accent` / `--amll-shadow` CSS 注入；④ `config.shadowColor` JSON 字段；⑤ `index.html` 中 `hasOwn("shadowColor")` 善后分支（在 4 完成后永远不会触发）。                                                                                |
| 预计涉及文件 | `myPlayer2/Services/Theme/ThemeStore.swift`、`myPlayer2/Services/Lyrics/LyricsWebViewStore.swift`、`myPlayer2/Resources/AMLL/index.html`。                                                                                                                                                                                                                    |
| 非目标    | 不动 `--amll-active` / `--amll-inactive` / `--amll-lp-color`（仍是 live 契约）；不动 `--amll-text` CSS 变量（虽然当前 0 消费，但不在用户明确清理列表里，留给后续阶段评估）；不动 `palette.background` Swift 字段（被 `ThemeStore.backgroundColor` → `LyricsPanelView` 消费）；不改歌词实际视觉。                                                                                                                          |
| 验收标准   | (1) 项目内搜索 `ThemePalette.shadow` / `palette.shadow` / `palette.accent` / `palette?.accent` / `palette?.shadow` 应无残留；(2) 项目内搜索 `--amll-shadow` / `--amll-bg` / `--amll-accent` 应无残留（除已注释的死代码或.bak2 备份）；(3) `index.html` 内 `hasOwn("shadowColor")` 分支已移除；(4) 构建通过；(5) 歌词主面板与全屏歌词的 active / inactive 颜色保持不变。                                                   |

### 0.3 统一 `MiniPlayerSpectrumView` fallback

| 字段     | 内容                                                                                                                                                                                                                |
| ------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | `MiniPlayerSpectrumView.resolveStaticAccent` 在 `accentColor == nil` 或无法转 RGB 时降到 `NSColor(white: 0.7, alpha: 1.0)`，与全局默认 accent `#E6C799`（`AppSettings.shared.accentColorHex` / `ThemeStore.defaultBlueNS`）口径不一致。 |
| 根因     | 局部硬编码，没复用项目已有的默认 accent。                                                                                                                                                                                          |
| 修复目标   | fallback 改读项目级默认 accent（来源优先级 `ThemeStore.shared.defaultBlue` → `AppSettings.shared.accentColor`），避免再造第三套常量。                                                                                                      |
| 预计涉及文件 | `myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift`。                                                                                                                                                        |
| 非目标    | 不改 `resolveArtworkFaithfulColors` 内部的 tuning；不改 `adjustedSpectrumBase` 的 saturation / brightness 曲线；不改正常路径下从父视图传入 accent 的行为。                                                                                     |
| 验收标准   | (1) 显式传入 accent 的路径保持原本行为；(2) 不传 accent / accent 无法转 RGB 时，spectrum 颜色基线为 `#E6C799` 而非中性灰；(3) 不引入新的 module-level 常量。                                                                                              |

### 0.4 修复 `ClassicLEDSkin` 固定黑阴影

| 字段     | 内容                                                                                                 |
| ------ | -------------------------------------------------------------------------------------------------- |
| 问题     | 报告 C.4 "B 类潜在 bug"：`ClassicLEDSkin` 的封面阴影固定 `Color.black.opacity(0.35)`，浅色模式下偏重。                   |
| 根因     | `.shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)`（`ClassicLEDSkin.swift:92`）不分支深浅模式。 |
| 修复目标   | 阴影 opacity 按 `colorScheme` 分支：暗色保留 0.35（原始厚重感），浅色下沉到 0.18，避免在浅色封面下压抑过头。                            |
| 预计涉及文件 | `myPlayer2/Skins/NowPlaying/ClassicLEDSkin.swift`。                                                 |
| 非目标    | 不扩展成 LED 整体视觉重设；不动 radius / offset / 内部 `PillSpectrumView`；不引入按 artwork 派生的阴影色。                    |
| 验收标准   | (1) 暗色模式阴影视觉与现状一致；(2) 浅色模式阴影明显减弱；(3) 仅修改阴影 opacity，不改其它参数。                                         |

### 0.5 修复 `FullscreenCoverGradientBlurSkin` 占位 icon 固定白色

| 字段     | 内容                                                                                                                                                                                                                                                                                    |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | 报告 C.4 "B 类潜在 bug" 标注 "FullscreenCoverGradient 箭头 `Color.white.opacity(0.5)`"。实际实现位于 `FullscreenCoverGradientBlurSkin.swift:186` 的 `CoverGradientBlurArtwork` 私有占位视图：当 `context.track?.artworkImage` 为 nil 时，绘制一个 `music.note` 占位 icon，固定 `.white.opacity(0.5)`。在浅色背景或亮 cover 下可读性不稳。 |
| 根因     | 固定白色，不响应当前 `colorScheme` 或 artwork 可读性判定。                                                                                                                                                                                                                                             |
| 修复目标   | icon 颜色改为跟随 `@Environment(\.colorScheme)`：暗色下保留白半透明，浅色下用 `.primary.opacity(0.45)`。复用 SwiftUI 现成的语义色，不为这一处单独造一个可读性判定。                                                                                                                                                                  |
| 预计涉及文件 | `myPlayer2/Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift`。                                                                                                                                                                                                                   |
| 非目标    | 不改 `CoverGradientBlurArtwork` 的 placeholder gradient / shadow / overlay 描边；不动 `makeArtwork` 返回 `EmptyView()` 的事实（这意味着 `CoverGradientBlurArtwork` 当前其实是 dead code，但该结论应交给后续 Phase 7 清理时再处理，本轮不删活路径之外的"似死非死"代码）。                                                                        |
| 验收标准   | (1) 暗色模式占位 icon 视觉与现状一致；(2) 浅色模式占位 icon 不再是高对比白；(3) 编译通过。                                                                                                                                                                                                                             |

### 0.6 评估但**不**强制扩大：`MiniPlayerSpectrumView` 与 `LedMeterView` 的 colorScheme 响应方式

| 字段   | 内容                                                                                                                   |
| ---- | -------------------------------------------------------------------------------------------------------------------- |
| 问题   | `LedMeterView` 直接 `@Environment(\.colorScheme)`；`MiniPlayerSpectrumView` 走父视图传 `usesDarkForeground: Bool`。两条路径风格不一致。 |
| 评估目标 | 判断是否有真实刷新遗漏。如果没有 → 本轮**不动**，只在 migration log 中登记为"后续架构一致性项"。                                                         |
| 验收   | 在 migration log 中给出结论。如果决定本轮改，仍要尊重边界（不破坏调用方传 accent 的路径）。                                                            |

***

## 4. 退出 Phase 0 的条件

- 上述 0.1–0.5 全部完成；0.6 已经给出书面结论。
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build` 通过。
- 项目内不再有死字段引用（0.2 验收项 1–3）。
- `docs/oklch-color-system-migration-log.md` 已写入 Phase 0 的完整记录。
- 工作树没有计划外的修改散落。

下一步：进入 Phase 1（颜色规则 token 化 + OKLCH 公共数学层）。
