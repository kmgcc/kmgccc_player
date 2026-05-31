# AMLL 自定义行为与 Patch Registry

本文是新版 AMLL 接入后的长期维护入口，回答“当前 App 到底对 AMLL 自定义了什么”。迁移审计与计划见 `docs/amll-upgrade-migration-audit.md`；升级过程历史见 `docs/amll-upgrade-implementation-log.md`；歌词提前量算法细节见 `docs/amll-lyric-advance-algorithm.md`。

## A. 当前保留的产品行为

| 行为 | 目的 | 当前实现层 | 维护说明 |
|---|---|---|---|
| 独立 parser bundle | 新版 core 不再 re-export parser，App 仍需要 `parseTTML`。 | Fork `packages/lyric/src/myplayer-app.ts` + App `Resources/AMLL/amll-lyric.js` | 通过 `scripts/sync-amll-from-fork.sh` 构建同步；不要把 parser 再假设为 core export。 |
| DOM `LyricPlayer` 专用 core bundle | App 使用普通 DOM renderer，不使用 canvas/dom-slim。 | Fork `packages/core/src/myplayer-app.ts` + App `Resources/AMLL/amll-core.js` | 后续 AMLL 内部修复集中看 `lyric-player/dom`、base/timeline/layout；不要改 dom-slim，除非 App 明确启用。 |
| 独立 Mesh Gradient background bundle | Apple 风格播放皮肤复用 AMLL 官方 `BackgroundRender` + `MeshGradientRenderer`，但不把 bg-render/Pixi 路径塞回歌词 core bundle。 | Fork `packages/core/src/myplayer-background.ts` + App `Resources/AMLL/amll-background.js` / `background.html` | 通过 `scripts/sync-amll-from-fork.sh` 构建同步。背景 bundle 只服务播放皮肤背景，不承载歌词 API。 |
| `timeOffsetMs` | 单曲偏移与全局提前量共同调整歌词视觉时间。 | App `index.html` setLyrics preprocessing | 这是 App 时间轴 adapter，不属于 AMLL public API；seek 不应使用全局提前量。 |
| `seekTimeOffsetMs` | 用户点击歌词时跳到音频真实对齐位置。 | App `index.html` seek line start table | 只包含单曲偏移，不含 `globalAdvanceMs`；保持和 `timeOffsetMs` 分离。 |
| `leadInMs` / `nearSwitchGapMs` | 近距离换行时提前切到下一行，让切换更干脆。 | App `index.html` timing preprocessing | 只改变送入 core 的 lyric line timing；不要把原始相邻行制造成结构 overlap。细节见 `docs/amll-lyric-advance-algorithm.md`。 |
| Exit highlight catch-up | 提前切行时，退出行剩余逐字高亮在退场期间补完。 | Fork core DOM line lifecycle + App overlay adapter | 窗口歌词需要 core mask animation 继续；fullscreen/cover blur overlay 只识别 `data-amll-exit-catch-up` 做可见性适配。 |
| 减弱高亮 / 离散逐字逐词高亮 | 设置项“减弱高亮(beta)”打开后，不再连续扫光，而按字/词整体 opacity 淡入，降低高亮移动干扰。 | Fork core DOM line mask branch + App config adapter | App 下发 `wordHighlightMode: "discrete"`；core 默认仍是 `"smooth"`。离散视觉参数沿用旧成熟版：18 帧 log opacity easing `2.2`、fade duration `300ms...2000ms`、窗口 inactive `0.28`、BG `0.4`、fullscreen `0`。每个 word/char 使用独立 `delay + duration` envelope，允许相邻短字/短词并行 fade。退场复用当前 `data-amll-exit-catch-up` 与 fullscreen opacity fade；window inline opacity 在 disable/catch-up 完成后淡回 inactive。不恢复旧 exit data / suppress / hide-show hack。 |
| CJK emphasis 连续波 | 连续 CJK 长时值词组恢复旧 upstream 的 staggered emphasis envelope，让相邻字处于不同上浮、放大、辉光进度。 | Fork core `utils/lyric-split-words.ts` | 对连续 CJK run 使用 `Intl.Segmenter` 重新分成语义 chunk；没有 `Intl.Segmenter` 时退化为新版逐 atom 行为。 |
| Fullscreen completed highlight 保持 | 并行显示组中已唱完但未退场的行保持完整高亮。 | App `index.html` `updateFullscreenParallelHighlightState()` + CSS | `data-fs-completed-highlight` 表示“仍在组内”，不是 catch-up。opacity fade 应绑定真实退场。 |
| Fullscreen active overlay lifecycle replay | 修复全屏当前行 active 高亮层在首次进全屏、seek、低/中渲染质量下丢失或卡住。 | App `index.html` fullscreen / cover-blur adapter | AMLL DOM line 是懒构建：`enable()` 可能先于 `show()` / `rebuildElement()`，当时 `splittedWords` 与 mask/emphasis animations 仍为空。fullscreen / cover-blur overlay 必须在 line `show()` / `rebuildElement()` 后可重入补建 `.amll-fs-*` / `.amll-cb-*` 层，并用当前播放时间重新调用 line `enable(currentMs, playing)` 同步 cloned animations。不要用固定延迟或改 generated bundle 遮盖。诊断日志前缀为 `[AMLLActiveHighlight]`，需覆盖 active line index、built / inSight、`splittedWords`、layer count、animation currentTime、surface role、render scale、DPR。 |
| Existing line position-spring reveal | 同一首歌关闭/打开歌词 surface 时，让已加载的 DOM line 围绕当前播放行重新显示：上方行从上方靠近、下方行从下方靠近。 | App `bridge.js` / `index.html` `revealExistingLyrics()` + Swift visibility adapter (`LyricsPanelView`, `LyricsFlatDriverView`, `FullscreenPlayerView`) | AMLL 官方没有正式命名的“聚拢动画”API；准确机制是现有 `LyricLineEl.lineTransforms.posY` position spring reveal。App 只重置当前行附近 line 的 `posY` current position，再调用 `calcLayout()` 设置原目标位置，保留当前歌词数据和播放时间。禁止用 `forceLyricsReload` / `setLyrics` / `setLyricLines` 代替：那会重建 line objects 并触发新歌词首次布局的整体上涌动画。 |
| Fullscreen / artistic emphasis glow live retint | App 深浅色模式、艺术背景歌词 palette 或 fullscreen surface profile 中途变化时，已 built 的官方 emphasis glow clone 必须同步换色，不依赖切歌重建。 | App `index.html` fullscreen / cover-blur adapter | `fullscreenEmphasisGlowColor` 与 cover-blur glow profile 最终写进 cloned Web Animation keyframes，CSS 变量变化不会让已存在 keyframes 自动重算。adapter 在 clone 时缓存官方原始 emphasis keyframes；theme/config/profile 变化时从原始 keyframes 轻量 `setKeyframes()` retint，并保留 currentTime/playState。未来懒构建行通过同一 clone 入口读取最新配置。日志前缀 `[AMLLThemeGlow] fullscreen-sync`。不要通过重新 `setLyrics` 或固定 delay 修复。 |
| Fullscreen CSS module selector 兼容 | 新版 CSS module hash 形态变化后，fullscreen overlay 仍能识别 lyric line/active/sub/bg。 | App `index.html` CSS/JS selector adapter | 使用 `[class*="lyricLine"]` / `[class*="active"]` 等语义片段；避免回退到旧 `[class*="_active_"]`。 |
| 普通 fullscreen 明度语义 | 普通全屏主要通过颜色明度区分层级，不靠整体 opacity 发灰。 | App `index.html` fullscreen CSS variables / overlay | 修 fullscreen 视觉时先确认 surface role；不要把 cover blur 的透明合成语义套到普通 fullscreen。 |
| Cover blur 混合模式语义 | 封面渐变模糊全屏允许透明度和 blend 参与合成。 | Swift fullscreen config + App `index.html` CSS | 当前 generic cover blur highlight 主要共用 `.amll-fs-*` 路径；legacy `.amll-cb-*` 路径仍保留兼容。 |
| Swift-owned lyrics color contract / near-mono neutralization | 歌词颜色决策归 Swift，避免 Swift + Web 双端重复选择 hue，并防止 nearMono artwork 的微弱残留 hue 被 fullscreen/Web 派生逻辑放大成粉、蓝、黄。 | Swift `SemanticPalette.lyrics` + App `index.html` adapter | Web rendering-only / adapter contract：Web 可保留 opacity、mix-blend-mode、text-shadow、drop-shadow、shadow structure 与兼容 fallback，但不得重新决定 hue。`syncFullscreenDerivedColors()` 必须优先消费 Swift 显式颜色，缺失时才 fallback 派生。nearMono lyrics neutralization 要求 visible colors OKLCH chroma ≤ 0.005。 |
| Artistic fullscreen lyrics Tone Ladder (v3 seed-trust) | 艺术背景类 fullscreen lyrics 用不透明 OKLCH tone ladder 表达 active / inactive / secondary 层级。v3 在 v2 single-seed 基础上加 seed-trust 契约：当 seed `c ≥ lyricsSeedChromaPreferred` 时 Tone Ladder **忽略** `isNearMonochrome` 参数，且 `artisticFullscreenLyricsColorSet` 跳过尾部的 `neutraliseLyricsSurfaceIfNearMono`。v2 失败的根因是 `ArtworkColorAnalysis.neutralFallback` 把 `isNearMonochrome=true` 注入 Tone Ladder，使彩色 seed 在 Swift 内就被 clamp 成 OKLCH `c≈0.004`，屏幕落色 `#808284`。 | Swift `PerceptualToneLadder.artisticLyricsTone` + `SemanticPaletteFactory.artisticFullscreenLyricsColorSet(...)` + `FullscreenPlayerView.resolveFullscreenLyricsInactiveBaseColor(...)` + `ColorSystemDiagnostic.describe(...)` | 仅在 Swift 侧 `settings.fullscreenArtBackgroundEnabled` 路径启用；Web 继续只消费显式颜色与渲染结构，不重新决定 hue。`resolveFullscreenLyricsInactiveBaseColor(...)` 不允许引用 BKArt surface background / `primaryBackgroundColor` / `lockedFullscreenLyricsBackgroundColor` 三条旧路径（v1 灰白化根因）。inactive C ≥ active C × 0.85、hueΔ vs seed ≤ 0.025。sub-inactive L 与 main-inactive L 差 ≤ 0.060（v3 翻译行不再偏暗）。Apple / Cover Gradient / Cover Blur profile 保持原 lighter/darker blend 语言。nearMono **+** grey seed 的双重信号仍输出 OKLCH chroma ≤ 0.005；只要 seed 有可视 chroma，无论 analysis bit 为 true 或 false，输出都保持 ≥ 0.040 的色彩身份。Self-check 必含 v3 四条新增回归门：`ToneLadder v3: colourful seed survives isNearMonochrome=true`、`Lyrics v3: artistic path keeps colour under .neutralFallback analysis`、`Lyrics v3: sub-inactive L close to main-inactive L`、`LED v3: low-level hue drift visible vs peak`。`COLOR_SYSTEM_LYRICS_DEBUG=1`（或艺术背景启用时自动）会在 `Log.debug(.theme)` 打印 highlight base / inactive base / 全 6 个 role 的 `#RRGGBB (L=… C=… H=…)`，用于现场吸管色复盘。 |
| Cover blur emphasis 官方链路 adapter | 大封面渐变模糊皮肤只对官方 emphasis 的 glow 做 cover-blur 专属弱化/重染，避免重造一套独立 glow 动画。 | App `index.html` generic cover blur adapter（CSS + bridge JS） + Swift base/highlight overlay | `installFullscreenEmphasizedGlowLayer()` 只给强调词 `.amll-fs-word-stack` 写入 `data-amll-fs-emphasis-body="1"`，让 highlight-only WebView 恢复强调词主填充；不再创建 `.amll-fs-cover-blur-glow-layer`。`installFullscreenPackedElementAnimations()` 继续按官方 per-character target clone `emphasize-word-*`，保留 scale / translate / duration / delay / stagger，只在 clone keyframes 中对 `textShadow` 做 profile retint/rescale；base 层 `coverBlurSuppressEmphasisGlow=true` 时仅把 `textShadow` 置为 `none`，不移除 transform。当前 glow profile 为 lighter `rgba(255,255,255,0.12) × 1.0`、darker `rgba(0,0,0,0.16) × 1.0`。profile / suppress / theme color 变化时必须走 `[AMLLThemeGlow] fullscreen-sync` live retint，不等待切歌。普通 window 不进入 cover-blur profile 调整。 |
| Window/main emphasis glow 配色 adapter | 窗口主歌词在浅色调色板（深字 + 浅底）下，官方 `rgba(255,255,255,glowLevel)` emphasis 辉光基本看不见。adapter 仅在 light 模式下把 textShadow 的颜色改为深色低 α 光晕，让长时值强调有可见、低噪的视觉收尾。深色调色板（白字 + 深底）保持官方白色光晕不变。 | App `index.html` `applyWindowEmphasisGlowScheme()` / `retintSingleWindowEmphasisAnimation()` / `installWindowEmphasisGlowLifecycleHooks()` | 只在 `surfaceRole === "main"` 启用；fullscreen / fullscreen cover-blur / batch preview 不进入此分支。检测信号是 Swift 通过 `config.theme = "light" \| "dark"` 下发的 app appearance；不再使用 `config.textColor` 亮度推断（之前的亮度路径与 config 顺序竞争，导致 light 模式下 halo 看不见）。`LyricsViewModel.refreshConfigFromSettings()` 与 `LyricsWebViewStore.applyEffectiveTheme()` 都会带 `theme` 字段，appearance 翻转时也会重发。改写发生在 `KeyframeEffect.setKeyframes()` 上，每个 emphasis 动画首次改写前会缓存 `__windowEmphasisOriginalKeyframes`，scheme 翻转时使用缓存还原。由于 AMLL line 懒构建，adapter 还必须 hook line `show()` / `rebuildElement()`，让未 built 的行在未来进入视口时也按最新 scheme retint。日志前缀 `[AMLLThemeGlow] window-sync` / `window-line-built`。当前 light profile 为 `rgba(0, 0, 0, source.a × 0.55)`。 |
| 歌词渲染质量三档 | 按“低 / 中 / 高”控制 WKWebView 实际渲染分辨率，减轻渲染压力或使用原生分辨率。 | Swift/WebView adapter | 真实低分辨率路径是 WKWebView frame 按质量档缩小、`pageZoom` 按同一质量档缩小，再用 layer inverse scale 放回原视觉尺寸；低 `0.5`，中 `0.75`，高 `1.0`。2026-05-17 A/B 已否定 contentsScale-only：完整 frame + `pageZoom = 1` + identity transform + 只改 layer `contentsScale` 看起来仍是 1.0x，不能代表真正的低分辨率 WebView 渲染，也不能改善 1.0x emphasis snap。旧 `amllHighResolutionLyricsEnabled=true` 迁移为高，false/缺失迁移为中。AMLL DOM `renderScale` 必须继续使用各 surface 的默认 renderer scale（窗口/全屏/cover blur 为 `0.75`，batch preview 为 `0.45`），不要用用户质量档位驱动 `LyricPlayer.setRenderScale()`。 |
| 歌词 surface hover / selection policy | 不显示窗口/全屏 hover 圆角背景；拖动时不允许选中文字。 | App `index.html` CSS | Upstream hover 背景真实来源是 `packages/core/src/styles/lyric-player.module.css` 中 `.lyricLine:has(> *):hover/:active` 使用的 `--amll-lp-hover-bg-color`。App adapter 对所有歌词 surface 将该变量置为 `transparent`，不维护 host-driven hover proxy。文本选择通过 `.amll-lyric-player` 子树的 `-webkit-user-select: none` + `user-select: none` 禁止；不加 JS `selectstart` 防线，除非未来证明 CSS 在目标 WebKit 下不足。 |
| 翻译歌词字体控制 | App 设置控制翻译字体大小/字重。 | App `index.html` CSS variables + semantic selector | 依赖新版 CSS module 语义 selector，例如 `[class*="lyricSubLine"]`；不要绑定旧 hash。 |

