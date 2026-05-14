# AMLL 升级前自定义盘点与兼容性审计

审计/整理日期：2026-05-13，升级执行补充：2026-05-14  
范围：升级前目录、Git、文档与备份整理；2026-05-14 起开始新版基础接入。生成 bundle 必须从新版 fork 源码构建后同步，不手改 `myPlayer2/Resources/AMLL/amll-core.js`。

## 1. 当前集成基线

| 项目 | 当前情况 | 证据/备注 |
|---|---|---|
| App 升级前使用的 AMLL core 版本 | `@applemusic-like-lyrics/core` `0.2.1` | 冻结源码见 `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-custom-legacy-0.2.1` |
| 最新本地 AMLL core 版本 | `@applemusic-like-lyrics/core` `0.5.0` | `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-integration/packages/core/package.json` |
| App 当前 AMLL 资源状态 | Phase 1 已切到新版 fork 的 myPlayer 专用 DOM-only bundle | 由 `scripts/sync-amll-from-fork.sh` 从新版 fork 构建并同步；旧 bundle 仍在备份目录 |
| 旧版官方参考源码 | `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-upstream-legacy-0.2.1-reference` | 用作 custom diff baseline，tag `legacy-upstream-reference-20260513` |
| 旧 custom 源码位置 | `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-custom-legacy-0.2.1` | 已从 App 仓库外移，tag `legacy-custom-core-20260513` |
| 新版集成源码位置 | `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-integration` | `origin` 指向 fork，`upstream` 指向官方仓库，当前分支 `myplayer-integration` |
| 临时最新版副本 | `/Users/kmg/Documents/vscode/player/amll-sources/_superseded/applemusic-like-lyrics-main-temp-20260513` | 已归档，不作为后续集成 base |
| bundle 产物位置 | `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Resources/AMLL/amll-core.js` | Phase 1 startup-fix sha256 `599ef9f9...ff92a40e`，110,328 bytes |
| parser 产物位置 | `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Resources/AMLL/amll-lyric.js` | Phase 1 sha256 `974ee4ea...fc5451e2`，198,970 bytes |
| CSS 产物位置 | `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Resources/AMLL/style.css` | Phase 1 sha256 `4770c9eb...496d00b`，4,727 bytes |
| App HTML 壳 | `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Resources/AMLL/index.html` | 当前 bundle marker `amll-upgrade-phase1-20260514` |
| 当前 bundle 备份 | `/Users/kmg/Documents/vscode/player/amll-sources/_backups/current-app-amll-bundle-20260513/Resources-AMLL` | 包含 `SHA256SUMS.txt` 与 `MANIFEST.txt` |
| App 实际使用播放器 | `LyricPlayer`，映射到普通 DOM renderer `DomLyricPlayer` | Phase 1 中 `index.html` 从 `amll-core.js` 导入 `LyricPlayer`，从 `amll-lyric.js` 导入 `parseTTML` |
| App 当前不使用 | `CanvasLyricPlayer`、`DomSlimLyricPlayer` | 新版已移除 canvas；dom-slim 自定义不应继续迁移，除非后续显式启用 |
| 当前 Git 整理状态 | App 仓库只保留运行 bundle 与接入文档；旧 custom 源码迁出 App 仓库 | App 仓库后续提交应包含旧源码删除、`.gitignore`、本文档 |

### 1.1 目录与 Git 归属

| 路径 | 归属仓库 | 作用 | 后续策略 |
|---|---|---|---|
| `/Users/kmg/Documents/vscode/player/myPlayer2` | App 仓库 `https://github.com/kmgcc/kmgccc_player.git` | Swift/App 前端、`myPlayer2/Resources/AMLL/` 运行 bundle、接入文档 | 不再跟踪 AMLL 源码工作树；只提交运行产物和接入 adapter |
| `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-custom-legacy-0.2.1` | 本地冻结 Git 仓库 | 当前旧 custom core 源码基线 | 只用于回滚、diff、查自定义；tag `legacy-custom-core-20260513` |
| `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-upstream-legacy-0.2.1-reference` | 本地冻结 Git 仓库 | 旧官方源码参考基线 | 只用于 custom diff；tag `legacy-upstream-reference-20260513` |
| `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-integration` | Fork 仓库 | 后续新版 AMLL 集成工作树 | `origin` = `kmgcc/applemusic-like-lyrics-kmgcccplayer-integration`，`upstream` = `amll-dev/applemusic-like-lyrics`，集成分支 `myplayer-integration` |
| `/Users/kmg/Documents/vscode/player/amll-sources/_backups/current-app-amll-bundle-20260513` | 文件备份目录 | 当前 App 正在运行的 AMLL bundle 快照 | 回滚运行 bundle 时直接从 `Resources-AMLL/` 复制回 App bundle 目录 |
| `/Users/kmg/Documents/vscode/player/amll-sources/_superseded/applemusic-like-lyrics-main-temp-20260513` | 非正式归档副本 | 之前临时下载的最新版源码 | 不作为后续 base；保留到新版 fork 工作流稳定后再清理 |

