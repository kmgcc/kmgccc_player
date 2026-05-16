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
| CJK emphasis 连续波 | 连续 CJK 长时值词组恢复旧 upstream 的 staggered emphasis envelope，让相邻字处于不同上浮、放大、辉光进度。 | Fork core `utils/lyric-split-words.ts` | 对连续 CJK run 使用 `Intl.Segmenter` 重新分成语义 chunk；没有 `Intl.Segmenter` 时退化为新版逐 atom 行为。 |
| Fullscreen completed highlight 保持 | 并行显示组中已唱完但未退场的行保持完整高亮。 | App `index.html` `updateFullscreenParallelHighlightState()` + CSS | `data-fs-completed-highlight` 表示“仍在组内”，不是 catch-up。opacity fade 应绑定真实退场。 |
| Fullscreen CSS module selector 兼容 | 新版 CSS module hash 形态变化后，fullscreen overlay 仍能识别 lyric line/active/sub/bg。 | App `index.html` CSS/JS selector adapter | 使用 `[class*="lyricLine"]` / `[class*="active"]` 等语义片段；避免回退到旧 `[class*="_active_"]`。 |
| 普通 fullscreen 明度语义 | 普通全屏主要通过颜色明度区分层级，不靠整体 opacity 发灰。 | App `index.html` fullscreen CSS variables / overlay | 修 fullscreen 视觉时先确认 surface role；不要把 cover blur 的透明合成语义套到普通 fullscreen。 |
| Cover blur 混合模式语义 | 封面渐变模糊全屏允许透明度和 blend 参与合成。 | Swift fullscreen config + App `index.html` CSS | 当前 generic cover blur highlight 主要共用 `.amll-fs-*` 路径；legacy `.amll-cb-*` 路径仍保留兼容。 |
| Cover blur emphasis 官方链路 adapter | 大封面渐变模糊皮肤只对官方 emphasis 的 glow 做 cover-blur 专属弱化/重染，避免重造一套独立 glow 动画。 | App `index.html` generic cover blur adapter（CSS + bridge JS） + Swift base/highlight overlay | `installFullscreenEmphasizedGlowLayer()` 只给强调词 `.amll-fs-word-stack` 写入 `data-amll-fs-emphasis-body="1"`，让 highlight-only WebView 恢复强调词主填充；不再创建 `.amll-fs-cover-blur-glow-layer`。`installFullscreenPackedElementAnimations()` 继续按官方 per-character target clone `emphasize-word-*`，保留 scale / translate / duration / delay / stagger，只在 clone keyframes 中对 `textShadow` 做 profile retint/rescale；base 层 `coverBlurSuppressEmphasisGlow=true` 时仅把 `textShadow` 置为 `none`，不移除 transform。当前 glow profile 为 lighter `rgba(255,255,255,0.12) × 1.0`、darker `rgba(0,0,0,0.16) × 1.0`。普通 fullscreen/window 不进入 cover-blur profile 调整。 |
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
| CJK Segmenter emphasis chunking | `packages/core/src/utils/lyric-split-words.ts` | 恢复旧 upstream `0.2.1` 对连续 CJK lyric atoms 的语义分组，使长时值词组按 merged chunk 生成 emphasis envelope 和字符 stagger。 | chunking 决定 DOM line 构建、`shouldEmphasize` 输入和官方 animation duration；App adapter 只能复制结果，无法让 window 与 fullscreen 同时回到旧 envelope。 | 是。无 `Intl.Segmenter` 时保持新版逐 atom 输出；ruby / 空白 / 非 CJK 合并规则仍走新版路径。 | 中。更新时检查 upstream `chunkAndSplitLyricWords` 是否再次调整 CJK/ruby/roman 分组语义，并用 `飘飘荡荡只能飘飘荡荡` 样本验证 chunk。 | 可讨论。属于恢复旧 upstream 视觉语义，但是否适合上游取决于 upstream 对 CJK 分词回归的接受度。 |

## C. App Adapter Registry