## A.1 Swift-owned lyrics color contract / near-mono neutralization

目的：

- 避免歌词颜色逻辑散落在 Swift 与 Web 双端，导致 `ThemeStore`、`SemanticPalette`、`FullscreenPlayerView`、`LyricsWebViewStore`、AMLL adapter 各自维护一套近似但不一致的派色规则。
- 避免 nearMono artwork 下的微弱 residual hue 被 Web 或 fullscreen 派生逻辑放大成粉色、蓝色或黄色。
- 为后续 AMLL 升级保留清晰边界：AMLL adapter 负责渲染结构，App Swift 色彩系统负责颜色决策。

规则：

- Swift 侧输出 window / fullscreen / cover blur 等 surface color set；当前入口为 `SemanticPalette.lyrics`、`LyricsColorPalette`、`LyricsSurfaceColorSet`、`LyricsCoverBlurBlendProfile`。
- Phase 6 v2 / v3 后，艺术背景类 fullscreen lyrics 通过 single-seed `PerceptualToneLadder` 深化 `LyricsSurfaceColorSet`；v3 引入 seed-trust，绕过 `analysis.isNearMonochrome` 在 colourful seed 上的双重 clamp；Phase 6.1 继续在同一 Swift-owned 层加入 chroma soft shoulder、dominant-first seed selection、scheme-aware L 表（日间反相）。仍是 Swift 端决策，Web adapter 不需对应改动。
- Web 侧不得重新选择 hue，不得用 CSS/JS 派生覆盖 Swift 已下发的语义色。
- Web 侧可以保留 opacity、mix-blend-mode、text-shadow、drop-shadow、shadow structure、line-state class、动画 clone 等渲染行为。
- `syncFullscreenDerivedColors()` 必须优先使用 Swift 显式颜色；fallback 派生只允许作为旧配置或缺省状态的兼容路径。