关键基线判断：

- 当前 App 运行依赖的是 DOM renderer，不是 canvas/dom-slim。后续 AMLL 内部修复应集中在 `lyric-player/dom` 与 base/timeline/layout。
- 当前 core bundle 同时 re-export `@applemusic-like-lyrics/lyric`，所以 `index.html` 能从 `amll-core.js` 直接导入 `parseTTML`。
- 最新 core `0.5.0` 的 `src/index.ts` 不再 re-export `@applemusic-like-lyrics/lyric`；纯净新版 core 不能继续满足 `import { LyricPlayer, parseTTML } from "./amll-core.js"`。
- 后续更新 upstream 的推荐流程：在 `myplayer-integration` 上以 `upstream/main` 为基线做 rebase/merge，把 App 特定修改集中在 adapter 或最小 core patch；构建出的运行 bundle 再同步进 App 仓库。

## 2. Core 源码自定义清单

| 文件 | 自定义点 | 产品目的 | 当前是否仍依赖 | 新版可能对应能力 | 迁移结论 |
|---|---|---|---|---|---|
| `packages/core/src/index.ts` | `export * from "@applemusic-like-lyrics/lyric"` | 让 App 从单一 `amll-core.js` 同时拿到播放器和 `parseTTML` | 是，`index.html` 直接导入 `parseTTML` | 最新 core 不再导出 parser，parser 在 `packages/lyric` / `packages/ttml` | P0。必须做 adapter：单独构建 parser bundle，或 custom core 继续 re-export parser |
| `packages/core/src/lyric-player/base.ts` | 新增 `WordHighlightMode`（`smooth` / `discrete`），`set/getWordHighlightMode` | 支持设置里的“离散逐词高亮” | 是，Swift 下发 `wordHighlightMode`，JS 调 `setWordHighlightMode` | 新版无对应公开 API | P1。若保留此产品功能，仍需 core patch 或重写为 DOM adapter |
| `packages/core/src/lyric-player/base.ts` | 新增 `setLyricAdvanceLeadInMs`、`setLyricNearSwitchGapMs`、行提前/近距离换行判断、前两个词提前、尾词截断 catch-up | Apple Music 风格提前进入下一句，减少近邻行切换迟滞 | 是，Swift 设置面板下发 `leadInMs` / `nearSwitchGapMs` | 新版 `OptimizeLyricOptions.tryAdvanceStartTime` 有固定提前逻辑，但不是可调契约 | P0/P1。优先改成 JS adapter 预处理歌词；若要保持与 core 优化顺序完全一致，再做小 core patch |
| `packages/core/src/lyric-player/base.ts` | 间奏点横向位置 fine tune，区分 fullscreen / 非 fullscreen，对唱右侧 inset | 让 interlude dots 与歌词文本视觉对齐 | 可能依赖，属于视觉修正 | 新版 layout 拆到 `base/layout.ts`，但 dots 放置仍由 `calcLayout` 侧执行 | P2。可先用纯净新版 A/B，必要时迁到新版 `calcLayout` |
| `packages/core/src/lyric-player/dom/index.ts` | `setWordHighlightMode` 后遍历行并 `updateMaskImageSync()` | 切换 smooth/discrete 后立即重建 mask/opacity 动画 | 是 | 新版只有 `setWordFadeWidth` 重建 mask | P1。跟离散高亮一起迁移 |
| `packages/core/src/lyric-player/dom/lyric-line.ts` | 离散逐词高亮：按词 opacity fade，CJK 可逐字/分组，WebAnimation 与 CSS calc 双路径 | 非渐变 mask 的“字/词点亮”模式 | 是，设置中可开启 | 新版无对应能力 | P1。仍可能需要 core patch，因为它复用 `splittedWords`、`maskAnimations`、行 enable/disable 生命周期 |
| `packages/core/src/lyric-player/dom/lyric-line.ts` | exit highlight catch-up / fade，`data-amll-exiting-highlight`、`data-amll-exit-highlight-word` | 行切走时不让当前词高亮突然消失，cover/fullscreen CSS 依赖这些 data 标记 | 是，`index.html` fullscreen/cover blur CSS 和 JS 读取这些标记 | 最新 `0.5.0` 修了 seek/pause 动画同步，但不提供这些 data 标记 | P1。需要结合新版 timeline 修复后重测；若视觉仍需要，保留 patch |
| `packages/core/src/lyric-player/dom/lyric-line.ts` | `hide()` 不再 dispose DOM，而是暂停动画；`show()` 复用 DOM 并可 re-enable | 避免 overscan 出入导致 DOM/动画/覆盖层反复销毁 | 很可能依赖，前端层会给 `splittedWords` 注入 `__fs*` / `__cb*` 节点和动画 | 新版仍是 hide 时 dispose | P0/P1。纯净新版可能破坏 fullscreen/cover blur 克隆层；可改 adapter 在 show 后重 patch，或继续 core patch |
| `packages/core/src/lyric-player/dom/lyric-line.ts` | mask gradient 增加 `maskOverflow = 4`，修正边界 mask position | 避免高亮边缘断裂/露缝 | 视觉依赖，需 A/B | 新版无明显对应项 | P2。先截图对比，再决定 |
| `packages/core/src/lyric-player/dom/lyric-line.ts` | fullscreen surface 下不更新 mask alpha；背景行 alpha 单独处理 | 避免 fullscreen/cover blur 下 core 的 mask alpha 与外层合成冲突 | 是，fullscreen/cover blur CSS 依赖稳定 opacity/color | 新版无 fullscreen surface 概念 | P1。若保留外层 fullscreen 合成，需 patch 或 adapter 覆盖 CSS vars |
| `packages/core/src/lyric-player/dom/lyric-line.ts` | emphasis glow/lift 改动：fullscreen 下削弱 glow、取消横向/纵向堆叠，非 fullscreen 使用更自然的 lift 曲线 | 修正强调词动画抖动、过亮、错层 | 是/待确认，当前 bundle marker 就是 window emphasis lift | 新版有自然弹簧/布局修复，但 emphasis 细节未等价 | P1/P2。纯净新版 A/B 后决定是否保留 |
| `packages/core/src/lyric-player/dom-slim/*` | 将离散高亮、exit fade、mask alpha 等同步复制到 dom-slim | 曾为 slim renderer 准备 | 当前不依赖，App 用 `LyricPlayer` DOM | 最新 core 未导出 dom-slim | 不迁移。删除维护负担 |
| `packages/core/src/lyric-player/canvas/*` | 当前 custom 仍保留 canvas renderer | 历史残留 | 当前不依赖 | 最新 `0.4.0` 已移除 canvas | 不迁移 |