| Adapter | 位置 | 依赖点 | 脆弱性 | 维护规则 |
|---|---|---|---|---|
| AMLL module bootstrap | `myPlayer2/Resources/AMLL/index.html` | `amll-core.js` 导出 `LyricPlayer`，`amll-lyric.js` 导出 `parseTTML` | 中。bundle 文件名和 export 名变化会启动失败。 | 改 fork 构建入口后必须同步 App bundle，并做 import smoke test。 |
| Bridge error forwarding | `myPlayer2/Resources/AMLL/bridge.js`, `LyricsWebViewStore` | `window.onerror` / `unhandledrejection` / console forwarding | 低。主要用于可观测性。 | 保持错误日志可见，避免 WKWebView 白屏只能猜。 |
| Timeline/internal-state accessors | `index.html` | `timelineState.hotLines` / `bufferedLines` / `currentTime`，以及 line object maps | 中高。读取 core 内部状态，不是 public API。 | 统一走兼容函数；升级 AMLL 后先查这些 accessor 是否仍命中。 |
| Timing preprocessing | `index.html` | parseTTML line/word shape、`leadInMs`、`nearSwitchGapMs`、`timeOffsetMs` | 中。直接改写 line/word timing，会影响 core overlap/hot line 判定。 | 保持“原始结构 overlap”和“焦点提前切换”边界清楚；新增修复先用样本演算。 |
| Fullscreen smooth overlay | `index.html` | `lineObj.element`、`splittedWords`、word mask animations、CSS module class substring | 高。依赖 DOM renderer 内部结构。 | 不要散落新 selector；优先集中在 layer patch 和 semantic class matching。 |
| Cover blur smooth overlay | `index.html` | `.amll-fs-*` generic path 与 `.amll-cb-*` legacy path | 高。两套路径容易只修一边。 | 修 fullscreen 高亮时同时确认 generic cover blur 和 legacy cover blur。 |
| Cover blur emphasis 官方链路 adapter | `index.html` `installFullscreenEmphasizedGlowLayer()` / `installFullscreenPackedElementAnimations()` / `cloneAnimationToElement()` / `releaseSplitWordAuxiliaryState()` | AMLL emphasis WebAnimation id、effect/timing/keyframe composite、`textShadow` keyframes、word-stack `data-amll-fs-emphasis-body` 属性、`--amll-fs-cover-blur-body-color` CSS 变量、highlight-only line-state 选择器（`active` / `data-fs-completed-highlight` / `data-amll-exit-catch-up` / `data-amll-exiting-highlight`） | 高。仍依赖 DOM renderer 私有 `splitWord.elementAnimations` 和 WebAnimation target；如果把 per-character animation clone 到单个 target，或 clone 时丢掉 `composite: "add"`，官方长词/长时值的 scale + float 叠加会失真。 | 只在 `coverBlurFullscreenGenericMode` 下启用。`installFullscreenEmphasizedGlowLayer()` 只打 `data-amll-fs-emphasis-body="1"` 并清理旧 `.amll-fs-cover-blur-glow-layer`；主 body CSS 只恢复强调词 active fill，不承担动画语义。`installFullscreenPackedElementAnimations()` 必须继续 clone `emphasize-word-*` 到原 per-character mapped target；禁止整条跳过，因为该 animation 同时包含 `scale/translate` 与 `textShadow`。`cloneAnimationToElement()` 必须通过 `resolveAnimationComposite()` 保留 source composite，尤其是 `float-word` / `emphasize-word-float*` 的 `add`，否则 float 会 replace 掉 scale。cover blur 只能在 cloned keyframes 上弱化/重染 `textShadow`；base suppress 只能移除 `textShadow`，不能移除 transform。普通 window 不进入 cover-blur profile 调整。 |
| Completed highlight state | `index.html` `updateFullscreenParallelHighlightState()` | `bufferedLines`、`scrollToIndex`、active class、`data-fs-completed-highlight` | 中高。语义是“仍在并行/foreground 组内”，不是 active。 | opacity 不按自身 endTime 熄灭；必须等真实退出组。 |
| Exit catch-up overlay adapter | `index.html` CSS | `data-amll-exit-catch-up` | 中。容易把 catch-up 进度和 opacity fade 混在一起。 | `data-amll-exit-catch-up` 只管高亮扫到行尾所需的可见性；opacity fade 绑定行退出。当前 fullscreen / cover blur smooth overlay 的退出高亮 opacity 曲线为 `0.50s cubic-bezier(0.22, 0.61, 0.36, 1)`；只做视觉曲线调整时不要改 completed/catch-up 选择器。 |
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