Phase 6.1 增量 — 日间模式 / 反相歌词 / 高饱和软压：

- Swift 通过 `colorScheme` 自动决定艺术 fullscreen lyrics 走 dark（高 L 高亮）还是 light（低 L 反相）。Swift 下发的字段名与 CSS 变量名不变：
  - `fullscreenActiveColor` → `--amll-fs-main-active`
  - `fullscreenInactiveColor` → `--amll-fs-main-inactive`
  - `fullscreenSubActiveColor` → `--amll-fs-sub-active`
  - `fullscreenSubInactiveColor` → `--amll-fs-sub-inactive`（translation 行）
  - `fullscreenBackgroundColor` → `--amll-fs-bg-active`（= `colorSet.subActive`，沿 v3 行为）
  - `fullscreenLineTimingInactiveColor` → `--amll-fs-main-line-timing-inactive`
  - `fullscreenLineTimingSubInactiveColor` → `--amll-fs-sub-line-timing-inactive`
- Interlude dots `[class*="interludeDots"] > *` 的 color fallback chain 是 `var(--amll-fs-main-active, var(--amll-active, var(--amll-lp-color, white)))`；Swift 下发的 active 颜色会被自动套用，日间反相时 dots 自动变深。
- Background lyric base 是 `var(--amll-fs-sub-color, var(--amll-fs-main-inactive, …))`；Swift 不下发 `--amll-fs-sub-color`，自然落到 `--amll-fs-main-inactive`，日间反相时背景歌词自动变深。
- Glow / shadow 用 `currentColor` 推导，与 lyric color 同步，反相后自动变深。无硬编码白色阴影。
- 因此 Phase 6.1 **不修改** `amll-core.js` / `amll-lyric.js` 生成 bundle，也**不修改** `index.html` 的 CSS 变量名或 fallback chain。

