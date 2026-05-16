# AMLL 升级实施日志

本文记录新版 AMLL 接入过程中实际发生的问题、判断、修复和验证。迁移前审计与路线见 `docs/amll-upgrade-migration-audit.md`；长期自定义行为与 patch 维护清单见 `docs/amll-custom-behavior-and-patch-registry.md`。

## 2026-05-14 新版基础接入

现象/目标：

- App 从旧 custom AMLL `0.2.1` 切到新版 AMLL `0.5.0`。
- App 仍需要 DOM `LyricPlayer`、TTML parser、原有 Swift/JS bridge 和多 surface 配置链路。

修复：

- 新版 fork 增加 myPlayer 专用构建入口：
  - `packages/core/src/myplayer-app.ts` 只导出 DOM `LyricPlayer`、interfaces 与 spring type，不导出 bg-render/Pixi。
  - `packages/core/tsdown.myplayer.config.ts` 构建自包含 `dist-myplayer/amll-core.mjs`。
  - `packages/lyric/src/myplayer-app.ts` 提供 App 专用 `parseTTML`，优先走 upstream parser；当新版严格 parser 因旧式 plain TTML 缺少 `itunes:key` 返回 0 行时，fallback 到旧式 `<p begin/end>` 行解析；同时对多语言翻译优先选择中文 `zh*`。
  - `packages/lyric/tsdown.myplayer.config.ts` 构建自包含 `dist-myplayer/amll-lyric.mjs`。
- App 仓库新增 `scripts/sync-amll-from-fork.sh`，从新版 fork 构建后同步到 `Resources/AMLL/`；不手改 generated bundle。
- App `index.html` 改为从 `amll-core.js` 导入 `LyricPlayer`、从 `amll-lyric.js` 导入 `parseTTML`。
- App `index.html` 增加 timeline/internal-state 兼容访问器，兼容新版 `timelineState`。
- `wordHighlightMode` 在新版缺少 core API 时显式降级到 smooth，并输出 `[AMLL-UPGRADE-DOWNGRADE]` 日志；旧离散高亮不迁移。
- `leadInMs` / `nearSwitchGapMs` 先通过 App 侧 lyric preprocessing adapter 恢复基础时间行为；core 缺少旧 API 时输出日志说明由 adapter 接管。
- 新增 `scripts/verify-amll-parser-shape.mjs`，用旧 bundle 备份与当前新版 parser 对同一 TTML 样本做结构 diff。

验证：

- 新版 myPlayer bundle 构建通过；`amll-core.js` / `amll-lyric.js` 无裸 npm import。
- Node import smoke test 通过：`LyricPlayer` 与 `parseTTML` 均可导入。
- Parser diff：`sample.ttml` 行结构通过，`lines=3`，`metadataDiffs=0`。
- 扩展 parser diff 暴露新版 parser 与旧 parser 的真实差异：duet、background translation、romanization、ruby fixture 的结构处理更偏新版 upstream。
- Xcode Debug 构建通过，App bundle 包含新版 `Resources/AMLL/amll-core.js`、`amll-lyric.js`、`style.css` 与更新后的 `index.html`。

## 2026-05-14 WebKit `process is not defined`

现象：

- `Resources/AMLL/index.html` 已在 WKWebView 中加载；`bridge.js`、module script 均执行。
- `window.AMLL` ready 链路正常，Swift 收到 `onReady`，随后 replay config 和下发 `setLyricsTTML`。
- `parseTTML` 成功解析当前 TTML：`lineCount=79`。
- `lyricPlayer.setLyricLines(lines)` 失败，歌词 DOM 未生成。

根因：

- 新版 myPlayer 专用 core bundle 中仍残留 `process.env.NODE_ENV !== "production"`。
- WKWebView 没有 Node `process`，触发 `ReferenceError: Can't find variable: process`。
- 本地 module import 的 `?v=amll-upgrade-phase1-20260514` 可正常 resolve，不是空白根因。

修复：

