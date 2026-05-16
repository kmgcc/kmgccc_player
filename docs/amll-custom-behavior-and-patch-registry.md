# AMLL 自定义行为与 Patch Registry

本文是新版 AMLL 接入后的长期维护入口，回答“当前 App 到底对 AMLL 自定义了什么”。迁移审计与计划见 `docs/amll-upgrade-migration-audit.md`；升级过程历史见 `docs/amll-upgrade-implementation-log.md`；歌词提前量算法细节见 `docs/amll-lyric-advance-algorithm.md`。

## A. 当前保留的产品行为

| 行为 | 目的 | 当前实现层 | 维护说明 |
|---|---|---|---|
| 独立 parser bundle | 新版 core 不再 re-export parser，App 仍需要 `parseTTML`。 | Fork `packages/lyric/src/myplayer-app.ts` + App `Resources/AMLL/amll-lyric.js` | 通过 `scripts/sync-amll-from-fork.sh` 构建同步；不要把 parser 再假设为 core export。 |
| DOM `LyricPlayer` 专用 core bundle | App 使用普通 DOM renderer，不使用 canvas/dom-slim。 | Fork `packages/core/src/myplayer-app.ts` + App `Resources/AMLL/amll-core.js` | 后续 AMLL 内部修复集中看 `lyric-player/dom`、base/timeline/layout；不要改 dom-slim，除非 App 明确启用。 |
| `timeOffsetMs` | 单曲偏移与全局提前量共同调整歌词视觉时间。 | App `index.html` setLyrics preprocessing | 这是 App 时间轴 adapter，不属于 AMLL public API；seek 不应使用全局提前量。 |
| `seekTimeOffsetMs` | 用户点击歌词时跳到音频真实对齐位置。 | App `index.html` seek line start table | 只包含单曲偏移，不含 `globalAdvanceMs`；保持和 `timeOffsetMs` 分离。 |
| `leadInMs` / `nearSwitchGapMs` | 近距离换行时提前切到下一行，让切换更干脆。 | App `index.html` timing preprocessing | 只改变送入 core 的 lyric line timing；不要把原始相邻行制造成结构 overlap。细节见 `docs/amll-lyric-advance-algorithm.md`。 |
| Exit highlight catch-up | 提前切行时，退出行剩余逐字高亮在退场期间补完。 | Fork core DOM line lifecycle + App overlay adapter | 窗口歌词需要 core mask animation 继续；fullscreen/cover blur overlay 只识别 `data-amll-exit-catch-up` 做可见性适配。 |
| Fullscreen completed highlight 保持 | 并行显示组中已唱完但未退场的行保持完整高亮。 | App `index.html` `updateFullscreenParallelHighlightState()` + CSS | `data-fs-completed-highlight` 表示“仍在组内”，不是 catch-up。opacity fade 应绑定真实退场。 |
| Fullscreen CSS module selector 兼容 | 新版 CSS module hash 形态变化后，fullscreen overlay 仍能识别 lyric line/active/sub/bg。 | App `index.html` CSS/JS selector adapter | 使用 `[class*="lyricLine"]` / `[class*="active"]` 等语义片段；避免回退到旧 `[class*="_active_"]`。 |
| 普通 fullscreen 明度语义 | 普通全屏主要通过颜色明度区分层级，不靠整体 opacity 发灰。 | App `index.html` fullscreen CSS variables / overlay | 修 fullscreen 视觉时先确认 surface role；不要把 cover blur 的透明合成语义套到普通 fullscreen。 |
| Cover blur 混合模式语义 | 封面渐变模糊全屏允许透明度和 blend 参与合成。 | Swift fullscreen config + App `index.html` CSS | 当前 generic cover blur highlight 主要共用 `.amll-fs-*` 路径；legacy `.amll-cb-*` 路径仍保留兼容。 |
| Cover blur emphasis 双通道（主 body + 装饰 glow） | 大封面渐变模糊皮肤的 highlight-only WebView 把主强调可见性和装饰光晕分开渲染，避免单条 glow 兼任主可见时在 darker 失效。 | App `index.html` generic cover blur adapter（CSS + bridge JS） + Swift base/highlight overlay | 主 body 通道：`installFullscreenEmphasizedGlowLayer()` 在确认强调动画存在时给所属 `.amll-fs-word-stack` 写入 `data-amll-fs-emphasis-body="1"`；配套 CSS 在 active/completed/catch-up/exiting line state 下强制 `.amll-fs-word-active` / `.amll-fs-char-stack` / `.amll-fs-char-active` 可见并把 color 拉到 `var(--amll-fs-cover-blur-body-color, --amll-fs-main-active, …)`。`fullscreenCoverBlurSuppressEmphasisGlow=true` 不会清掉 body 通道——该 flag 只关 halo。装饰 glow 通道仍走 `.amll-fs-glow-layer`，仅承担 halo；lighter `rgba(255,255,255,0.12)` × 0.9 ≈ 0.108、darker `rgba(0,0,0,0.16)` × 0.9 ≈ 0.144 是 decorative-only 数值，禁止用 glow alpha 补偿主可见性。普通 fullscreen 没有 highlight-only class，body CSS 不生效。 |
| 0.75 低分辨率渲染 | 降低 WKWebView 实际渲染尺寸，减轻渲染压力。 | Swift/WebView adapter | 真实路径是 WKWebView frame `0.75` + `pageZoom=0.75` + layer scale 回放；不是 DOM `LyricPlayer.setRenderScale()`。 |
| 翻译歌词字体控制 | App 设置控制翻译字体大小/字重。 | App `index.html` CSS variables + semantic selector | 依赖新版 CSS module 语义 selector，例如 `[class*="lyricSubLine"]`；不要绑定旧 hash。 |