Phase 6.1 seed-selection 与 chroma soft shoulder（Swift 内部）：

- `SemanticPaletteFactory.artisticLyricsSingleSeed` 改为：nearMono → preferred；`pickSalientLyricSeed` 通过则用 `salientHighlightPalette.first`（要求 cover 主域均匀 + salient 与 dominant hue 距 ≥ 0.08 + salient OKLCH chroma ≥ 0.09）；否则用 `analysis.dominantColor`（OKLCH c ≥ 0.025）；都失败再走 candidate scan 兜底。
- `PerceptualToneLadder.artisticLyricsTone` 在彩色路径下先 `OKColor.chromaSoftShoulder(ceiling=0.095, softness=0.045)` 再 clamp 到 hue-family cap；日间用 ceiling=0.072 / softness=0.030 / cap*0.72。
- 这些都属于 Swift-owned decision，Web 不感知。

Phase 6.2 增量 — focus-score seed / nearMono trust override / 反粉红 shapes / 日夜 token 收尾（2026-05-21）：

- `SemanticPaletteFactory.focusScore(...)` 用连续打分替代 Phase 6.1 的 4-AND 硬 gate：`visualContrast × salience × fieldUniformity × designFocus - noisePenalty/competing`，阈值 0.55。`visualContrast` 在 dominant.c < 0.045（真灰/真黑）时把 hue distance 当作 max contrast，让 "黑底 + 5% 亮黄" 这种典型设计封面能稳定 fire。
- `ArtworkColorAnalysis` 引入 `trustedHueChromaFloor=0.045`：dominant / topPalette / salient 任一 OKLCH chroma ≥ floor 即跳过 nearMono 非严格分支。pure-grey / 极暗封面仍 nearMono。
- `BKColorEngine.make(...)` 末尾在 true nearMono 且无 trusted hue 候选时对 bgStops / shapePool / dotBase / bgVariants 做 OKLCH chroma crush 到 ≤ 0.008（`OKColor.neutralise`），消除淡粉残留。
- `PerceptualToneLadder.artisticLyricsTone` 的 soft shoulder 改为 gated：只有 `base.c × chromaScale >= lyricsHighChromaShoulderTrigger=0.085` 才生效；mid-C seed 穿过原样到 cap。
- 夜间 token: active L 0.905 → 0.920、sub-active 0.830 → 0.855、UltraDark inactive trim 0.060 → 0.095、active/sub-active chromaScale 0.92/0.96 → 0.98/1.00。
- 日间 token: active L 0.150 → 0.215（不死黑）、inactive 0.430 → 0.470、translation 0.435 → 0.475、line-timing 0.470/0.500 → 0.510/0.540。严格升序保持。
- `BKColorEngine.tierRanges` 夜间: `bgB` 0.18…0.32 → 0.14…0.28、`fgB` 0.34…0.54 → 0.28…0.46、`dotB` 0.46…0.68 → 0.40…0.58（dotB.upper 等于 inactive L floor 0.580）。日间: `bgB` 0.88…0.95 → 0.92…0.97、`fgB` 0.78…0.88 → 0.80…0.90、`dotB` 0.62…0.74 → 0.66…0.78、`bgS` 上限 0.30 → 0.22 避免 pastel。
- `FullscreenMiniPlayerView` 新增 `usesDarkControlForegroundForLightArtisticBackground`：日间艺术背景 + `hasArtworkThemeColor` → `controlPrimaryNSColor = readabilityProfile.foregroundPrimary`（dark on bright artistic glass，自动获得 Phase-4 nearMono 反粉红行为）。
- glow / interlude dots / background lyric / translation 仍走 CSS fallback chain，无需新 CSS 变量；**未修改** `amll-core.js` / `amll-lyric.js` 生成 bundle、`index.html` CSS 变量名 / fallback chain、`bridge.js`。
- Phase 6.2 进一步（2026-05-21）：在 v3 seed-trust 之上 (a) Phase 6.1 salient hard gate 升级为连续 focusScore；(b) `analysis.isNearMonochrome` 受 trusted-hue 覆盖；(c) chroma soft shoulder 改为只在 scaled C ≥ 0.085 时触发；(d) 夜间 active L 0.905 → 0.920、UltraDark inactive trim 0.060 → 0.095；(e) 日间艺术背景 bg / shapes 大幅提亮；(f) 日间歌词 active L=0.150 改为 0.215（不死黑），仍严格 ASC 且 < bg L；(g) FullscreenMiniPlayer 日间艺术背景下控件主色切到 dark foreground readability profile。glow / interlude dots / background lyric 仍走 CSS fallback chain 自动跟随 Swift 下发色，**无 generated bundle / index.html 改动**。Self-check 新增 20+ 个 Phase 6.2 场景；3 个既有测试更新以反映 Phase 6.2 语义。

Phase 6.3 增量 — artistic color system stabilization（2026-05-22，2026-05-23 人工复测未通过）：

- Phase 6.3 的 nearMono / trusted hue、focus score、BK true-nearMono neutralise、日间 light tier、MiniPlayer dark foreground 和 ThemeStore pending hold 都是中间实现尝试，不能再写成已修复事实。
- 人工复测确认：小面积强焦点仍不稳定；有色封面仍会被 nearMono 灰白化；true nearMono 下 floating shapes 淡粉有回归；日间艺术背景仍偏暗；日间歌词 active / inactive 仍阴沉；Fullscreen MiniPlayer UI 仍有多条颜色路径；切歌仍会闪 default / 错误深浅色。
- `fullscreenEmphasisGlowColor` 由 Swift 下发、App `index.html` adapter 消费的 dark glow 方向保留；后续需确认不要回退，但不应把 hue 决策放回 Web。
- AMLL active/inactive highlight transition / feather 本轮不处理，继续作为 backlog；不改 fork core、不手改 `amll-core.js` / `amll-lyric.js`。

Phase 6.4 增量 — artistic architecture stabilization（2026-05-23，2026-05-23 人工复测未通过）：

- Swift-owned lyrics color contract 不变；Web / AMLL adapter 仍只消费 Swift 下发颜色。本轮未修改 `index.html`、`bridge.js`、fork core 或 generated `amll-core.js` / `amll-lyric.js`。
- Phase 6.4 曾尝试把日间 UltraDark 限定为 dark-scheme-only、统一 Fullscreen MiniPlayer / bottom controls 的 dark foreground、在 fullscreen lyrics pending 时 hold palette、让 `ArtworkAssetSnapshot.analysis` 携带 analyzer 状态；这些实现仍未通过人工验收，不能写成最终稳定架构。