### 2.1 离散逐字高亮风险边界

离散逐字/逐词高亮仍是保留的产品需求，但旧实现不能作为可靠迁移基线直接照搬。已知风险包括：

- 提前切行时 exiting line 的高亮淡出丢失。
- 行隐退后存在高亮残留，随后又突然闪没。
- 即使关闭离散高亮，也会污染 smooth 默认路径。
- 过去为修离散高亮加入的强力 exiting-line suppress，疑似破坏从窗口进入全屏时历史行显示。
- 当前窗口歌词字符裁切、强调词回落末尾下坠异常，可能与旧离散高亮/exit suppress/line lifecycle patch 有关；至少不能默认迁移。

迁移原则：

- 保留“离散高亮”作为后续产品能力。
- 不把旧实现当作可靠迁移基线。
- Phase 1 先恢复纯净新版 smooth 路径，并确认关闭 discrete 时完全接近 upstream 行为。
- 后续若重做 discrete，必须基于新版 renderer/timeline 重新设计；关闭 discrete 时不得残留 class、data attribute、动画、opacity/mask 覆盖或 line suppress 行为。

## 3. App 前端层自定义清单

| 位置 | 自定义点 | 依赖的 DOM/API | 迁移风险 | 建议 |
|---|---|---|---|---|
| `Resources/AMLL/index.html` module import | 从 `./amll-core.js` 导入 `LyricPlayer` 和 `parseTTML` | core bundle re-export lyric parser | 高。最新 core 不导出 `parseTTML` | P0：先拆 parser adapter 或继续 re-export |
| `Resources/AMLL/index.html` inline CSS | 大量 fullscreen / cover-blur / line-timing CSS，混用 `[class*="_lyricLine_"]` 与旧 hash 类名如 `._lyricLine_m23bz_6` | AMLL CSS module 类名、DOM 层级、`active` 类 | 中高。substring selector 较稳，硬编码 hash 会失效 | 把硬编码 hash 改成 substring selector 或自有 class adapter |
| `Resources/AMLL/index.html` surface role | `surfaceRole` 决定 main/fullscreen/batch/coverBlurHighlight 默认参数 | `window.__AMLL_SURFACE_ROLE`，`lyricPlayer` public methods | 中。核心 API 大多还在，但 `setRenderScale`/`setFPS` 对 lyric player 仍是 no-op guard | 保留在 adapter 层；不要放进 core |
| `Resources/AMLL/index.html` line seek | 自定义 hit-test、`line-click`、`lyricLinesIndexes`、`processedLines`、`getLine()` | Core line event、WeakMap、line objects | 中。新版仍有 `lyricLinesIndexes` 和 line-click，但内部字段受保护且非稳定 API | 封装 `getLineIndex/getProcessedLine` adapter，兼容旧/新结构 |
| `Resources/AMLL/index.html` 内部状态访问 | 读取 `currentLyricLineObjects`、`hotLines`、`currentTime`、`initialLayoutFinished`、`isNonDynamic` | 旧 base 的 protected 字段在 JS 中可见 | 高。新版 `hotLines/currentTime/initialLayoutFinished` 移到 `timelineState` | P0：新增兼容函数，例如从 `lyricPlayer.timelineState?.hotLines` 回退旧字段 |
| `Resources/AMLL/index.html` fullscreen layering | 遍历 `lineObj.element`、`lineObj.splittedWords`、`splitWord.mainElement/subElements/maskAnimations/elementAnimations`，注入 `__fs*` 节点 | `LyricLineEl` 私有字段名和 DOM 结构 | 高。字段名当前新版基本仍在，但不是公开 API；hide dispose 会破坏注入层 | 建议改成集中 adapter，并在每次 setLyrics/show/update 后可重入 patch |
| `Resources/AMLL/index.html` cover-blur layering | 注入 `.amll-cb-word-stack` / `.amll-cb-char-stack`，克隆 mask/element animations | 同上，加上 `data-amll-exiting-highlight` | 高。最依赖 custom core 的 exit 标记和不 dispose 行 | P1：纯净新版先跑，cover blur 后补；必要时保留 core exit patch |
| `Resources/AMLL/index.html` line timing mode | `normalizeMainLinesForLineTimingMode(lines)`，并写 `lyricPlayer.isNonDynamic = true/false` | 旧 core `isNonDynamic` 字段 | 高。新版仍有 `isNonDynamic`，但写 protected 字段不是契约 | 改为 adapter 侧处理 lyric lines 或推动 core 暴露公开 setter |
| `Resources/AMLL/index.html` time offsets | `timeOffsetMs` 改写 line/word 时间，`seekTimeOffsetMs` 保留 seek start | parseTTML line shape | 中。新版 parser shape 需验证 | P0：用同一 TTML 样本比较 parser 输出 |
| `Resources/AMLL/index.html` config consumer | `setConfig` 消费字体、颜色、blend、timing、mode、align 等 | `setEnableBlur`、`setEnableSpring`、`setWordFadeWidth`、`setOverscanPx`、`setAlignAnchor`、`setAlignPosition` 等 | 中。多数 public API 仍在；`setWordHighlightMode`、lead-in API 不在 | 保留 config schema，缺失项走 adapter 或 custom patch |
| `Resources/AMLL/index.html` diagnostics/profile | wrap `setLyricLines`、`calcLayout`、line `rebuildElement/updateMaskImage*`，debug dump visible layers | 方法名和 line object internals | 中高。新版方法仍在，但 timeline 字段变了 | 降级为可选诊断，不阻塞播放 |
| `Resources/AMLL/bridge.js` | pending calls、capabilities、Swift onReady、user seek callback | `window.LyricsRenderer` / `window.AMLL` | 低。与 core 解耦 | 可直接保留 |