- 在新版 fork 的 `packages/core/tsdown.myplayer.config.ts` 中把浏览器 bundle define 改为生产常量：`import.meta.env.DEV=false`，并显式定义 `process.env.NODE_ENV="production"`。
- 通过 `scripts/sync-amll-from-fork.sh` 重新从源码构建并同步 `amll-core.js`；没有手改 generated bundle。
- `bridge.js` 增加 `window.onerror`、`unhandledrejection`、`console.warn/error` 转发。
- Swift `LyricsWebViewStore` 将 `[AMLL-BOOT]`、ready、setLyrics、错误类日志提升到可见等级。

验证：

- 重建后的 `amll-core.js` 已无 `process` / `NODE_ENV` 残留。
- Debug App 日志显示：module import 成功、ready 成功、`setLyricsTTML len=36063`、`parseTTML lineCount=79`、`setLyricLines done lineCount=79`、`Loaded lines: 79`。
- 截图确认主窗口右侧歌词恢复显示。

## 2026-05-14 低分辨率渲染核查

现象：

- 升级后需要确认旧版 0.75 倍低分辨率渲染是否仍生效。

根因/判断：

- 旧版 0.75 倍渲染能力的真实实现不是 DOM `LyricPlayer.setRenderScale()`。
- Swift 设置层使用 `amllHighResolutionLyricsEnabled` 控制低分辨率模式；默认未开启高分辨率时，`amllLowResolutionModeEnabled == true`。
- `LyricsSurfaceRole.amllLowResolutionScale = 0.75`，main/fullscreen/standalone 支持低分辨率，batch preview 不受该开关影响。
- `LyricsWebViewStore.layoutWebView()` 才是真正降分辨率的位置：WKWebView frame 按 `0.75` 缩小，`webView.pageZoom = 0.75`，layer 用 `scale(1 / 0.75)` 放回宿主布局尺寸；鼠标 hit-test / event 坐标也按 `0.75` 修正。
- JS 侧 `renderScale: 0.75` 和 `lyricPlayer.setRenderScale(renderScale)` 对当前 DOM `LyricPlayer` 基本不是有效路径；新版日志显示 `hasSetRenderScale: "undefined"`。

修复：

- 没有改 core。继续保留 Swift/WebView adapter 实现，不把低分辨率误迁成 core patch。

验证：

- 实际启动验证显示 main surface 默认进入低分辨率：宿主约 `232x653` 时，WKWebView frame 约 `174x489`，`pageZoom=0.75`，layer scale 约 `1.33`，最终宿主布局尺寸不变。

## 2026-05-15 翻译歌词 CSS hash 回归

现象：

- 新版接入后翻译歌词字体大小/字重配置失效。

根因：

- App CSS 仍依赖旧 CSS module hash 形态或过窄 selector。
- 新版 AMLL CSS module 类名变化后，翻译行 selector 没有稳定命中。

修复：

- 将翻译行相关 selector 改为语义片段匹配，例如 `[class*="lyricSubLine"]`。
- 字体大小、字体族和 light/dark 字重继续由 App CSS variables 驱动。

验证：

- 翻译歌词字体大小/字重恢复；此问题属于 App CSS adapter 层，不需要 fork core patch。

## 2026-05-15 Fullscreen 高亮残留

现象：

- 全屏歌词中，当前行唱完退出后，高亮不会淡出/消失。
- 窗口歌词没有同类残留。

误判与排除：

- 不应恢复旧 `data-amll-exiting-highlight` 机制；根因不是 core 缺旧 data 标记。
- 不应用 `setTimeout` 模拟退出高亮；这会绕过 core timeline/animation。
- 不应直接围绕 `bufferedLines` / `hotLines` 改 core；新版这些状态在 `timelineState` 内，且缓冲行语义不是 overlay 永久高亮语义。

根因：

- 官方 AMLL core 原始行的 active 生命周期正常。
- 真实残留发生在 App fullscreen adapter 的 DOM/CSS overlay 层。
- 新版 CSS module 类名形态变为类似 `xkZOxW_lyricLine`、`xkZOxW_active`；App fullscreen CSS/diagnostics/JS 仍大量使用旧选择器 `[class*="_lyricLine_"]`、`[class*="_active_"]` 和 `className.includes("_active_")`。
- 旧选择器在新版类名上不命中，导致 `.amll-fs-word-active` / `.amll-cb-word-active` 的非 active 行隐藏/降色/退出规则失效。