Phase 6.5 增量 — artistic color system architecture repair（2026-05-23）：

- Swift-owned lyrics color contract 继续保持：AMLL Web adapter 只消费 Swift 下发的 fullscreen surface colors，不重新选择 hue。本轮未修改 `index.html`、`bridge.js`、fork core 或 generated `amll-core.js` / `amll-lyric.js`。
- nearMono 语义改为 `analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate` 才执行歌词中性化。`hasTrustedHueCandidate` 需要 palette/salient 或 dominant + real sampling support，`.neutralFallback` 的 fallback orange 不能作为真实 hue；muted coherent covers 保留颜色，true grey 仍中性。
- 日间 artistic fullscreen lyrics token 提亮为 active L=0.335、inactive L=0.620、translation L=0.622；translation 与 inactive 同层，dark emphasis glow 方向保留。AMLL active/inactive feather transition 未处理，继续 backlog。
- ThemeStore pending / fullscreen lyrics / BKArt hold 属于 Swift 状态链路修复；AMLL adapter contract 不变。AMLL active/inactive feather transition 仍是 Phase 7 / fork-core backlog；本轮继续不处理。

Phase 6.2 outstanding work / Phase 7 candidates:

- **AMLL highlight transition 内层颜色过渡**：fullscreen 线级 transition (`color .14s/.18s ease-out`) 由浏览器在 sRGB 空间做 RGB interp。per-word/character 的 mask-image / linear-gradient 边缘 "seam" 颜色由 `amll-core.js` 内联，Swift 无 CSS 变量 hook。要实现 OKLCH-interpolated mid color 需要 fork core patch（暴露 `transitionColor` / `--amll-fs-edge` CSS 变量给 renderer 消费）。本轮 Phase 6.2 不做。审计结论：见 `docs/amll-upgrade-implementation-log.md` Phase 6.2 节。

nearMono lyrics neutralization：

- Phase 6.5 起，`analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate` 时，歌词 visible colors 的 OKLCH chroma ≤ 0.005。
- 适用于窗口歌词与全屏歌词，包括 active / inactive / base / secondary / translation / cover blur 输入色。
- glow 若为设计常量白/黑可保留；若未来改为主题化 glow，不得在 nearMono 下引入彩色 hue。
- Tone Ladder 输出同样受 nearMono neutralization 约束：lyrics visible colors OKLCH chroma ≤ 0.005；LED nearMono tone cap ≤ 0.006。

AMLL 升级注意：

- 未来升级 AMLL 或重建 `index.html` adapter 时，必须保留 Swift-owned lyrics color contract。
- 不要把颜色决策重新搬回 Web / CSS，不要让 Web 根据 main color 自行选择 hue。
- 不要删除 Swift 显式颜色字段后依赖 `syncFullscreenDerivedColors()` 的 fallback 派生作为主路径。

验收：

- black / white / grey artwork 下窗口与全屏歌词不偏粉、不偏蓝、不偏黄。
- 彩色 artwork 下窗口歌词保留 Phase 5 前的基本观感与 theme tint。
- Phase 5 `ColorSystemSelfCheck` 歌词项通过：nearMono window / fullscreen / cover blur chroma ≤ 0.005，彩色窗口 tint 保留，层级合理。

## B. Fork Patch Registry