### 3.1 Fullscreen Surface 产品语义

fullscreen surface 不是单纯的 AMLL core 渲染模式，而是 App 侧既定视觉语义：

- 普通全屏歌词皮肤主要通过颜色明度区分歌词层级，不依赖整体 opacity 发灰；除高亮相关部分外，不应随意引入 opacity。
- 全屏封面渐变模糊模式允许透明度参与合成，属于另一套视觉语义。
- 浅色/深色模式下分别存在 `plus-lighter` / `plus-darker` 等混合策略，升级时不能无意丢失。
- 本轮基础接入阶段先登记这些语义，并尽量保持现有 App 层壳逻辑；不急于重做 fullscreen/cover blur 的视觉 patch。

## 4. Swift 层 AMLL 契约清单

| Swift 来源 | 下发字段/消息 | JS 消费位置 | 是否依赖 custom core | 新版兼容判断 |
|---|---|---|---|---|
| `LyricsViewModel.refreshConfigFromSettings()` | `fontSize`、`fontWeight`、`fontFamilyMain`、`fontFamilyTranslation`、`translationFontSize`、`translationFontWeight` | `index.html` `setConfig` 设置 CSS vars | 否 | 可直接保留 |
| `LyricsViewModel.refreshConfigFromSettings()` | `leadInMs`、`nearSwitchGapMs` | `setConfig` -> `syncLeadTimingConfig()` -> `setLyricAdvanceLeadInMs` / `setLyricNearSwitchGapMs` | 是 | 最新无 API。P0/P1：改 adapter 或 core patch |
| `LyricsViewModel.refreshConfigFromSettings()` | `timeOffsetMs`、`seekTimeOffsetMs` | `setConfig` 后触发歌词 reload；`setLyrics` 改写 line/word 时间和 seek start | 否，主要依赖 parser shape | 需用新版 parser A/B 验证 |
| `LyricsViewModel.refreshConfigFromSettings()` | `renderScale`、`fpsCap` | `setConfig` 尝试 `lyricPlayer.setRenderScale` / `setFPS` | 否；当前 lyric player 也基本是 guarded no-op | 可保留，但应标记为 no-op 或改由 WKWebView/RAF adapter 管 |
| `LyricsViewModel.refreshConfigFromSettings()` | `enableBlur`、`enableSpring`、`overscanPx`、`wordFadeWidth` | core public APIs | 否 | 最新仍兼容 |
| `LyricsViewModel.refreshConfigFromSettings()` | `wordHighlightMode` | `setConfig` -> `setWordHighlightMode`，同时切 root class `amll-word-highlight-discrete` | 是 | 最新无 API。P1 core patch 或 adapter |
| `LyricsViewModel.refreshConfigFromSettings()` | `lineHeight`、`activeScale` | 当前 `index.html` 未检索到实际消费 | 否 | 可清理或补明确消费；升级不应依赖 |
| `FullscreenPlayerView` config | fullscreen colors、`mixBlendMode`、`blendOpacity`、`alignAnchor`、`alignPosition`、`alignOffset` | `index.html` fullscreen style/compositing/align logic | 部分依赖 core DOM class，但大多在 adapter 层 | 可保留，需修 internal state adapter |
| `FullscreenPlayerView` config | `fullscreenLyricDodgeMode`、`fullscreenCoverBlurMode`、`coverBlurFullscreenGenericMode`、`coverBlurFullscreenGenericProfile`、`coverBlurFullscreenThemeColor`、`coverBlurSuppressEmphasisGlow` | `index.html` fullscreen/cover blur root state与 DOM layering | 间接依赖 custom core 的 line lifecycle、exit markers、mask behavior | P1。纯净新版跑通后优先验证 fullscreen/cover blur |
| `LyricsSurfaceRole` | `renderScale`、`enableBlur`、`enableSpring`、`fpsCap`、`overscanPx`、`wordFadeWidth` | `LyricsViewModel` / `FullscreenPlayerView` 组装 config | 仅 `wordFadeWidth`/`blur`/`spring`/`overscan` 走 core public API | 兼容；`renderScale/fpsCap` 应确认实际作用 |
| `LyricsRuntimeOverlayResolver` | 字体 size delta、`globalAdvanceDeltaMs` | 进入 config 的 font/time offset | 否 | 可直接保留 |
| `LyricsWebViewStore` | `setLyricsTTML`、`setCurrentTime`、`setPlaying`、`setConfigJSON` | `bridge.js` -> `window.LyricsRenderer` | 否，协议层稳定 | 可直接保留 |
| `LyricsWebViewStore.applyTheme()` | `theme`、`textColor`、`shadowColor` 与 CSS vars | `index.html` / root style | 否 | 可直接保留 |