修复：

- 只修改 App adapter `Resources/AMLL/index.html`。
- 将 fullscreen/cover-blur overlay CSS 与诊断选择器改为能同时匹配新旧 CSS module 的语义片段：`[class*="lyricLine"]`、`[class*="active"]`、`[class*="lyricMainLine"]`、`[class*="lyricSubLine"]`、`[class*="lyricBgLine"]`。
- 同步修正 JS active 判断，让 `updateFullscreenParallelHighlightState()`、diagnostics 与 fullscreen layer patch 能识别新版 `xkZOxW_active`。

验证：

- 普通 fullscreen 和当前 generic cover blur highlight overlay 共用 `.amll-fs-*` 路径，随 selector 修复覆盖。
- legacy `.amll-cb-*` 路径同样做 selector 修复。

## 2026-05-15 Exit Highlight Catch-up

现象：

- 提前切行时，退出行剩余逐字高亮在新版接入后会停在当前进度，然后整行退出。
- 旧版 custom 行为是在退出/隐退动画期间快速补完剩余高亮，同时整行淡出。

根因：

- App adapter 的 `leadInMs` / `nearSwitchGapMs` 会在近距离换行时提前下一行 start，并把上一行 `endTime` clip 到提前切行点。
- 上一行 word end time 仍保留原始逐字时序；切行点时 mask animation 可能没走到行尾。
- 新版 `LyricLineEl.disable()` 在行退出时直接 `pause()` 所有 `maskAnimations`。
- fullscreen / cover blur overlay 复制或替换的是同一组 `splitWord.maskAnimations`，所以 core 一暂停，overlay 视觉层也同步停住。

修复：

- 在新版 fork core 的 `packages/core/src/lyric-player/dom/lyric-line.ts` 增加窄语义 `startExitHighlightCatchUp()`：
  - 仅普通播放退出行触发。
  - seek 退出不触发。
  - 暂停状态不触发。
  - 剩余 mask 进度小于 16ms 时退化为 upstream 原行为。
  - 否则把未完成的 mask animations 以 `playbackRate = remaining / catchUpDuration` 加速到行尾，`catchUpDuration` 限制在 120-280ms。
- `LyricPlayerBase.setCurrentTime()` 把 `isSeek` 传给 `line.disable(isSeek)`，避免 seek 触发 catch-up。
- `pause()` 即使行已退出，也会暂停其 mask animations，避免 catch-up 在暂停状态继续播放。
- fullscreen / cover blur smooth overlay 增加 `data-amll-exit-catch-up="1"`，用于保留 active color / visibility；标记由 animation `finished` promise 清理，不使用 `setTimeout`。
- App adapter 的 `setCurrentTime` 在大跳 `timeDelta > 500ms` 时把本次更新标为 seek。

验证：

- 普通紧邻切行：退出行剩余高亮在退场期间补完。
- 非提前切行、暂停、seek 不触发异常 catch-up。
- 窗口和 fullscreen 共享 core mask continuation；cover blur smooth overlay 识别同一 catch-up 标记。

## 2026-05-15/16 Exit Catch-up Overlay 时间关系修正

现象：

- 第一版 fullscreen / cover blur 适配后，高亮 overlay 不再断掉，但退场时间关系不对：
  - 窗口模式高亮层 opacity 淡出偏早偏快。
  - 全屏模式高亮退场偏晚，整行位移/缩放走到后段，高亮才明显淡出。

根因：

- 第一版把 `data-amll-exit-catch-up="1"` 同时当成“mask 继续补完”和“高亮层保持可见”的条件。
- 这导致 overlay opacity 等 catch-up 标记清除后才开始下降，而不是从行退出同一帧开始。
- 后续复查确认 opacity 目标值写入没有晚于退场起点；视觉“晚开始”的主因是 `opacity 0.50s cubic-bezier(0.42, 0, 1, 1)` 是 ease-in 型曲线，前段过平。