| Patch | 修改文件 | 目的 | 为什么不能放 App adapter | 默认路径是否退化 upstream | Upstream 更新风险 | 是否适合上游 PR |
|---|---|---|---|---|---|---|
| myPlayer DOM-only bundle entry | `packages/core/src/myplayer-app.ts`, `packages/core/tsdown.myplayer.config.ts` | 生成 App 可直接加载的 DOM-only browser bundle，避免 bg-render/Pixi 等非当前路径内容。 | App 只能加载构建产物，不能在运行时改变 core package export graph。 | 是。只影响 myPlayer 专用构建入口，不改变 upstream 默认入口。 | 低。更新时检查 core export 名称和 tsdown config。 | 不适合，属于 App 分发需求。 |
| myPlayer Mesh Gradient background bundle entry | `packages/core/src/myplayer-background.ts`, `packages/core/tsdown.myplayer-background.config.ts` | 生成独立 `amll-background.js`，只导出 Apple 风格背景需要的 `BackgroundRender` / `MeshGradientRenderer`。 | App 需要可在独立 WKWebView 中直接加载的浏览器 bundle；把 bg-render 合进歌词 core 会扩大稳定歌词链路的同步面。 | 是。只影响 myPlayer 专用构建入口，不改变 upstream 默认入口，也不改变 `amll-core.js` 的 DOM-only 歌词路径。 | 低中。更新时检查 `bg-render` export 名称、renderer constructor 语义和 browser bundle 是否仍无额外 runtime import。 | 不适合，属于 App 分发和解耦需求。 |
| myPlayer parser bundle entry | `packages/lyric/src/myplayer-app.ts`, `packages/lyric/tsdown.myplayer.config.ts` | 独立构建 `parseTTML` bundle，并处理旧式 TTML fallback / 中文翻译优先。 | App 需要 parser JS bundle；旧式 TTML fallback 属于 App 兼容需求。 | 大体是。优先 upstream parser，fallback 只在严格 parser 返回 0 行等兼容场景介入。 | 中。parser shape 或 package 路径变化时需重跑 parser diff。 | 部分适合。旧式 TTML fallback 可考虑上游讨论；App 语言偏好不适合。 |
| Browser production define | `packages/core/tsdown.myplayer.config.ts` | 消除 WKWebView 中的 `process.env.NODE_ENV` 运行时引用。 | 这是 bundle 构建问题，不是 App runtime 能可靠修补的问题。 | 是。只影响 myPlayer browser bundle define。 | 低。更新 tsdown 或构建链时检查产物是否仍无 `process`。 | 可能适合，如果 upstream browser build 也有同类问题。 |
| Exit highlight catch-up: seek-aware line disable | `packages/core/src/lyric-player/base/index.ts` | `setCurrentTime(time, isSeek)` 是 core 判断 seek 的入口；必须把 `isSeek` 传给退出行。 | App adapter 无法在不 monkey patch core line object 的前提下可靠区分每个 line disable 是否来自 seek。 | `isSeek=true` 时退化为 upstream 的暂停 mask 行为。普通非提前切行且无需 catch-up 时也退化 upstream。 | 中。更新时检查 `commitPlayerTimeState().linesToDisable` 调用点。 | 可能适合，若上游接受 seek-aware disable 语义。 |
| Exit highlight catch-up: abstract signature | `packages/core/src/lyric-player/base/line.ts` | 为 DOM line 提供类型化 `disable(isSeek?: boolean)`。 | 不改类型链路只能用 cast 或 monkey patch，维护性更差。 | 是。可选参数保持调用兼容。 | 低。更新时同步所有 `LyricLineBase` 子类签名。 | 仅随上一个 patch 一起考虑。 |
| Exit highlight catch-up: DOM mask continuation | `packages/core/src/lyric-player/dom/lyric-line.ts` | 提前切行退出时，让未完成 mask animations 在退出窗口内补完。 | 窗口歌词直接依赖原始 DOM mask animations；App adapter 不触碰 `splittedWords` / `maskAnimations` / `disable()` 内部字段无法覆盖窗口和 fullscreen 共同路径。 | 普通播放、非 seek、非暂停、剩余 mask 超过 16ms 才触发；其他路径退化 upstream。 | 中高。更新时对照 `enable()` / `disable()` / `pause()` / `maskAnimations` lifecycle。 | 可能适合，前提是抽象成通用“exiting line mask continuation”能力。 |
| Word highlight mode / discrete mask branch | `packages/core/src/lyric-player/base/consts.ts`, `packages/core/src/lyric-player/base/index.ts`, `packages/core/src/lyric-player/dom/index.ts`, `packages/core/src/lyric-player/dom/lyric-line.ts` | 恢复 App “减弱高亮(beta)”产品能力：开启时按字/词整体 opacity 淡入，关闭时保持官方 smooth 连续扫光。 | 离散高亮本体必须进入 DOM line 的 `maskAnimations` 生命周期；fullscreen / cover blur overlay 只映射这些 animation，若在 App adapter 重造会再次与 exit catch-up、completed highlight 和 emphasis clone 纠缠。window 退场还需要 core 清理 discrete inline opacity，App adapter 无法覆盖窗口歌词。 | 是。默认 `wordHighlightMode = "smooth"`，不进入 discrete branch；切回 smooth 时清理 inline opacity 并重新生成官方 mask image animation。discrete 每个 word/char 使用独立 `delay + duration` envelope；非 active 后只淡回 inactive opacity，不改 smooth mask。 | 中。更新时重点检查 `LyricLineEl.updateMaskImageSync()`、`maskAnimations` lifecycle、`disable()` / `startExitHighlightCatchUp()`、`DomLyricPlayer.setWordFadeWidth()` / `setWordHighlightMode()`、`LyricLineBase` API。 | 不适合直接上游，属于 App 产品语义；若 upstream 接受可抽象成正式 word highlight mode。 |
| CJK Segmenter emphasis chunking | `packages/core/src/utils/lyric-split-words.ts` | 恢复旧 upstream `0.2.1` 对连续 CJK lyric atoms 的语义分组，使长时值词组按 merged chunk 生成 emphasis envelope 和字符 stagger。 | chunking 决定 DOM line 构建、`shouldEmphasize` 输入和官方 animation duration；App adapter 只能复制结果，无法让 window 与 fullscreen 同时回到旧 envelope。 | 是。无 `Intl.Segmenter` 时保持新版逐 atom 输出；ruby / 空白 / 非 CJK 合并规则仍走新版路径。 | 中。更新时检查 upstream `chunkAndSplitLyricWords` 是否再次调整 CJK/ruby/roman 分组语义，并用 `飘飘荡荡只能飘飘荡荡` 样本验证 chunk。 | 可讨论。属于恢复旧 upstream 视觉语义，但是否适合上游取决于 upstream 对 CJK 分词回归的接受度。 |

## C. App Adapter Registry