## 5. 迁移优先级

### P0：新版接入前必须明确

- `parseTTML` 来源：最新版 core 不再导出 parser。必须决定单独 parser bundle，还是 custom core 继续 re-export `@applemusic-like-lyrics/lyric`。
- 新旧 parser 输出 shape：必须用同一批 TTML 样本做结构 diff，至少比较 line/word 起止时间、翻译/罗马音/背景声部、agent/duet 信息、空行/间奏行和字段命名；`timeOffsetMs`、line timing mode、seek 命中都依赖这个 shape。
- 构建产物命名：当前 App import `amll-core.js` 和 `style.css`；最新版 tsdown 默认产物是 `amll-core.mjs` / `amll-core.cjs` / `style.css`。同步脚本要负责重命名或改 HTML import。
- 内部状态 adapter：`hotLines`、`currentTime`、`initialLayoutFinished` 在新版进入 `timelineState`；当前 `index.html` 仍读旧字段。
- `currentLyricLineObjects` / `splittedWords` / `element` 注入层的生命周期：最新版 hide 仍可能 dispose DOM，当前 fullscreen/cover blur 注入层可能被销毁。
- 纯净新版接入阶段的显式降级：`wordHighlightMode`、`leadInMs`、`nearSwitchGapMs` 在新版无等价 public API 时必须进入明确 fallback，并输出日志标记，例如 `[AMLL-UPGRADE-DOWNGRADE] wordHighlightMode ignored by pure upstream core`，避免静默失效被误判为功能正常。
- 纯净新版 smoke test 样本：必须覆盖普通逐字、CJK、英文、对唱、背景人声、长间奏、暂停 seek、同一句内拖动、fullscreen cover blur。

### 5.1 升级时不得盲目继承的旧 patch

- 离散高亮相关 suppress 和 mask/opacity 覆盖。
- exiting line 的强力抑制逻辑。
- 为修历史 bug 临时加入、但可能破坏 fullscreen/history line 生命周期的 patch。
- hide/show 不 dispose 的旧 line lifecycle patch，除非新版基础接入验证证明 App 注入层无法外置恢复。
- fullscreen mask alpha / glow / lift 的旧 core patch，Phase 1 不迁移，后续按视觉回归结果单独评估。