修复：

- 解耦 catch-up 进度和 opacity fade：
  - `data-amll-exit-catch-up` 只保留 active color / visibility。
  - opacity fade 由非 active 行的 CSS 目标立即置为 `0`，从行退出同一时间窗开始。
- fullscreen / cover blur smooth overlay 的 fade timing-function 从 ease-in 型曲线改为 `ease-out`，保留 `0.50s` 时长。
- 窗口模式中，core patch 调整为有 catch-up 时先保留 gradient alpha 路径；没有 catch-up 时才立即切 `SOLID`。

验证：

- fullscreen 提前切行时，高亮层 opacity 与整行退场同起。
- catch-up 仍只负责把 mask 扫到行尾。
- 本阶段没有继续扩大 fork core patch。

## 2026-05-16 并行组完成行高亮提前熄灭

样本：

- L79 v1 `02:43.311-02:47.754 Goodnight`
- L80 v2 `02:44.144-02:45.684 So you don't wake`
- L81 v2 `02:45.684-02:48.107 in the morning`

现象：

- fullscreen 下，L80 到自己的 endTime 后，高亮层提前熄灭。
- 视觉上 L80 仍留在并行显示组里，位移/缩放/模糊退场时间正常。
- 正确行为应是 L80 保持完整高亮，直到它真正开始退场动画时，再让高亮与退场同步淡出。

根因：

- `updateFullscreenParallelHighlightState()` 已经为这类“已完成但仍留在组内”的行设置 `data-fs-completed-highlight="1"`。
- 非 active 行的 `.amll-fs-*` / `.amll-cb-*` opacity 归零规则只排除了 `data-amll-exit-catch-up`，没有排除 `data-fs-completed-highlight`。
- active class 一消失，overlay opacity 就按自身 endTime 归零，而不是按真实退出组的时间归零。

修复：

- App CSS 的非 active overlay 归零规则新增 `:not([data-fs-completed-highlight="1"])`。
- completed-highlight 行继续保持 active overlay opacity；当它真正不再属于 fullscreen 并行/foreground 组时，JS 移除该标记，同一套非 active 规则才开始 opacity fade。

验证：

- 普通 fullscreen `.amll-fs-*` 覆盖。
- legacy cover blur `.amll-cb-*` 覆盖。
- 当前 generic cover blur highlight 主要走 `.amll-fs-*` 路径，也随本修正覆盖。

## 2026-05-16 L5/L6 假 Overlap

样本：

- L5 `00:33.469-00:33.877`
- L6 `00:33.877-00:35.504`

现象：

- 原始 TTML 中 L5/L6 没有 overlap，官方 AMLL 应该是紧邻切行。
- App 里 L5/L6 会被当成并行歌词一起高亮，window 和 fullscreen 都受影响。

根因：

- Core timeline 对行命中使用 start-inclusive/end-exclusive；原始相邻行不会被官方逻辑并行高亮。
- App timing preprocessing 把“焦点提前切换时间”直接写回 `line.startTime`。
- 反向处理 L6 时，上一行 L5 尚未被之后的 fallback lead-in 改成更早 start；此时立即裁剪 L5 `endTime` 会使用旧 start `33.469` 作为下限。
- 随后 L5 start 被提前到 `33.119`，end 却保留在 `33.469`，而 L6 start 已提前到 `33.277`，制造约 192ms 假 overlap。

修复：

- 仍在 App adapter 层修复，不改 core。
- near switch 对上一行的 `endTime` 不再立即按旧 start clamp，而是先登记 pending end cap。
- 所有行的 start lead-in 都应用完后，再用最终 startTime 执行 `clipLineEndTime()`。

验证：

- 默认 `leadInMs=600` / `nearSwitchGapMs=160` 下，同一 TTML 样本处理为 L5 `33.119-33.277`、L6 `33.277-...`。
- `33.300/33.468/33.469/33.877` 等检查点只有 L6 hot，不再并行。
- 保留提前切行，不把原本相邻的结构误判成并行。
- Xcode Debug build 通过。