| Adapter | 位置 | 依赖点 | 脆弱性 | 维护规则 |
|---|---|---|---|---|
| AMLL module bootstrap | `myPlayer2/Resources/AMLL/index.html` | `amll-core.js` 导出 `LyricPlayer`，`amll-lyric.js` 导出 `parseTTML` | 中。bundle 文件名和 export 名变化会启动失败。 | 改 fork 构建入口后必须同步 App bundle，并做 import smoke test。 |
| Bridge error forwarding | `myPlayer2/Resources/AMLL/bridge.js`, `LyricsWebViewStore` | `window.onerror` / `unhandledrejection` / console forwarding | 低。主要用于可观测性。 | 保持错误日志可见，避免 WKWebView 白屏只能猜。 |
| AMLL Mesh Gradient background host | `myPlayer2/Resources/AMLL/background.html`, `AMLLMeshGradientBackgroundView`, `AppleStyleSkin` | `amll-background.js` 导出 `BackgroundRender` / `MeshGradientRenderer`；JS bridge 提供 `setConfig`、`setAlbum`、`setLowFreqVolume`、`setPlaying`、`dispose`、`diagnostics` | 中。背景 WKWebView 与歌词 WKWebView 解耦，但依赖 bg-render API 名称、renderer lifecycle、WKWebView file URL module access。 | Apple 风格窗口/全屏共用该 host。只能把 `backgroundReady` message 当作 renderer ready；`didFinish` 只代表 HTML 导航完成。页面必须把 module import、renderer construction、JS error / rejection 通过 `backgroundDebug` 回传日志。无 artwork 时使用 generated fallback album，host 背后保留非黑 Swift fallback。`dynamicBackgroundEnabled=false` 时必须 pause renderer、清零低频值并释放 Swift 采样消费者；离开 Apple 风格或 view dismantle 时必须 `dispose()`。renderScale 固定 0.6，柔和/标准/活跃分别为 `flowSpeed 0.32/0.58/0.92` 与 `30/30/60 FPS`。Apple fullscreen 不叠通用背景压暗层。 |
| Timeline/internal-state accessors | `index.html` | `timelineState.hotLines` / `bufferedLines` / `currentTime`，以及 line object maps | 中高。读取 core 内部状态，不是 public API。 | 统一走兼容函数；升级 AMLL 后先查这些 accessor 是否仍命中。 |
| Timing preprocessing | `index.html` | parseTTML line/word shape、`leadInMs`、`nearSwitchGapMs`、`timeOffsetMs` | 中。直接改写 line/word timing，会影响 core overlap/hot line 判定。 | 保持“原始结构 overlap”和“焦点提前切换”边界清楚；新增修复先用样本演算。 |
| Word highlight mode config adapter | `index.html`, Swift `LyricsViewModel.refreshConfigFromSettings()`, fullscreen config assembly | `AppSettings.amllDiscreteWordHighlightEnabled`、`wordHighlightMode` config、`lyricPlayer.setWordHighlightMode()`、root class `amll-word-highlight-discrete` | 中。必须保证 core API 缺失时显式降级，API 存在时不输出旧 downgrade；fullscreen/cover blur 只能适配 layer 可见性，不重造离散动画本体。 | “减弱高亮(beta)”关闭下发 `"smooth"`，开启下发 `"discrete"`。root class 只切换 overlay CSS 语义；动画本体由 fork core `maskAnimations` 提供。discrete 退场使用当前 `data-amll-exit-catch-up` 与 smooth 同款 opacity transition，不依赖旧 `data-amll-exiting-highlight` / `data-amll-exit-highlight-word`，也不再启用 discrete 专属 hidden lock。 |
| Fullscreen smooth overlay | `index.html` | `lineObj.element`、`splittedWords`、word mask animations、CSS module class substring | 高。依赖 DOM renderer 内部结构。 | 不要散落新 selector；优先集中在 layer patch 和 semantic class matching。 |
| Cover blur smooth overlay | `index.html` | `.amll-fs-*` generic path 与 `.amll-cb-*` legacy path | 高。两套路径容易只修一边。 | 修 fullscreen 高亮时同时确认 generic cover blur 和 legacy cover blur。 |
| Apple style fullscreen cover-blur-lighter lyrics path | Swift `FullscreenPlayerView` fullscreen config/compositing + App `index.html` generic cover blur adapter | `coverBlurFullscreenGenericMode`、`coverBlurFullscreenGenericProfile=lighter`、`coverBlurFullscreenThemeColor`、Swift `.plusLighter` WebView blend、generic cover blur dots body color only | 中。Apple fullscreen 必须复用 cover blur generic lyric state/animation semantics，不能再维护 Apple-only opacity/dots selector patches，也不能把 legacy cover blur root visibility hack 或 child opacity/blend hack 套到 generic dots 上。 | 只影响 Apple 风格 fullscreen lyric surface。背景仍是 Mesh Gradient，布局仍按 Apple fullscreen/classic placement；歌词颜色来自主题取色引擎，并固定走 cover blur lighter profile / `plus-lighter`。不使用 cover blur light/dark 自动切换、`plus-darker` 或封面模糊背景。快速设置切换 skin 必须 force reapply fullscreen lyrics config/theme，避免旧 CSS vars/profile 留在 WebView。Generic dots 的 show/scale animation 与三颗点逐步变亮 opacity 由 AMLL renderer 管理；App adapter 只改 dot body `background-color`。 |
| Swift-owned lyrics color contract | Swift `SemanticPalette.lyrics` / `FullscreenPlayerView` config assembly + App `index.html` `syncFullscreenDerivedColors()` | Swift 显式下发 window / fullscreen / cover blur surface color set；Web adapter 消费颜色并保留渲染行为。 | 中。字段遗漏会让 Web fallback 重新派生颜色，nearMono artwork 下可能再次放大 residual hue。 | 保持 `SemanticPalette.lyrics` 为主决策入口；`syncFullscreenDerivedColors()` 只在显式颜色缺失时 fallback 派生。Phase 6.5 起，只有 `analysis.isNearMonochrome && !analysis.hasTrustedHueCandidate` 才触发 visible lyrics OKLCH chroma ≤ 0.005 的中性化；有可信 muted hue 的封面必须保留颜色。未来 AMLL 升级不得把 hue 决策搬回 CSS/JS。艺术背景类 fullscreen lyrics 通过 Swift `PerceptualToneLadder.artisticLyricsTone(... scheme:)` 在 light / dark 各产出 ascending / descending L ladder；Web adapter 不需新字段，dots / background lyric / glow 通过 `--amll-fs-main-active` / `--amll-fs-main-inactive` fallback chain 自动跟随 Swift 下发的反相色。 |
| Apple style LED tone policy | `AppleStyleSkin` + `ClassicCoverArtworkView` + `LedMeterView` | `forceBrightLEDColors` 复用 LED resolver 的 dark/bright profile | 低。属于 skin 视觉策略，不改 LED resolver 本体。 | Apple Mesh Gradient 在 light/dark App appearance 下都按暗背景处理，窗口和 fullscreen 都固定传 `forceBrightLEDColors=true`。其他复用 `ClassicCoverArtworkView` 的 skin 默认仍只在 `artBackgroundIsUltraDark` 时强制亮色。 |
| Cover blur emphasis 官方链路 adapter | `index.html` `installFullscreenEmphasizedGlowLayer()` / `installFullscreenPackedElementAnimations()` / `cloneAnimationToElement()` / `releaseSplitWordAuxiliaryState()` | AMLL emphasis WebAnimation id、effect/timing/keyframe composite、`textShadow` keyframes、word-stack `data-amll-fs-emphasis-body` 属性、`--amll-fs-cover-blur-body-color` CSS 变量、highlight-only line-state 选择器（`active` / `data-fs-completed-highlight` / `data-amll-exit-catch-up` / `data-amll-exiting-highlight`） | 高。仍依赖 DOM renderer 私有 `splitWord.elementAnimations` 和 WebAnimation target；如果把 per-character animation clone 到单个 target，或 clone 时丢掉 `composite: "add"`，官方长词/长时值的 scale + float 叠加会失真。 | 只在 `coverBlurFullscreenGenericMode` 下启用。`installFullscreenEmphasizedGlowLayer()` 只打 `data-amll-fs-emphasis-body="1"` 并清理旧 `.amll-fs-cover-blur-glow-layer`；主 body CSS 只恢复强调词 active fill，不承担动画语义。`installFullscreenPackedElementAnimations()` 必须继续 clone `emphasize-word-*` 到原 per-character mapped target；禁止整条跳过，因为该 animation 同时包含 `scale/translate` 与 `textShadow`。`cloneAnimationToElement()` 必须通过 `resolveAnimationComposite()` 保留 source composite，尤其是 `float-word` / `emphasize-word-float*` 的 `add`，否则 float 会 replace 掉 scale。cover blur 只能在 cloned keyframes 上弱化/重染 `textShadow`；base suppress 只能移除 `textShadow`，不能移除 transform。普通 window 不进入 cover-blur profile 调整。 |
| Completed highlight state | `index.html` `updateFullscreenParallelHighlightState()` | `bufferedLines`、`scrollToIndex`、active class、`data-fs-completed-highlight` | 中高。语义是“仍在并行/foreground 组内”，不是 active。 | opacity 不按自身 endTime 熄灭；必须等真实退出组。 |
| Exit catch-up overlay adapter | `index.html` CSS | `data-amll-exit-catch-up` | 中。容易把 catch-up 进度和 opacity fade 混在一起。 | `data-amll-exit-catch-up` 只管高亮扫到行尾所需的可见性；opacity fade 绑定行退出。当前 fullscreen / cover blur smooth overlay 的退出高亮 opacity 曲线为 `0.50s cubic-bezier(0.22, 0.61, 0.36, 1)`；只做视觉曲线调整时不要改 completed/catch-up 选择器。 |
| CSS module semantic selectors | `index.html` CSS/JS diagnostics | `[class*="lyricLine"]`, `[class*="active"]`, `[class*="lyricSubLine"]` 等 | 中。仍是内部 CSS module 约定，但比 hash 稳定。 | 禁止回退到旧 `[class*="_active_"]` / hard-coded hash。 |
| Lyrics render quality WebView scaling | Swift `AMLLWebView` / `LyricsWebViewStore` + App `index.html` CSS | WKWebView scaled frame、`pageZoom`、layer inverse transform、`WebViewHostView.hitTest`、`LyricsMouseGatedWebView.scaledMouseEvent`、`LyricsMouseGatedWebView.scrollWheel`、`window.AMLL.hostWheel`、`AppSettings.amllLyricsRenderQuality` | 中。正式模型与禁区见下一节。此 adapter 属于 App/WebKit 边界，不是 AMLL core patch。 | 保持 `webFrame = host × quality`、`pageZoom = quality`、`layer inverse scale = 1 / quality`；click/scroll 优先保留 WebKit/AMLL 原生语义，只在 AppKit 无法把事件送入 WebKit 时做最小桥接。 |