## B. Fork Patch Registry

| Patch | 修改文件 | 目的 | 为什么不能放 App adapter | 默认路径是否退化 upstream | Upstream 更新风险 | 是否适合上游 PR |
|---|---|---|---|---|---|---|
| myPlayer DOM-only bundle entry | `packages/core/src/myplayer-app.ts`, `packages/core/tsdown.myplayer.config.ts` | 生成 App 可直接加载的 DOM-only browser bundle，避免 bg-render/Pixi 等非当前路径内容。 | App 只能加载构建产物，不能在运行时改变 core package export graph。 | 是。只影响 myPlayer 专用构建入口，不改变 upstream 默认入口。 | 低。更新时检查 core export 名称和 tsdown config。 | 不适合，属于 App 分发需求。 |
| myPlayer parser bundle entry | `packages/lyric/src/myplayer-app.ts`, `packages/lyric/tsdown.myplayer.config.ts` | 独立构建 `parseTTML` bundle，并处理旧式 TTML fallback / 中文翻译优先。 | App 需要 parser JS bundle；旧式 TTML fallback 属于 App 兼容需求。 | 大体是。优先 upstream parser，fallback 只在严格 parser 返回 0 行等兼容场景介入。 | 中。parser shape 或 package 路径变化时需重跑 parser diff。 | 部分适合。旧式 TTML fallback 可考虑上游讨论；App 语言偏好不适合。 |
| Browser production define | `packages/core/tsdown.myplayer.config.ts` | 消除 WKWebView 中的 `process.env.NODE_ENV` 运行时引用。 | 这是 bundle 构建问题，不是 App runtime 能可靠修补的问题。 | 是。只影响 myPlayer browser bundle define。 | 低。更新 tsdown 或构建链时检查产物是否仍无 `process`。 | 可能适合，如果 upstream browser build 也有同类问题。 |
| Exit highlight catch-up: seek-aware line disable | `packages/core/src/lyric-player/base/index.ts` | `setCurrentTime(time, isSeek)` 是 core 判断 seek 的入口；必须把 `isSeek` 传给退出行。 | App adapter 无法在不 monkey patch core line object 的前提下可靠区分每个 line disable 是否来自 seek。 | `isSeek=true` 时退化为 upstream 的暂停 mask 行为。普通非提前切行且无需 catch-up 时也退化 upstream。 | 中。更新时检查 `commitPlayerTimeState().linesToDisable` 调用点。 | 可能适合，若上游接受 seek-aware disable 语义。 |
| Exit highlight catch-up: abstract signature | `packages/core/src/lyric-player/base/line.ts` | 为 DOM line 提供类型化 `disable(isSeek?: boolean)`。 | 不改类型链路只能用 cast 或 monkey patch，维护性更差。 | 是。可选参数保持调用兼容。 | 低。更新时同步所有 `LyricLineBase` 子类签名。 | 仅随上一个 patch 一起考虑。 |
| Exit highlight catch-up: DOM mask continuation | `packages/core/src/lyric-player/dom/lyric-line.ts` | 提前切行退出时，让未完成 mask animations 在退出窗口内补完。 | 窗口歌词直接依赖原始 DOM mask animations；App adapter 不触碰 `splittedWords` / `maskAnimations` / `disable()` 内部字段无法覆盖窗口和 fullscreen 共同路径。 | 普通播放、非 seek、非暂停、剩余 mask 超过 16ms 才触发；其他路径退化 upstream。 | 中高。更新时对照 `enable()` / `disable()` / `pause()` / `maskAnimations` lifecycle。 | 可能适合，前提是抽象成通用“exiting line mask continuation”能力。 |

## C. App Adapter Registry