## 2026-05-16 Cover Blur 强调辉光合成

现象：

- 仅 fullscreen 大封面渐变模糊皮肤受影响。
- lighter 模式下，长时间 emphasis 高亮的辉光过亮、过显眼。
- darker 模式下，emphasis 辉光基本不可见。
- 普通 fullscreen 和窗口歌词不应改变。

根因：

- 当前大封面渐变模糊皮肤走 generic cover blur 路径：Swift 渲染 base/highlight 两个 fullscreen WebView，base 层按 profile 做 `plus-lighter` / `plus-darker` 合成，highlight 层承担强调高光。
- 第一轮修复只恢复了 `.amll-fs-cover-blur-glow-layer`，但没有完整切断 base/highlight packed animation 里的原始 emphasis `text-shadow` clone。
- `installFullscreenPackedElementAnimations()` 会在 glow suppress 之后再次遍历 `__fsSourceElementAnimations`，把 `emphasize-word-*` text-shadow animation clone 到 `.amll-fs-*` stack/char stack 上；所以 base 层仍可能继续发出原始白色 glow。
- 第一轮 retint 还依赖 theme/active color 解析。WebKit 可能返回 `color(display-p3 ...)` 等非传统 `rgb()/rgba()` 字符串，一旦解析失败就退回原始白色 shadow，只乘 `0.28`；AMLL 源 glow alpha 最高约 `0.8`，实际可达 `0.224`，超过旧实现应有的 `<0.2` 上限。
- lighter 下，残留原始白色 glow 与过高 clone alpha 继续被 `plus-lighter` 放大。
- darker 下，亮色/主题色 glow 在最终 `plus-darker` 合成中基本不产生可见暗化效果；需要低 alpha 深色 halo，而不是亮色辉光。

修复：

- 只改 App `Resources/AMLL/index.html` generic cover blur adapter，不改 fork core。
- 普通 fullscreen 继续保持当前行为：`installFullscreenEmphasizedGlowLayer()` 在非 generic cover blur 下直接返回；packed animation 过滤也只在 `isFullscreenCoverBlurGenericMode()` 下生效。
- generic cover blur base 层收到 `coverBlurSuppressEmphasisGlow=true` 时，取消原始 emphasis animations，并把源 word `text-shadow` 置为 `none !important`。
- generic cover blur packed animation clone 显式跳过 `emphasize-word-*` 且非 `float` 的 text-shadow animation，防止 suppress 后又被重新装回 base/highlight 普通文字层。
- generic cover blur highlight 层使用独立 `.amll-fs-cover-blur-glow-layer`：
  - clone 原始 emphasis `text-shadow` animation；
  - glow 子层内部使用 `mix-blend-mode: normal`；
  - 不再依赖 theme color 解析来控制强度，改用 profile 固定策略；
  - lighter：`rgba(255,255,255,0.12)`，alpha multiplier `0.9`，源 alpha `0.8` 时最终最高约 `0.0864`；
  - darker：`rgba(0,0,0,0.16)`，alpha multiplier `0.9`，源 alpha `0.8` 时最终最高约 `0.1152`。
- Glow alpha 原则：cover blur emphasis glow 的最终 text-shadow alpha 必须先保持在已验证稳定的低强度区间；后续微调必须先用 highlight-only layer diagnostics 确认可见来源。

验证：

- A/B 判断：
  - 若关闭独立 glow clone 后仍有辉光，说明 base/packed 层仍在发光；本次通过跳过 generic cover blur packed emphasis text-shadow clone 切断该来源。
  - 若关闭 clone 后辉光消失，说明剩余来源是 clone；本次将 clone alpha 明确压回稳定值，lighter 最高约 `0.0864`，darker 最高约 `0.1152`。