## D. 低分辨率交互模型（Accepted / Rejected）

Accepted：

- 真实低分辨率模型是 `WKWebView.frame = host × quality`、`pageZoom = quality`、`layer inverse scale = 1 / quality`。`contentsScale-only` 不会改变 WebKit 实际内容渲染分辨率。
- q < 1 时，`WebViewHostView.hitTest(_:)` 必须用本地 `point` 检查完整视觉 `bounds`，并直接返回承载的 `LyricsMouseGatedWebView`，让 click 继续走 `scaledMouseEvent()` → WebKit 原生 DOM click / `line-click`。
- AppKit flat host 与 SwiftUI host 都必须同步 `webViewLayoutScale`，否则窗口主歌词会漏掉低分辨率 hit-test 分支。
- q < 1 的 wheel bridge 只补齐事件入口：Swift 调 `window.AMLL.hostWheel(...)`，JS 在 lyric root 派发标准 `WheelEvent`，AMLL core 原有 wheel handler 继续负责 `scrollState`、clamp、layout 和 `preventDefault()`。
- q < 1 wheel 方向以 q = 1 WebKit 原生 DOM wheel 为唯一基准：`WheelEvent.deltaX = -event.scrollingDeltaX`、`WheelEvent.deltaY = -event.scrollingDeltaY`、`deltaMode = DOM_DELTA_PIXEL`。Apple 已把自然滚动设置体现在 delta 中，不再根据 `isDirectionInvertedFromDevice` 额外翻转。
- Hover indicator 当前是产品层关闭：App adapter 用 `--amll-lp-hover-bg-color: transparent` 隐藏 window / fullscreen hover 圆角背景。文本选择通过 `.amll-lyric-player` 子树的 `-webkit-user-select: none` / `user-select: none` 禁止。
- 本轮交互修复只改 Swift host 与 App `index.html` adapter；不改 fork core，也不手改 generated `amll-core.js` / `amll-lyric.js` / `style.css`。

Rejected：

- 不用 `contentsScale-only` 作为低分辨率模型。
- 不把用户质量档写进 DOM `renderScale`。
- 不恢复 host-driven hover overlay / proxy / app hover class。
- 不恢复 `window.AMLL.hostClickAt(...)` 或任何 JS seek 模拟来代替 WebKit 原生 click。
- 不为防 Home 透传直接吞 `scrollWheel`。
- 不 copy `CGEvent` / 重建 `NSEvent` 后期待 `super.scrollWheel` 稳定生成 DOM wheel。
- 不调用 `webView.hitTest(webViewPoint)` 作为低分辨率事件入口；它可能命中 WKWebView 内部子 view 并绕过 `LyricsMouseGatedWebView.scaledMouseEvent()`。
- 不凭直觉猜 wheel 方向；必须用 q = 1 原生 DOM wheel 对照。

## E. 未迁移或暂缓的旧能力

| 项目 | 当前状态 | 原因 |
|---|---|---|
| 旧离散 exit data / suppress 机制 | 不恢复；新版只恢复离散高亮本体。 | 旧实现风险高，包含 `data-amll-exiting-highlight`、`data-amll-exit-highlight-word`、suppress、hide/show lifecycle hack、退出行残留和闪没问题。 |
| 旧 `data-amll-exiting-highlight` / `data-amll-exit-highlight-word` 机制 | 不恢复。 | 新版修复使用 `data-amll-exit-catch-up` 的窄语义，不搬旧 data 协议。 |
| Exiting-line suppress | 不恢复。 | 疑似破坏窗口进入全屏时历史行显示；当前问题不需要它。 |
| hide/show 不 dispose 行 DOM | 暂未恢复。 | 优先让 App overlay 可重入；只有证明无法外置时再考虑 core patch。 |
| fullscreen mask alpha / glow / lift 旧 core patch | 暂未恢复。 | 需要纯净新版 A/B 后按具体视觉问题单独评估。 |
| dom-slim 自定义 | 不迁移。 | App 当前使用普通 DOM `LyricPlayer`，不是 `DomSlimLyricPlayer`。 |
| canvas renderer 自定义 | 不迁移。 | 新版 upstream 已移除 canvas，App 当前不依赖。 |

## 维护流程

1. 改 AMLL 内部行为时，先判断能否放在 App adapter；只有窗口歌词和 fullscreen 共同依赖 core DOM lifecycle 且无法外置时，才改 fork core。
2. 改 fork core 后，必须更新本 registry，说明为什么不能放 adapter、默认路径是否退化 upstream、upstream 更新风险。
3. 不手改 `myPlayer2/Resources/AMLL/amll-core.js`。编辑 fork TypeScript source，运行构建，再用 `scripts/sync-amll-from-fork.sh` 同步 bundle。
4. 改 App `index.html` overlay 或 timing adapter 后，必须同时考虑 window、fullscreen、generic cover blur、legacy cover blur 是否受影响。
5. 涉及歌词时间关系时，先用具体 TTML 样本做时序演算，再改代码；不要用只针对某首歌的魔法阈值。