迁移时这些 patch 必须先审计、再小范围重做；不得因为旧 custom core 中存在就默认搬运。

### P1：新版跑通后优先补

- `wordHighlightMode` 离散高亮 API 与 DOM 行实现。
- `leadInMs` / `nearSwitchGapMs` 的可调提前策略。
- exit highlight data 标记与 catch-up 行为。
- fullscreen/cover blur layering 的重 patch 机制。
- fullscreen 下 mask alpha / glow / lift 的视觉修正。

### P2：可延后确认

- interlude dots 横向 fine tune。
- mask overflow 视觉边缘修正。
- 旧 hash class selector 清理。
- `lineHeight` / `activeScale` 是否继续保留在 Swift config。
- dom-slim/canvas 清理。

## 6. 初步迁移判断

### 可直接保留的

- `bridge.js` 的 Swift/JS 消息协议：`setLyricsTTML`、`setCurrentTime`、`setPlaying`、`setConfig`、onReady、user seek callback。
- Swift 层主题、字体、颜色、blend、align 的 config schema。
- `setEnableBlur`、`setEnableSpring`、`setWordFadeWidth`、`setOverscanPx`、`setAlignAnchor`、`setAlignPosition` 等 public core API 调用。
- `LyricsSurfaceRole` 的多 surface 生命周期模型。

### 需改成 adapter 的

- `parseTTML` 导入和 parser bundle 管理。
- 读取 core 内部状态的函数：统一封装为 `getCurrentTime()`、`getHotLines()`、`isInitialLayoutFinished()`、`getProcessedLine()`，兼容旧字段和新版 `timelineState`。
- `leadInMs` / `nearSwitchGapMs`：优先在 `setLyrics` 前做歌词预处理 adapter，而不是直接改 core base。
- fullscreen/cover blur DOM 注入：集中成可重入 patch，避免散落访问 `splittedWords`。

### 仍可能需要 core patch 的

- 离散逐词高亮的 mask/opacity 动画，因为它深度依赖 `LyricLineEl` 的 `maskAnimations` 和 enable/disable 生命周期。
- exit highlight catch-up 与 data 标记，因为外层 CSS/JS 已依赖这些标记。
- hide/show 不 dispose 行 DOM，除非 adapter 能可靠在每次 show 后重建 fullscreen/cover blur 注入层。
- fullscreen 下 mask alpha 与 emphasis 动画的特殊处理。

### 暂时无法判断，待纯净新版 A/B 验证的

- 新版 `0.5.0` 的 timeline 修复是否已经解决原先“顽固 bug”的主体。
- 新版自然弹簧是否足以替代当前 emphasis lift 自定义。
- 新版行平衡、背景行注音、高亮同步是否改变现有视觉回归。
- cover blur highlight overlay 在新版 DOM 生命周期下是否仍稳定。

## 7. 旧实现恢复路径

- 运行 bundle 回滚：从 `/Users/kmg/Documents/vscode/player/amll-sources/_backups/current-app-amll-bundle-20260513/Resources-AMLL/` 复制回 `/Users/kmg/Documents/vscode/player/myPlayer2/myPlayer2/Resources/AMLL/`，或从 App 仓库历史恢复 `myPlayer2/Resources/AMLL/`。
- 旧 custom core 源码回滚：进入 `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-custom-legacy-0.2.1`，使用 tag `legacy-custom-core-20260513` 作为冻结基线。
- 旧官方源码参考：进入 `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-upstream-legacy-0.2.1-reference`，使用 tag `legacy-upstream-reference-20260513` 做 custom diff baseline。
- 新版集成失败时，App 仓库仍可只恢复 `myPlayer2/Resources/AMLL/` 运行 bundle；不需要把旧 custom 源码重新放回 App 仓库内部。

## 建议的升级执行顺序

1. 建立 `amll-adapter` 层：先解决 parser import、内部状态兼容函数、bundle 文件命名。
2. 接入纯净 `0.5.0` DOM `LyricPlayer`，对 `wordHighlightMode`、`leadInMs`、`nearSwitchGapMs` 做显式降级和日志标记，不允许静默忽略。
3. 跑 P0 smoke test，记录哪些旧 bug 消失、哪些自定义视觉缺失。
4. 先补 adapter 能解决的：lead-in 预处理、状态读取、fullscreen/cover blur 可重入 patch。
5. 最后只对无法外置的功能做小 core patch：离散高亮、exit data 标记、必要的 line lifecycle。
6. 每次 core patch 后构建源码产物，再同步到 `myPlayer2/Resources/AMLL/`；不要手改 `amll-core.js`。

## 8. 当前执行计划