- lighter：base 原始 emphasis glow 被 suppress，普通 packed 层不再重装 text-shadow；可见 glow 只来自 highlight-only 独立 glow layer，强度保持稳定低值。
- darker：highlight-only 独立 glow layer 改用低 alpha 黑色 halo，符合 `plus-darker` 的可见机制，不再依赖亮色 glow。
- 普通 fullscreen/window：未改 core，非 generic cover blur 分支直接返回，视觉路径不变。

回退记录：

- 一次仅调 profile 强度的尝试把 lighter 提到最终 alpha 约 `0.14`、darker 提到约 `0.24`，实测导致 cover blur 下高亮几乎消失。
- 该尝试已回退到上一版稳定参数：lighter `0.0864`、darker `0.1152`。
- 回归原因不是 fork core 或时间轴，而是 App cover blur highlight-only layer 的结构语义：该层会隐藏普通 `.amll-fs-word-active` / `.amll-fs-char-active` 和非 `.amll-fs-glow-layer` 的 stack 子层，强调词的可见高亮主要由 glow clone 承担。把 glow profile 当作"只影响装饰辉光"的独立旋钮是不准确的。
- 后续若继续增强，必须把"装饰 halo 强度"和"主高亮可见性"分离后再调，例如先为 highlight-only 层增加诊断开关确认 source word、glow layer、stack active layer 的 computed visibility/text-shadow，再只调独立 halo，不复用会影响主可见高亮的参数。

## 2026-05-16 Cover Blur Highlight-Only 主高亮 / 装饰 Glow 通道分离

现象：

- 仅 fullscreen 大封面渐变模糊皮肤的 highlight-only WebView 受影响。
- 上一轮回退的稳定参数（lighter ≈ 0.0864、darker ≈ 0.1152）下，darker 模式实测强调高亮基本看不见。
- 普通 fullscreen 和窗口歌词不应改变。

根因（结构性问题，不是 alpha 数值问题）：

- `Resources/AMLL/index.html` 在 `.amll-surface-fullscreen-cover-blur-highlight-only` WebView 内显式隐藏：
  - 非 active 行的所有 lyric 内容；
  - active 行的 main line / sub line / emphasize wrapper 文本（`color: transparent !important`）；
  - `.amll-fs-word-base` / `.amll-fs-char-base`（基础不发光层）；
  - `.amll-fs-word-active` / `.amll-fs-char-active`（本应显示的高亮主体）；
  - `.amll-fs-word-stack` 内除 `.amll-fs-glow-layer` 之外的全部子层。
- 上述策略把"主强调高亮可见性"和"装饰 halo"全部压到 `.amll-fs-glow-layer` 单层承担。
- glow clone 是 source emphasize-word text-shadow animation 经 profile retint 后的结果：lighter 白色 rgba(255,255,255,0.12) × 0.9、darker 黑色 rgba(0,0,0,0.16) × 0.9。叠加 source max alpha 0.8 后，最终最高 ≈ 0.108 白色 halo / 0.144 黑色 halo。
- 这种强度足够作为"装饰辉光"，但在被亮色或暗色 cover blur 浸染的背景上无法稳定承担"主高亮本体可读"。
- darker 模式：≈ 0.144 黑色 halo 在 darker profile 的明亮 cover 表面被 wash out，且没有任何主高亮 fill 兜底，于是表现为"什么都看不到"。
- lighter 模式：≈ 0.108 白色 halo 勉强可见，但本质上是字形轮廓边缘的浅光晕，不构成"该词被高亮"的视觉读出。
- 单纯把 glow alpha 调大会让 lighter 过曝、darker 真正实现"halo 自身可见"但仍是 halo 而非主高亮；继续调 alpha 永远无法解开"装饰 vs 主可见"职责混叠。

修复（仅改 App adapter，不改 fork core）：

- 在 `Resources/AMLL/index.html` 引入"主强调 highlight body"独立通道：
  - 当 `installFullscreenEmphasizedGlowLayer()` 检测到当前 splitWord 在 generic cover blur 模式下有 emphasize-word text-shadow animation 时，先给所属 `.amll-fs-word-stack` 写入 `data-amll-fs-emphasis-body="1"`。
  - 写入 attr 的时机早于 suppress 分支判断，`fullscreenCoverBlurSuppressEmphasisGlow=true` 不会清掉 body 通道——该 flag 语义是抑制装饰 glow，而非整体强调可见。