| Adapter | 位置 | 依赖点 | 脆弱性 | 维护规则 |
|---|---|---|---|---|
| AMLL module bootstrap | `myPlayer2/Resources/AMLL/index.html` | `amll-core.js` 导出 `LyricPlayer`，`amll-lyric.js` 导出 `parseTTML` | 中。bundle 文件名和 export 名变化会启动失败。 | 改 fork 构建入口后必须同步 App bundle，并做 import smoke test。 |
| Bridge error forwarding | `myPlayer2/Resources/AMLL/bridge.js`, `LyricsWebViewStore` | `window.onerror` / `unhandledrejection` / console forwarding | 低。主要用于可观测性。 | 保持错误日志可见，避免 WKWebView 白屏只能猜。 |
| Timeline/internal-state accessors | `index.html` | `timelineState.hotLines` / `bufferedLines` / `currentTime`，以及 line object maps | 中高。读取 core 内部状态，不是 public API。 | 统一走兼容函数；升级 AMLL 后先查这些 accessor 是否仍命中。 |
| Timing preprocessing | `index.html` | parseTTML line/word shape、`leadInMs`、`nearSwitchGapMs`、`timeOffsetMs` | 中。直接改写 line/word timing，会影响 core overlap/hot line 判定。 | 保持“原始结构 overlap”和“焦点提前切换”边界清楚；新增修复先用样本演算。 |
| Fullscreen smooth overlay | `index.html` | `lineObj.element`、`splittedWords`、word mask animations、CSS module class substring | 高。依赖 DOM renderer 内部结构。 | 不要散落新 selector；优先集中在 layer patch 和 semantic class matching。 |
| Cover blur smooth overlay | `index.html` | `.amll-fs-*` generic path 与 `.amll-cb-*` legacy path | 高。两套路径容易只修一边。 | 修 fullscreen 高亮时同时确认 generic cover blur 和 legacy cover blur。 |
| Cover blur emphasis 双通道 adapter | `index.html` `installFullscreenEmphasizedGlowLayer()` / `installFullscreenPackedElementAnimations()` / `releaseSplitWordAuxiliaryState()` | AMLL emphasis WebAnimation id、`textShadow` keyframes、`.amll-fs-cover-blur-glow-layer`、word-stack `data-amll-fs-emphasis-body` 属性、`--amll-fs-cover-blur-body-color` CSS 变量、highlight-only line-state 选择器（`active` / `data-fs-completed-highlight` / `data-amll-exit-catch-up` / `data-amll-exiting-highlight`） | 高。主可见和装饰光晕被显式拆成两个通道，任何一条丢失都会让强调词不可读或过曝。 | 只在 `coverBlurFullscreenGenericMode` 下启用。**主 body 通道**：写 `data-amll-fs-emphasis-body="1"`，CSS 恢复 `.amll-fs-word-active` / `.amll-fs-char-stack` / `.amll-fs-char-active` 可见，颜色拉到 `--amll-fs-cover-blur-body-color` → `--amll-fs-main-active`；不能依赖 glow profile 数值。**装饰 glow 通道**：`.amll-fs-cover-blur-glow-layer` clone + retint，lighter `~0.108`、darker `~0.144`，是 decorative-only。base 层取消原始 glow，generic packed clone 跳过 emphasis text-shadow；`releaseSplitWordAuxiliaryState()` 在拆 stack 前清 attr。`fullscreenCoverBlurSuppressEmphasisGlow=true` 只关 halo，body 仍在。普通 fullscreen 不进入该分支。 |
| Completed highlight state | `index.html` `updateFullscreenParallelHighlightState()` | `bufferedLines`、`scrollToIndex`、active class、`data-fs-completed-highlight` | 中高。语义是“仍在并行/foreground 组内”，不是 active。 | opacity 不按自身 endTime 熄灭；必须等真实退出组。 |
| Exit catch-up overlay adapter | `index.html` CSS | `data-amll-exit-catch-up` | 中。容易把 catch-up 进度和 opacity fade 混在一起。 | `data-amll-exit-catch-up` 只管高亮扫到行尾所需的可见性；opacity fade 绑定行退出。 |
| CSS module semantic selectors | `index.html` CSS/JS diagnostics | `[class*="lyricLine"]`, `[class*="active"]`, `[class*="lyricSubLine"]` 等 | 中。仍是内部 CSS module 约定，但比 hash 稳定。 | 禁止回退到旧 `[class*="_active_"]` / hard-coded hash。 |
| Low resolution WebView scaling | Swift `AMLLWebView` / `LyricsWebViewStore` | WKWebView frame、`pageZoom`、layer transform、hit-test scale | 中。与 AMLL core 解耦，但易被误认为 JS `renderScale`。 | 修渲染分辨率时先查 Swift/WebView 几何路径。 |

## D. 未迁移或暂缓的旧能力

| 项目 | 当前状态 | 原因 |
|---|---|---|
| 离散逐字/逐词高亮 | 暂未迁移，关闭时保持 smooth upstream-like 路径。 | 旧实现风险高，包含 suppress、mask/opacity 覆盖、退出行残留等历史问题。 |
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