### Phase 1：新版基础接入 App

- 使用 `/Users/kmg/Documents/vscode/player/amll-sources/applemusic-like-lyrics-kmgcccplayer-integration` 的 `myplayer-integration` 分支作为新版源码 base。
- 接入纯净新版 DOM `LyricPlayer` 到 App，解决 parser import / `parseTTML` 来源、bundle 产物命名与同步、App `Resources/AMLL/` 引用兼容、timeline/internal-state adapter、新旧 parser 输出 shape 结构 diff。
- 对 `wordHighlightMode`、`leadInMs`、`nearSwitchGapMs` 先做显式降级和日志标记；其中时间字段在 Phase 2 恢复前不得静默失效。
- Phase 1 不迁移离散逐字高亮、exit highlight catch-up、exiting line suppress、hide/show 不 dispose 的旧 line lifecycle patch、fullscreen mask alpha / glow / lift 的旧 core patch。

### Phase 2：恢复时间相关、已验证必要的自定义

- 在新版基础接入可运行后，优先接回 `leadInMs`、`nearSwitchGapMs`、必要的歌词提前 / 近距离换行逻辑。
- 验证 `timeOffsetMs` / `seekTimeOffsetMs` 与新版 parser shape 的兼容性。
- 优先使用 adapter / lyric preprocessing；只有明确无法外置时，才做小而独立的 core patch。
- 时间相关改动必须实际接入 App，并通过构建、parser diff、配置 downgrade/恢复日志做基本验证。

## 9. 2026-05-14 执行记录

### 已完成

- 新版 fork 增加 myPlayer 专用构建入口：
  - `packages/core/src/myplayer-app.ts` 只导出 DOM `LyricPlayer`、interfaces 与 spring type，不导出 bg-render/Pixi。
  - `packages/core/tsdown.myplayer.config.ts` 构建自包含 `dist-myplayer/amll-core.mjs`。
  - `packages/lyric/src/myplayer-app.ts` 提供 App 专用 `parseTTML`，优先走 upstream parser；当新版严格 parser 因旧式 plain TTML 缺少 `itunes:key` 返回 0 行时，fallback 到旧式 `<p begin/end>` 行解析；同时对多语言翻译优先选择中文 `zh*`，避免新版默认拿到英文翻译。
  - `packages/lyric/tsdown.myplayer.config.ts` 构建自包含 `dist-myplayer/amll-lyric.mjs`。
- App 仓库新增 `scripts/sync-amll-from-fork.sh`，从新版 fork 构建后同步到 `Resources/AMLL/`；不手改 generated bundle。
- App `index.html` 已改为从 `amll-core.js` 导入 `LyricPlayer`、从 `amll-lyric.js` 导入 `parseTTML`。
- App `index.html` 增加 timeline/internal-state 兼容访问器，兼容新版 `timelineState`。
- `wordHighlightMode` 在新版缺少 core API 时显式降级到 smooth，并输出 `[AMLL-UPGRADE-DOWNGRADE]` 日志；旧离散高亮不迁移。
- `leadInMs` / `nearSwitchGapMs` 已通过 App 侧 lyric preprocessing adapter 恢复基础时间行为；core 缺少旧 API 时会输出日志并说明由 adapter 接管。
- 新增 `scripts/verify-amll-parser-shape.mjs`，用旧 bundle 备份与当前新版 parser 对同一 TTML 样本做结构 diff。

### 验证结果

- 新版 myPlayer bundle 构建通过；`amll-core.js` / `amll-lyric.js` 无裸 npm import。
- Node import smoke test 通过：`LyricPlayer` 与 `parseTTML` 均可导入。
- Parser diff：`sample.ttml` 行结构通过，`lines=3`，`metadataDiffs=0`。
- 扩展 parser diff：官方 fixture 暴露新版 parser 与旧 parser 的真实差异：
  - `apple-music-other-duet.ttml` 行结构兼容，只有 metadata 增量差异。
  - `apple-music-duet.ttml` 在背景声部/翻译拆分上有差异；新版会给背景行更完整的 start/end 和独立翻译，旧版会把部分背景翻译拼到主行。
  - `complex-test-song.ttml` 在 romanization 对齐、合唱/背景行 duet 判定、背景翻译拆分上有差异；新版更偏向结构化逐字 romanWord，旧版更偏向整行 romanLyric。
  - `ruby-test-song.ttml` 旧 parser 会触发 wasm `unreachable`，新版 parser 可作为后续 ruby 兼容验证基线。
- Xcode Debug 构建通过：`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -destination 'platform=macOS' build`。
- 构建出的 App bundle 已包含新版 `Resources/AMLL/amll-core.js`、`amll-lyric.js`、`style.css` 与更新后的 `index.html`。

### 2026-05-14 启动空白问题排查与修复

排查链路结论：