- 新增配套 CSS，在 line-state 为 `active` / `data-fs-completed-highlight="1"` / `data-amll-exit-catch-up="1"` / `data-amll-exiting-highlight="1"` 时，对于带 `data-amll-fs-emphasis-body="1"` 的 word-stack：
  - 强制 `.amll-fs-word-active`、`.amll-fs-char-stack`、`.amll-fs-char-active` `visibility: visible !important`；
  - color / `-webkit-text-fill-color` 强制为 `var(--amll-fs-cover-blur-body-color, var(--amll-fs-main-active, …))`；
  - 显式 `text-shadow: none !important; filter: none !important;`，保证 body 通道本身不发光、不再叠加 halo。
- 体节奏：char-active 已有 source mask animations，仅恢复可见性即可继续按现有时间轴 progressive reveal；不需要克隆任何 mask animation 到额外节点。
- `.amll-fs-word-base` / `.amll-fs-char-base` / 非高亮行 / 非 active 行 等等的隐藏规则全部保留——body 通道只在被显式打 attr 的强调词上生效。
- `releaseSplitWordAuxiliaryState()` 在拆 stack 节点前清除 `data-amll-fs-emphasis-body`，避免在罕见状态下属性悬挂。
- glow profile 数值本轮**不动**：lighter `rgba(255,255,255,0.12) × 0.9`、darker `rgba(0,0,0,0.16) × 0.9`；同时在 `coverBlurGlowProfiles` 头部加入"decorative-only"注释，明确禁止再用它补偿主高亮可见性。

通道职责分工（修复后定型）：

- 主 emphasis highlight body 通道：
  - 仅在 highlight-only WebView 的 generic cover blur 模式下激活；
  - 仅作用于被标记的强调词 word-stack；
  - 不依赖 glow profile alpha；
  - 颜色走 `--amll-fs-cover-blur-body-color`，缺省回落到 `--amll-fs-main-active` / `--amll-active`，可让后续 Swift 端按 profile 微调 body 主色而不动 glow；
  - 在 lighter / darker 下都是"主可见的强调字"，是否可读由该通道单独负责。
- 装饰 glow 通道：
  - 继续走 `.amll-fs-glow-layer` clone；
  - 仅承担 halo / 装饰光晕；
  - lighter：≈ 0.108 白色弱晕，不过曝；
  - darker：≈ 0.144 黑色暗晕，做"emphasis halo"线索而不再兜底主可见；
  - 后续若要调整 halo 强度，只调 `coverBlurGlowProfiles`，不应触发主高亮消失。

为什么这比继续调 alpha 更稳定：

- 主可见性与装饰晕环现在是两个互不依赖的渲染节点，CSS / JS 路径互相独立；
- 调 glow alpha 只会改变光晕强度，不会再让"darker 整个不显示"；
- 主高亮亮度受主题语义（`--amll-fs-main-active`）驱动，与 cover blur 合成无关；
- 任何模式失效都可单独定位（attr 是否设、CSS 是否命中、主题色是否解析、glow clone 是否存在），不再被叠层语义掩盖。

验证：

- Xcode Debug build 通过（`xcodebuild ... build` 成功）。
- 视觉验证由用户在 app 中确认：
  - darker 模式下强调词本体必须可读；
  - lighter 模式下主高亮清晰、glow 不过曝；
  - 普通 fullscreen / window 路径无 highlight-only class，body 通道 CSS 不生效，视觉应保持不变；
  - 时间轴 / catch-up 路径未触碰。
- 改动文件：
  - `myPlayer2/Resources/AMLL/index.html` — CSS 新增 body 通道选择器；bridge JS 在 `installFullscreenEmphasizedGlowLayer()` 中写入 attr，在 `releaseSplitWordAuxiliaryState()` 中清除 attr；`coverBlurGlowProfiles` 头部加入 decorative-only 注释。