- `Resources/AMLL/index.html` 已在 WKWebView 中加载；`bridge.js`、module script 均执行。
- 带 `?v=amll-upgrade-phase1-20260514` 的本地 module import 在本次 WKWebView 验证中可正常 resolve；`LyricPlayer` 与 `parseTTML` 的 import 都成功，因此 `?v=` 不是本次空白根因，暂未移除。
- `window.AMLL` ready 链路正常：前端调用 `_onRendererReady()`，Swift 收到 `onReady`，随后 replay config 和下发 `setLyricsTTML`。
- `parseTTML` 成功解析当前 TTML：`lineCount=79`。
- 真正失败点是 `lyricPlayer.setLyricLines(lines)`：新版 myPlayer 专用 core bundle 中仍残留 `process.env.NODE_ENV !== "production"`，WKWebView 没有 Node `process`，导致 `ReferenceError: Can't find variable: process`，歌词 DOM 未生成。

修复方式：

- 在新版 fork 的 `packages/core/tsdown.myplayer.config.ts` 中把浏览器 bundle 的 define 改为生产常量：`import.meta.env.DEV=false`，并显式定义 `process.env.NODE_ENV="production"`。
- 通过 `scripts/sync-amll-from-fork.sh` 重新从源码构建并同步 `amll-core.js`；没有手改 generated bundle。
- `bridge.js` 增加 `window.onerror`、`unhandledrejection`、`console.warn/error` 转发，Swift `LyricsWebViewStore` 将 `[AMLL-BOOT]`、ready、setLyrics、错误类日志提升到可见等级，避免后续 WKWebView 启动失败只能猜。

验证结果：

- 重建后的 `amll-core.js` 已无 `process` / `NODE_ENV` 残留。
- 实际启动 Debug App 后日志显示：module import 成功、ready 成功、`setLyricsTTML len=36063`、`parseTTML lineCount=79`、`setLyricLines done lineCount=79`、`Loaded lines: 79`。
- 截图确认主窗口右侧歌词恢复显示。

### 2026-05-14 低分辨率渲染核查

旧版 0.75 倍渲染能力的真实实现不是 DOM `LyricPlayer.setRenderScale()`：

- Swift 设置层使用 `amllHighResolutionLyricsEnabled` 作为用户开关；默认未开启高分辨率时，`amllLowResolutionModeEnabled == true`。
- `LyricsSurfaceRole.amllLowResolutionScale = 0.75`。main/fullscreen/standalone 支持低分辨率，batch preview 不受该开关影响。
- `AMLLWebView.Coordinator.updateLowResolutionMode()` 会把 scale 同步给 `WebViewHostView.webViewLayoutScale`，并调用 `LyricsWebViewStore.setLowResolutionModeEnabled()`。
- `LyricsWebViewStore.layoutWebView()` 才是真正降分辨率的地方：WKWebView frame 按 `0.75` 缩小，`webView.pageZoom = 0.75`，随后 layer 用 `scale(1 / 0.75)` 放回宿主布局尺寸；鼠标 hit-test / event 坐标也按 `0.75` 修正。
- `applyBackingScaleForResolutionMode()` 当前仍使用窗口 backing scale，没有把 layer contentsScale 降到 0.75；因此实际收益来自“缩小 WebView frame + pageZoom + layer 放大”，不是单独修改 backing scale。
- JS 侧 `renderScale: 0.75` 和旧 `index.html` 的 `lyricPlayer.setRenderScale(renderScale)` 对 App 当前 DOM `LyricPlayer` 基本不是有效路径：旧 custom core 与新版 core 的 `setRenderScale` 实现在 `bg-render` / Pixi/canvas 背景渲染类上，`lyric-player/dom` 没有该 public method；新版实际日志也显示 `hasSetRenderScale: "undefined"`。

新版迁移结论：

- 0.75 低分辨率能力没有因新版 core 接入而失效，因为它属于 App/WebView adapter 层，不依赖 AMLL DOM core。
- 本次实际启动验证显示 main surface 默认进入低分辨率：宿主约 `232x653` 时，WKWebView frame 为约 `174x489`，`pageZoom=0.75`，layer scale 约 `1.33`，最终宿主布局尺寸不变。
- 继续保留 Swift/WebView adapter 实现；不要把它误迁成 core patch，也不要只依赖 JS `renderScale`。
- 文档中此前“`renderScale/fpsCap` 应确认实际作用”的判断修正为：`renderScale` 对当前 DOM 歌词路径是兼容保留字段但实际 no-op；真实低分辨率由 Swift WebView 几何缩放负责。

### 仍未迁移

- 离散逐字/逐词高亮。
- exit highlight catch-up 与相关 data 标记。
- exiting-line suppress。
- hide/show 不 dispose 的旧 line lifecycle patch。
- fullscreen mask alpha / glow / lift 的旧 core patch。
- fullscreen/cover blur layering 的新版可重入重构。
