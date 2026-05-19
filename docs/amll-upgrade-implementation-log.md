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

## 2026-05-18 窗口歌词 Hover A/B 与 Host-driven 回滚

现象：

- 真实低分辨率路径恢复后，`0.5x` / `0.75x` / `1.0x` 的渲染分辨率行为正确。
- 非 `1.0x` 下窗口歌词 hover 背景错位；click seek 仍正确。

A/B 结果：

- `native-off,class-test,coord-raw`：错位。
- `native-off,class-test,coord-div`：错位。
- `native-off,class-test,click-path`：错位更明显。
- 只有 `native-off,class-test,coord-mul` 让 hover 显示贴合正确歌词行。

结论：

- 坐标换算方向确定为：视觉坐标到 AMLL DOM 坐标 = `clientX * quality` / `clientY * quality`。
- 但 JS 原生 `pointermove` 仍受缩小后的真实 WKWebView frame / WebKit tracking region 限制：`0.75x` 只能覆盖左上 75% 区域，`0.5x` 只能覆盖左上 50% 区域。
- 直接在 `WebViewHostView` 捕获完整视觉区域 mouse move 看似能绕开 WebKit tracking region，但实测破坏了原本正确的 WKWebView 事件转发/点击路径。

失败尝试与回滚：

- 曾临时实现 Swift host-driven hover：`WebViewHostView` 捕获 `mouseMoved` / `mouseExited`，`LyricsWebViewStore` 发送 `window.AMLL.updateAppHoverPoint(x, y)`，`index.html` 用 app-driven API 设置 `amll-app-hover-line`。
- 实测结果：hover 框完全不见；click seek 被修坏；非 `1.0x` 下点击区域被限制到真实渲染分辨率区域，能点到的区域坐标不偏，但完整视觉区域下方/右侧点不到。
- 因此该 host-driven hover 方案已回滚，不再作为最终方案记录。

当前状态：

- 保持真实低分辨率模型不变：`webFrame = host × quality`、`pageZoom = quality`、`layer inverse scale = 1 / quality`。
- click seek 的完整视觉区域命中依赖两段路径：`WebViewHostView.hitTest` 在完整 host bounds 内直接返回 `LyricsMouseGatedWebView`，随后 `LyricsMouseGatedWebView.scaledMouseEvent()` 把 window event location 乘 `quality` 后交给 WebKit。
- 回滚 host-driven hover 后仍不能让 `WebViewHostView.hitTest` 先调用 `webView.hitTest(webViewPoint)`；这样事件可能落到 WKWebView 内部子 view，绕过 `scaledMouseEvent()`，点击区域又会被限制到真实渲染 frame。
- hover 可以暂时回到旧错位状态；后续修复必须不截获 NSView 事件链、不改 `WebViewHostView.hitTest` / `mouseMoved` 转发、不影响 click seek。
- 下一步应重点对照原本正确的 click 路径，优先考虑只处理 native `:hover` CSS 与 adapter class，或继续 JS 内部 A/B 取证。

## 2026-05-18 窗口歌词 Hover 透明 Tracking Overlay（Rejected / 已证伪）

> 本节只保留负结果。代码中不应再保留 `LyricsHoverProxyView`、host hover JS API、app-driven hover class 或 pointer metrics A/B harness。

有价值的结论：

- `native-off,class-test,coord-mul` 证明低分辨率下 hover 坐标换算方向是 visual point → DOM point = `point * quality`。
- 但 WebKit native tracking region 仍按真实缩小后的 `WKWebView.frame = host × quality` 建立，坐标修正不能扩大 hover 事件入口。
- 透明 tracking overlay / host-driven hover 会引入 Swift→JS 高频通道，且历史实现曾干扰 click 路径诊断；产品现在也不需要保留 hover indicator。
- `webView.hitTest(webViewPoint)` 不是 hover 修复捷径：它可能命中 WKWebView 内部子 view，绕过 `LyricsMouseGatedWebView.scaledMouseEvent()`，使 click 又退回只覆盖左上真实 frame。

Rejected：

- 不恢复 host-driven hover overlay / proxy。
- 不恢复 `window.AMLL.setHostHoverPoint(...)` / `clearHostHover()`。
- 不恢复 `amll-app-hover-line` / app-driven hover class。
- 不继续用 hover 坐标修复污染 click / scroll 事件链。

## 2026-05-18 窗口/全屏低分辨率事件链路收敛（Accepted）

现象：

- `0.5x` / `0.75x` 下窗口歌词视觉区域完整，但 click seek 只在左上角真实低分辨率 WKWebView frame 内有效。
- 在点不到的窗口歌词区域滚轮，会穿透到底下 Home 页面。
- fullscreen 歌词此前可点击；最近修窗口低分辨率事件时变成不可点击。
- 窗口 hover 圆角提示不再要求修复，产品决策是隐藏；后续复核扩展为 fullscreen hover 也隐藏。

根因：

- 真实低分辨率模型把 WKWebView 的 NSView frame 缩到 `host × quality`，再通过 `pageZoom = quality` 与 layer inverse scale 放回完整视觉尺寸。AppKit hit-testing 不理解 layer inverse scale，因此默认只会命中左上角真实 frame。
- AppKit flat host 路径直接使用 `WebViewHostView`，但没有像 SwiftUI `AMLLWebView.Coordinator` 那样写入 `webViewLayoutScale`，导致窗口主歌词的 host 仍按 `1.0` 处理 hit-test，完整视觉区域没有进入 scaled event path。
- 最近的 host-driven click 修复让 `WebViewHostView` 在 q < 1 时返回 `self` 并调用 `window.AMLL.hostClickAt(...)` 手工 seek。这把 AppKit/WebKit 事件到达问题变成 JS 语义模拟问题；更糟的是 `hostClickAt` 只允许 `isMainSurface`，所以 fullscreen surface 被 host 吞掉 click 后 JS 直接 no-op。
- `WebViewHostView.hitTest(_:)` 曾把 AppKit 已经传入的本地 `point` 又当成 superview 坐标做 `convert(point, from: superview)`。宿主有 padding / 非零 origin 时，这会把完整 bounds 判断偏移，进一步制造局部命中。
- 滚轮穿透的本质同样是命中结构不完整：事件没有稳定落在歌词 WebView/host 的完整视觉区域，Responder 链可继续把 wheel 交给下层 Home。

修复：

- 保留真实低分辨率渲染模型：`WKWebView.frame = host × quality`、`pageZoom = quality`、`layer inverse scale = 1 / quality`。
- `LyricsWebViewStore.layoutWebView()` 在每次布局时把 `renderQualityScale` 同步回 `WebViewHostView.webViewLayoutScale`；AppKit flat host attach 时也立即写入当前质量 scale，避免窗口主歌词漏掉 scale。
- `WebViewHostView.hitTest(_:)` 在 q < 1 时用本地 `point` 检查 `bounds.contains(point)`，并直接返回承载的 WKWebView 本身。不要返回 host/self，不要调用 `webView.hitTest(...)`，因为后者可能命中 WKWebView 内部子 view 并绕过 `LyricsMouseGatedWebView.scaledMouseEvent()`。
- click 重新走原生链路：`LyricsMouseGatedWebView.mouseDown` → `scaledMouseEvent()` → `super.mouseDown` → WebKit 原生 `line-click` / DOM click fallback → Swift `onUserSeek`。
- 2026-05-18 复核发现：`LyricsMouseGatedWebView.scrollWheel` 在 q < 1 时局部吞掉 wheel 会阻断 AMLL 原生 DOM wheel scroll；这是回归，不是 accepted 方案。最终修复见下一节。
- 删除 Swift `dispatchHostClickAt`、`WebViewHostView.onClickAt` 和 JS `window.AMLL.hostClickAt`。
- 删除 app-driven hover class / pointer cleanup 残留；hover indicator 最终改为所有歌词 surface 通过 upstream CSS variable 统一隐藏。

Rejected / 保留负经验：

- contentsScale-only：已实测不能真实降低 WKWebView 内容渲染分辨率。
- DOM `renderScale` 绑定用户质量档：会把 WebView backing quality 与 AMLL renderer scale 耦合，导致 1.0 / 0.5 的 emphasis 回落异常。
- 透明 hover tracking overlay / host-driven hover：坐标证据有价值，但不是产品需要，且增加不稳定通道。
- host-driven click / `hostClickAt`：绕开 WebKit 原生 click，窗口右下仍可能不稳，并直接误伤 fullscreen。
- 直接吞掉低分辨率 `scrollWheel`：可阻止 Home 穿透，但也杀死 AMLL 自身滚动。
- `webView.hitTest(webViewPoint)`：会命中内部子 view，绕过外层 scaled event adapter。

验证要求：

- 三档质量下窗口歌词可见行全区域 click seek，重点测右下角和下半部分。
- 三档质量下窗口歌词卡片全区域滚轮不滚动 Home，且自身仍可滚动。
- fullscreen 歌词 click seek 恢复；cover blur highlight overlay 不接管 hit-testing。
- 窗口/fullscreen hover 圆角背景不显示；不新增 app-driven hover 行为。
- 低分辨率视觉差异仍存在。

## 2026-05-18 滚动 / Hover / Selection 交互回归收敛（Accepted）

现象：

- 最近为了防止窗口歌词滚轮穿透 Home，在 `LyricsMouseGatedWebView.scrollWheel` 的 q < 1 分支直接 `return`，导致窗口和 fullscreen 歌词自身无法用鼠标滚轮 / 触摸板上下滚动。后一轮把 wheel copy 成新的 `NSEvent(cgEvent:)` 并修正 location 再 `super.scrollWheel`，仍未让 WebKit 稳定产生 DOM `wheel`。
- fullscreen 仍显示 hover 圆角背景，说明此前只隐藏 window main selector，没有定位真实 hover 来源。
- 鼠标左键拖动时，歌词文字会像普通网页文本一样被选中。

根因：

- AMLL 的手动滚动不是 AppKit `NSScrollView`，而是 upstream core 在 player 根元素上监听 DOM `wheel`，`preventDefault()` 后更新 `scrollState.scrollOffset`。Swift 层吞掉 `scrollWheel` 会同时阻断 Home 穿透和 AMLL 自身滚动。
- q < 1 的 AppKit 入口已经由 `WebViewHostView.hitTest(_:)` 命中 `LyricsMouseGatedWebView`；断点不在 hit-test。断点在 `LyricsMouseGatedWebView.scrollWheel` 之后：scroll wheel 事件比 mouse event 更依赖原始 WebKit/AppKit 元数据，copy 底层 `CGEvent` 并重建 `NSEvent` 后交给 `super.scrollWheel`，不能作为稳定的 DOM `wheel` 派发方案。
- hover 圆角背景真实来源是 fork/upstream `packages/core/src/styles/lyric-player.module.css`：`.lyricLine:has(> *):hover` / `:active` 使用 `--amll-lp-hover-bg-color` 设置背景色。此前只写 `.amll-surface-main [class*="lyricLine"]:hover`，所以 fullscreen surface 仍按 upstream 默认变量显示。
- upstream `packages/core/src/styles/index.css` 只在 `.amll-lyric-player.dom` 上设置未加前缀的 `user-select: none`。WKWebView 下实际文本节点仍可能被拖选，需要 App adapter 在歌词根与子树补 `-webkit-user-select: none`。

修复：

- `WebViewHostView.hitTest(_:)` 仍负责让完整视觉 host 区域命中 `LyricsMouseGatedWebView`，不改回 `webView.hitTest(...)`，不走 JS seek 模拟。
- `LyricsMouseGatedWebView.scrollWheel` 不再吞掉 q < 1 wheel，也不再 copy/rebuild `NSEvent` 后盲目交给 WebKit。q < 1 时 Swift 保留原始 wheel delta / phase / momentum / inverted metadata 做诊断，并调用很小的 App adapter `window.AMLL.hostWheel(...)`。
- `window.AMLL.hostWheel(...)` 不直接改 AMLL protected/internal state；它只在 `lyricPlayer.getElement()` 上派发标准、cancelable 的 DOM `WheelEvent`。因此真正更新 `scrollState.scrollOffset`、`clampPlayerScrollOffset()`、`calcLayout()` 和 `preventDefault()` 的仍是 upstream core 的 `attachPlayerScrollHandlers(...).wheel` listener。
- q >= 1 保持 `super.scrollWheel(with: event)`，走 WebKit 原生 DOM wheel 派发路径。
- `WebViewHostView.scrollWheel` 只消费“短暂命中 host 而未命中 WebView”的状态，避免 nextResponder 把 wheel 交给 Home；常态滚动必须由 WKWebView 处理。
- `index.html` 在 `.amll-lyric-player` 上设置 `--amll-lp-hover-bg-color: transparent`，覆盖 window / fullscreen / cover blur 的 upstream hover/active 背景来源。
- `index.html` 在 `.amll-lyric-player` 与子树上设置 `-webkit-user-select: none` 和 `user-select: none`，不加 JS `selectstart`，避免为 CSS 可解问题再引入事件补丁。

Rejected / 保留负经验：

- 不为防 Home 穿透而吞掉低分辨率 `scrollWheel`。
- 不再把 scroll wheel 当普通 mouse event：copy `CGEvent`、改 location、重建 `NSEvent` 再 `super.scrollWheel` 已证实不能作为稳定方案。
- 不用 Swift/JS 直接改 AMLL scroll state；q < 1 的 adapter 只补齐 DOM `WheelEvent` 入口，滚动语义仍由 AMLL core wheel handler 执行。
- 不继续用 surface-specific hover selector 猜测上游 CSS；当前稳定入口是 upstream 已暴露的 `--amll-lp-hover-bg-color`。
- 不增加 JS `selectstart` 防线，除非未来目标 WebKit 证明 CSS 禁止选择不足。

验证要求：

- window / fullscreen 在 0.5 / 0.75 / 1.0 下都能滚轮/触摸板滚动歌词本身。
- 在窗口歌词完整卡片区域滚动不再带动底层 Home。
- window / fullscreen hover 圆角背景都不显示。
- 拖动歌词文字不能产生选区。
- click seek、fullscreen click、cover blur highlight、emphasis 动画和三档真实低分辨率效果不受影响。

## 2026-05-19 低分辨率 Wheel Bridge 方向修正（Accepted）

现象：

- q < 1 已恢复能滚动，但鼠标滚轮和触摸板上下滚动方向都与 q = 1 WebKit 原生路径相反。

根因：

- 上一轮 q < 1 bridge 把 AppKit `NSEvent.scrollingDeltaX/Y` 原样写入 DOM `WheelEvent.deltaX/Y`。在 WebKit 的 DOM wheel 语义里，同一物理手势下 DOM `deltaY` 与 AppKit `scrollingDeltaY` 符号相反；因此原样传递会让 AMLL core 的 `scrollOffset += evt.deltaY` 反向。
- `isDirectionInvertedFromDevice` 不是额外翻转开关。Apple 已经把用户的自然滚动设置体现在 `deltaX/Y` 与 `scrollingDeltaX/Y` 中；再基于该标志翻转会造成双重反转。

修复：

- q >= 1 继续作为 ground truth：`LyricsMouseGatedWebView.scrollWheel` 调用 `super.scrollWheel(with:)`，由 WebKit 原生生成 DOM `wheel`。
- q < 1 的 `hostWheel` 映射规则为：`WheelEvent.deltaX = -event.scrollingDeltaX`、`WheelEvent.deltaY = -event.scrollingDeltaY`、`deltaMode = DOM_DELTA_PIXEL`。不乘 quality，不读取 `isDirectionInvertedFromDevice` 来改方向。
- `KMGCCC_AMLL_SCROLL_DIAGNOSTICS=1` 时，Swift 日志同时输出 `event.deltaX/Y`、`event.scrollingDeltaX/Y`、映射后的 `domDeltaX/Y`、phase、momentum、precise、inverted；DOM root 日志输出 `source=native|hostWheel`、`deltaX/Y`、`deltaMode`、surface role、render quality 和 target，用于用同一物理手势对照 q=1 与 q<1。

Rejected / 保留负经验：

- 不把 `isDirectionInvertedFromDevice` 当作手动取反依据；它只描述设备方向和系统滚动方向的关系。
- 不为调方向引入 quality 缩放或速度倍率；方向先和 q=1 原生 DOM wheel 对齐，速度问题单独处理。

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

## 2026-05-16 Emphasis 连续波与 Fullscreen Scale

样本：

- L17 `01:17.210-01:26.020 飘飘荡荡只能飘飘荡荡`

问题 A 现象：

- 旧版 AMLL / 旧 App 中，相邻长时值 CJK 字会形成连续波式 emphasis：前后多个字处于不同上浮、放大、辉光进度。
- 新版接入后变成近似“同时只强调一个字”，连续感断裂。

问题 A 根因：

- 旧 custom `0.2.1` 与旧 upstream reference `0.2.1` 的 emphasis keyframes、`amount` / `blur` / `scale` / `translate` 计算基本一致；连续波不是 custom 特供。
- 旧 upstream 的 `utils/lyric-split-words.ts` 会先拆成 CJK 原子，再用 `Intl.Segmenter(granularity: "word")` 把连续 CJK 原子重新分成语义 chunk。
- 对样本，旧行为会得到 `飘飘荡荡 0-4920`、`只能 4920-5640`、`飘飘荡荡 5640-8810` 三个 chunk；emphasis animation 对 merged chunk 的总时长生成，并对 chunk 内字符 stagger，所以产生连续波。
- 新版 `0.5.0` 的分词逻辑把 CJK 单字作为不可合并 atom 直接输出；同一样本变成 10 个单字独立 chunk。长时值 envelope 被拆小，前后字不再共享一个 emphasis 时间窗。
- 这是 core DOM 行构建前的分词/强调输入变化，不是 App adapter。window、普通 fullscreen、cover blur 都会受影响。

问题 A 修复：

- 在新版 fork core `packages/core/src/utils/lyric-split-words.ts` 中恢复 CJK run 的 `Intl.Segmenter` 分组，保留新版对 ruby / 空白 / 非 CJK 合并的处理。
- fallback 仍是新版行为：当运行环境没有 `Intl.Segmenter` 时，不做额外 CJK regroup。
- 没有改时间轴、mask、seek、pause 或布局逻辑。

问题 B 现象：

- window / 官方 emphasis 有上浮、scale、glow。
- fullscreen clone 层中长时值词 scale 不明显或被吃掉，只剩上浮；cover blur glow 修复后仍需要保留 scale。

问题 B 根因：

- App fullscreen / cover blur adapter 会把官方 `emphasize-word-*` 和 `emphasize-word-float` clone 到 per-character mapped target。
- scale 与 `emphasize-word-float` 都作用在同一个 char stack 的 `transform` 上，必须保留源动画的 `composite: "add"`。
- 旧 clone helper 只读取 `sourceEffect.composite`。在 WKWebView 若该属性不可用，clone timing 会退回默认 `replace`，float transform 会覆盖 scale transform，视觉上只剩上浮。
- window 不走 fullscreen clone helper，因此 window 不受这个 adapter 问题影响；普通 fullscreen、generic cover blur、legacy cover blur 都共享该 helper 或等价路径，均需覆盖。

问题 B 修复：

- App `Resources/AMLL/index.html` 增加 `resolveAnimationComposite()`：
  - 依次读取 `KeyframeEffect.composite`、timing composite、keyframe composite；
  - 对 `float-word` / `emphasize-word-float*` 做 id fallback，强制 clone timing 使用 `composite: "add"`。
- cover blur 仍只 retint/rescale `textShadow`；不移除 transform，不重造私有 emphasis 动画系统。

验证：

- `scripts/sync-amll-from-fork.sh` 构建并同步通过。
- Xcode Debug build 通过，构建产物包含更新后的 `groupCJKWordsBySegmenter()` 与 `resolveAnimationComposite()`。
- `amll-core.js` 由 fork source 重新生成，包含 `groupCJKWordsBySegmenter()`。
- `amll-lyric.js` Node import smoke test 通过。
- `amll-core.js` 在补最小 browser global stub 后 Node import smoke test 通过。
- 用样本时序脚本确认旧分组为 `飘飘荡荡 / 只能 / 飘飘荡荡`，新版修复前为逐字分组；修复恢复旧分组语义。

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

## 2026-05-16 Fullscreen / Cover Blur Emphasis 官方链路回归

现象：

- 普通 fullscreen 下，强调词的官方“放大 + 上浮 + 回落”观感明显弱于窗口歌词。
- 大封面渐变模糊皮肤下，glow 只在少数字符上很淡地出现；部分长时值强调词反而不显示明显 glow。
- 其他皮肤仍能看到 glow，说明 core 的 emphasis 本体仍在。

调查结论：

- fork core 与 `upstream/main` 的 `initEmphasizeAnimation()` 对应实现一致；本轮没有发现 fork core 破坏官方 emphasis。
- 官方 emphasis 是一条完整动画链：
  - `float-word`：普通词轻微上浮。
  - `emphasize-word-*`：per-character `matrix3d scale + translate(x/y) + textShadow glow`，长时值通过 `du` 推导更大的 `amount/blur`；尾词还会放大 `amount/blur/du`。
  - `emphasize-word-float`：per-character 正弦上浮/回落，叠加在前一条 animation 上。
- fullscreen adapter 会 capture 原始 `splitWord.elementAnimations`，再 cancel 源 animation 并 clone 到 `.amll-fs-*` stack/char stack。普通 fullscreen 因为仍按 per-character target clone，大体保留了官方链路，但已经不是原始节点直跑 upstream。
- generic cover blur 的上一轮实现把 `emphasize-word-*` 误判成“text-shadow-only animation”，在 `installFullscreenPackedElementAnimations()` 中整条跳过；这同时丢掉了官方 scale/translate。
- 同时，`installFullscreenEmphasizedGlowLayer()` 把多条 per-character `emphasize-word-*` clone 到单个 `.amll-fs-cover-blur-glow-layer`。这些 animation 使用 `composite: replace`，多个字符的 transform/textShadow 在一个目标上互相覆盖，导致长词和长时值词的官方 glow 时间规律丢失。

修复：

- 只改 App `Resources/AMLL/index.html` adapter，不改 fork core，不改时间轴 / lead-in / catch-up / completed highlight。
- generic cover blur 不再创建独立 word-level glow clone；`installFullscreenEmphasizedGlowLayer()` 只负责给强调词 stack 写 `data-amll-fs-emphasis-body="1"`，并清理旧 `.amll-fs-cover-blur-glow-layer`。
- `installFullscreenPackedElementAnimations()` 在 generic cover blur 下不再跳过 `emphasize-word-*`，而是继续按官方 per-character target clone。
- clone `emphasize-word-*` 时只适配 keyframes 里的 `textShadow`：
  - highlight layer：按 profile retint/rescale，保留官方 transform、duration、delay、per-character stagger。
  - base layer `coverBlurSuppressEmphasisGlow=true`：只把 `textShadow` 置为 `none`，仍保留官方 transform。
- 之前的 body CSS 继续只负责 highlight-only WebView 中强调词主填充可见；它不再承担重造 emphasis 动画语义。

验证：

- `index.html` module script 通过 `node --input-type=module --check -` 语法检查。
- 代码检查确认 core `packages/core/src/lyric-player/dom/lyric-line.ts` 与 upstream 的 emphasis 实现一致；本轮未修改 fork core。
- Xcode Debug build 通过（`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build`）。
- 预期视觉：
  - 普通 fullscreen：保留现有 per-character packed clone，不做 profile 调整。
  - cover blur lighter/darker：官方 scale/translate/float 回到 per-character clone；glow 只做 cover blur 专属弱化/重染，不再由单独 glow clone 重造。
  - window：未触碰。

后续：

- 其他皮肤下 glow 半径/强度略偏大属于单独审美微调；本轮不全局调 glow。

## 2026-05-16 Fullscreen Emphasis Scale 与 Cover Blur Glow 微调

现象：

- Cover blur lighter/darker 下，官方链路恢复后 glow 已稳定，但视觉上可以稍微更明显。
- 普通 fullscreen 和 cover blur fullscreen 的长时值强调词仍缺少明显“放大”，看起来主要只有上浮和 glow；窗口歌词正常。

调查结论：

- 官方 `emphasize-word-*` keyframes 里的 `transform` 同时包含 `matrix3d` scale 与轻微 `translate(x/y)`；`emphasize-word-float` 使用 `composite: "add"`，把正弦上浮/回落叠加在 scale transform 上。
- fullscreen adapter 通过 `cloneAnimationToElement()` 把 core WebAnimation clone 到 `.amll-fs-*` stack/char stack，但原 helper 只复制 `effect.getTiming()`。WebAnimation 的 effect-level `composite` 不在 `getTiming()` 返回值里。
- 结果是 cloned `emphasize-word-float` 从官方的 `add` 退化为默认 `replace`。它后执行时覆盖同一 char stack 上 cloned `emphasize-word-*` 的 `matrix3d` scale，视觉就只剩上浮，scale 被吃掉。
- 影响范围是使用 fullscreen packed animation clone 的普通 fullscreen 和 generic cover blur fullscreen；window 直接跑 core 原始 animation，不受影响。

修复：

- 只改 App `Resources/AMLL/index.html`，不改 fork core，不改时间轴 / lead-in / near switch / exit catch-up / completed highlight。
- `cloneAnimationToElement()` 现在读取 `sourceAnimation.effect.composite`，当 source composite 不是默认 `replace` 时，把它带入 cloned animation options。这样 `emphasize-word-float` 继续以 `add` 叠加，`emphasize-word-*` 的 scale 不再被覆盖。
- Cover blur glow 只做小幅参数微调：
  - lighter：`rgba(255,255,255,0.12)` 保持不变，`alphaMultiplier 0.9 -> 1.0`，源 alpha `0.8` 时最高约 `0.0864 -> 0.096`。
  - darker：`rgba(0,0,0,0.16)` 保持不变，`alphaMultiplier 0.9 -> 1.0`，源 alpha `0.8` 时最高约 `0.1152 -> 0.128`。
- glow 结构不变：仍是 per-character official emphasis chain adapter，只在 cloned keyframes 上弱化/重染 `textShadow`。

验证：

- `index.html` module script 通过 `node --input-type=module --check -` 语法检查。
- `git diff --check` 通过。
- Xcode Debug build 通过（`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build`）。
- 视觉仍需在 App 中确认 lighter 不过曝、darker 可见但不脏，普通 fullscreen / cover blur 都有上浮 + 放大 + glow。

## 2026-05-16 Fullscreen Exit Highlight Fade 曲线微调

目标：

- 仅让 fullscreen / cover blur smooth overlay 的退出高亮 opacity fade 在开头稍早下降一点，后段自然收住。
- 不改 fork core，不改 lead-in / nearSwitch / exit catch-up / completed highlight / active selector / overlap 逻辑。

修复：

- App `Resources/AMLL/index.html` 中 `.amll-fs-word-active`、`.amll-fs-char-active` 与 legacy cover blur `.amll-cb-word-active` / `.amll-cb-char-active` 的 opacity transition 保持 `0.50s` 时长，只把 timing-function 从 `ease-out` 调整为 `cubic-bezier(0.22, 0.61, 0.36, 1)`。
- 非 active 行 opacity 目标值、`data-fs-completed-highlight` 保持规则、`data-amll-exit-catch-up` 可见性适配均未改变。

验证：

- `index.html` module script 通过 `node --input-type=module --check -` 语法检查。
- `git diff --check` 通过。
- Xcode Debug build 通过（`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build`）。
- 视觉仍需在 App 中确认提前切行 catch-up 的高亮淡出更早一点但不突兀，普通并行显示组完成行不提前熄灭。

## 2026-05-16 离散高亮恢复

目标：

- 恢复设置项“减弱高亮(beta)”对应的旧 `wordHighlightMode = discrete` 产品能力。
- 默认关闭时保持当前新版 smooth 连续扫光路径。
- 不带回旧 custom 0.2.1 中的 `data-amll-exiting-highlight` / `data-amll-exit-highlight-word`、exiting suppress、hide/show 不 dispose hack。

旧版视觉参数：

- 旧 custom 0.2.1 的离散高亮本体不是硬切，而是 word/char 的 opacity fade-in：
  - inactive opacity：普通窗口主行 `0.28`，BG 行 `0.4`，fullscreen surface `0`。
  - fade duration：按高亮片段时长计算，并 clamp 到 `300ms...2000ms`。
  - keyframes：18 个 opacity 采样点。
  - easing：`log1p(x * 2.2) / log1p(2.2)`，前段较快、后段自然收住。
  - CJK 连续 chunk 在 discrete 模式下不按整 chunk 同时亮起，而回落到各字自己的 start/end；非 CJK chunk 保持整词/整组高亮。
- 旧版另有离散 exit fade：退出时把已亮词从当前 opacity 以 `ease-out` 淡回 inactive opacity，最长 `280ms` 左右。但该实现依赖旧 data 标记和额外 exit animation list，是历史残留/闪没问题的重要来源，本次不迁移结构。

本次修复：

- fork core 增加 `WordHighlightMode = "smooth" | "discrete"`、`setWordHighlightMode()`、`getWordHighlightMode()`。
- DOM renderer 的 `setWordHighlightMode()` 会对当前已构建行执行 `updateMaskImageSync()`，设置切换可实时重建 mask/opacity animation。
- `LyricLineEl.updateMaskImageSync()` 增加 discrete branch：
  - smooth 仍走现有 `generateWebAnimationBasedMaskImage()` / calc fallback；
  - discrete 走 per-word opacity animation，沿用旧版 18 帧、log easing `2.2`、`300ms...2000ms` duration clamp、窗口 inactive opacity `0.28` / BG `0.4` / fullscreen `0`；
  - discrete animation 仍写入 `word.maskAnimations`，让当前 exit catch-up 可继续以 `data-amll-exit-catch-up` 加速剩余高亮。
- App `index.html` 保留配置下发，不在 overlay 中重做离散动画本体：
  - core API 存在后不再输出旧 `[AMLL-UPGRADE-DOWNGRADE] discrete wordHighlightMode requested but not migrated...`；
  - discrete fullscreen / cover blur 的退出保持逻辑改用当前 `data-amll-exit-catch-up`，不依赖旧 `data-amll-exiting-highlight` / `data-amll-exit-highlight-word`；
  - discrete 模式不再跳过 completed highlight 计算，完成但仍在并行组内的行继续保留 active overlay。

取舍：

- 沿用：opacity fade-in 视觉参数、duration clamp、CJK/非 CJK 高亮粒度、fullscreen inactive opacity 语义。
- 舍弃：旧离散专属 exit data 标记、逐词 exit fade animation list、强力 suppress、hide/show 不 dispose 生命周期 hack、任何会污染 smooth 路径的 mask/opacity 兼容逻辑。
- 退场淡出由当前已稳定的行 opacity fade 与 `data-amll-exit-catch-up` 负责；离散 branch 只提供高亮本体的 opacity fade-in，不重新发明 exit lifecycle。

升级影响：

- 改动集中在 fork core DOM line mask branch 与 App config adapter；parser、timeline、layout、lead-in / nearSwitch、emphasis chain 未改。
- smooth 关闭状态下，`wordHighlightMode` 默认为 `"smooth"`，不会进入 discrete branch；切回 smooth 时会移除 discrete 写入的 inline opacity 并恢复 mask image 路径。
- patch 仍可迁移/剥离：新增 API 和 discrete branch 都围绕 `wordHighlightMode` 单点开关；未来 upstream 若提供正式离散模式，可删除该 branch 并把 App config 映射到 upstream API。

验证：

- fork core `pnpm run typecheck` 通过。
- `scripts/sync-amll-from-fork.sh` 构建并同步 `amll-core.js` / `amll-lyric.js` / `style.css` 通过。
- `index.html` module script 通过 `node --input-type=module --check -` 语法检查。
- Xcode Debug build 通过（`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build`）。
- 视觉仍需在 App 中覆盖：窗口 smooth/discrete、普通 fullscreen、cover blur、提前切行 catch-up、并行 completed highlight、seek/pause/切歌和设置项运行时切换。

## 2026-05-16 离散高亮 envelope 与退场修复

目标：

- 保持已恢复的 `wordHighlightMode = discrete` 产品能力，同时补齐旧版成熟行为里的并行 fade envelope。
- 修复 discrete 下 fullscreen / cover blur 退场延迟、缺少 opacity 渐隐，以及 window 行退场后 inline opacity 残留。
- 不恢复旧 custom 0.2.1 的 `data-amll-exiting-highlight` / `data-amll-exit-highlight-word`、exiting suppress、hide/show 不 dispose hack。

根因：

- A：上一版 discrete WebAnimation 使用“整行扩展 duration + keyframe offset”表达每个词的 fade 片段。视觉上接近旧版，但 animation 自身不是独立 envelope，`endTime` 会被行级 duration 语义放大；exit catch-up 读取 `maskAnimations` 时无法准确知道每个词自己的 `delay + clamp duration`。
- B：fullscreen discrete adapter 仍保留了历史兼容分叉：`.amll-fs-*` / `.amll-cb-*` active 层在 discrete 下被 `transition: none`，非 active 行还会被 visibility hidden / lock 隐藏；同时 catch-up 非 active 选择器没有像 smooth 一样把 opacity 置 0，所以高亮会等 catch-up 结束后再突然消失。
- C：window discrete 的 opacity 是直接写在 word element 上的 WebAnimation/inline opacity。`disable()` 后如果没有 catch-up，只暂停动画，没有把当前 opacity 淡回 inactive；如果有 catch-up，动画完成后也会停在最终高亮 opacity。

修复：

- fork core `LyricLineEl.generateWebAnimationBasedDiscreteWordHighlight()` 改为每个 word/char 自己的 WebAnimation：
  - `delay = highlightStartTime - lineStartTime`；
  - `duration = clamp(wordDuration, 300ms, 2000ms)`；
  - keyframes 只表达 inactive -> active 的 18 帧 log opacity fade。
- `setMaskAnimationState()` 在 discrete 下按 animation 自己的 `endTime` 判断是否继续播放，不再被 line `totalDuration` 提前截断。
- `disable()` 与 catch-up 完成后，如果当前是 discrete 且行已经非 active，会把 word 当前 computed opacity 作为起点，取消原 mask animation，并用 `300ms cubic-bezier(0.22, 0.61, 0.36, 1)` 淡回 inactive opacity；seek 路径即时复位，避免跳转残留。
- App fullscreen / cover blur discrete overlay 不再启用专属 hidden lock：
  - discrete active 层恢复 smooth 同款 `opacity .50s cubic-bezier(0.22, 0.61, 0.36, 1)` transition；
  - non-active / non-completed / non-catch-up 行保持 visibility visible 并把 opacity 置 0，让 transition 生效；
  - discrete 的 `data-amll-exit-catch-up="1":not(active)` 选择器也和 smooth 一样置 opacity 0，catch-up 只保留 active color / visibility，opacity fade 仍绑定真实行退出。

边界：

- smooth mask image 路径未改。
- lead-in / nearSwitch / exit catch-up 判定阈值 / completed highlight / cover blur emphasis 官方链路 adapter 未改。
- 仍没有恢复旧 discrete exit data、旧 suppress 或 hide/show lifecycle hack。

验证：

- fork core `pnpm run typecheck` 通过。
- `scripts/sync-amll-from-fork.sh` 构建并同步 `amll-core.js` / `amll-lyric.js` / `style.css` 通过。
- `index.html` module script 通过 `node --check` 语法检查。
- `git diff --check` 通过。
- Xcode Debug build 通过（`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build`）。
- 视觉仍需在 App 中确认短时值中文连续字/英文短词可并行 fade，window discrete 退场不残留，普通 fullscreen 与 cover blur discrete 退场 opacity fade 与行退出同步。

## 2026-05-16 Apple 风格 Mesh Gradient 播放皮肤

目标：

- 新增窗口与全屏共用的 `Apple 风格` 播放皮肤，背景使用 AMLL 官方 Mesh Gradient / 流体背景。
- 前景封面、LED、频谱沿用现有 `经典` 皮肤布局，不迁移或改写歌词 core 的稳定时间轴成果。
- 背景能力与歌词能力解耦，避免把 `bg-render` 重新塞回 DOM-only 歌词 bundle。

方案：

- fork 新增专用 background bundle entry：
  - `packages/core/src/myplayer-background.ts`
  - `packages/core/tsdown.myplayer-background.config.ts`
- App `scripts/sync-amll-from-fork.sh` 构建并同步 `dist-myplayer-background/amll-background.mjs` 到 `myPlayer2/Resources/AMLL/amll-background.js`。
- App 新增 `Resources/AMLL/background.html`，在独立透明 WKWebView 中加载 `BackgroundRender.new(MeshGradientRenderer)`，只暴露稳定 bridge：
  - `setConfig({ dynamic, fps, flowSpeed, renderScale })`
  - `setAlbum(dataURL)`
  - `setLowFreqVolume(value)`
  - `setPlaying(isPlaying)`
  - `dispose()`
- `amll-core.js` 仍保持 DOM-only lyric bundle，Apple 背景不依赖 `LyricPlayer` 或 fullscreen overlay 内部字段。

窗口皮肤：

- `AppleStyleSkin` 注册到 `SkinRegistry`，名称 `Apple 风格`。
- background 使用 `AMLLMeshGradientBackgroundView`，封面/LED/频谱通过抽出的 `ClassicCoverArtworkView` 复用经典皮肤前景。
- 若全局窗口封面背景开启，Apple 风格会跳过 app-level BKArt 背景，避免盖住 Mesh Gradient。

全屏皮肤：

- `FullscreenPresentationCoordinator.FullscreenSkinID.appleStyle` 注册为全屏皮肤。
- 背景使用同一 Mesh Gradient host，并铺满全屏；封面、LED、频谱沿用经典全屏布局。
- 歌词位置沿用经典全屏布局。
- 歌词颜色使用当前主题取色引擎生成偏亮色组，不使用 cover blur 的 light/dark profile 自动切换。
- `index.html` 新增 `fullscreenAppleStyleMode` root class，Apple 风格允许行/副歌词透明度层级，区别于经典全屏“完全不透明 + 明度区分层级”的策略；lead-in、near switch、exit catch-up、discrete highlight 等时间轴行为不变。

设置与参数：

- 窗口和全屏共用 Apple 背景设置：
  - `skin.appleStyle.dynamicBackgroundEnabled`，默认开启。
  - `skin.appleStyle.flowSpeed`，默认 `standard`。
- UI 复用现有设置样式：Switch `动态背景`，胶囊滑块 `流体速度`。
- 参数映射：
  - `柔和`：`flowSpeed = 0.18`，`FPS = 30`。
  - `标准`：`flowSpeed = 0.32`，`FPS = 30`。
  - `活跃`：`flowSpeed = 0.55`，`FPS = 60`。
- `renderScale` 固定 `0.6`，不新增清晰度 UI。

音频采样生命周期：

- 动态背景开启且 Apple 背景 view 存在时，`AMLLMeshGradientBackgroundView.Coordinator` 以独立 consumer 身份调用 `AudioVisualizationService.shared.start()` 并 `addConsumer`。
- 低频输入使用 `band0 * 0.72 + band1 * 0.28`，再经 `pow(raw, 0.82) * 0.65` 限制到 `0...0.55`，驱动 `setLowFreqVolume()`，只做轻微呼吸律动。
- 关闭动态背景、离开 Apple 风格、view dismantle 或 dispose 时移除该 consumer 并调用 `AudioVisualizationService.shared.stop()`。
- LED / 频谱仍通过各自 consumer 与引用计数维持采样；Apple 背景只释放自己的 consumer，不直接关闭其他可视化需求。

验证：

- fork background bundle 通过 `scripts/sync-amll-from-fork.sh` 构建并同步。
- `amll-background.js` 产物不包含 Pixi renderer 路径，歌词 `amll-core.js` 仍由 DOM-only entry 构建。
- Xcode Debug build 通过后需在 App 中手动确认：窗口/全屏 Apple 背景显示、切歌换图、resize、切换皮肤停止渲染采样、动态背景开关与三档速度即时生效、重启后设置恢复。

## 2026-05-16 Apple 风格黑屏与透明度修复

目标：

- 修复 Apple 风格窗口 / 全屏切入后 Mesh Gradient 背景实际不可见、只显示黑底的问题。
- 修复 Apple 风格全屏歌词仍被经典全屏“不透明 + 明度层级”CSS 覆盖的问题。
- 重做 Apple 风格 skin picker 预览卡片，使其回到现有皮肤卡片的单色、线框、符号化设计语言。

黑屏根因：

- 背景 WebView 的 `didFinish` 被当作 renderer ready 使用，但这只代表 `background.html` 导航完成，不代表 `amll-background.js` module import、`BackgroundRender.new(MeshGradientRenderer)`、canvas 插入或 fallback album 已完成。
- 本地 file URL 下的 module import 缺少显式 file access 配置时，页面可以加载而 `./amll-background.js` 访问失败；旧页面没有把 module import failure / unhandled rejection 回传到 App 日志，Swift 侧 optional chaining 又会吞掉后续 bridge 调用。
- Swift host 和 `background.html` 都使用黑色或透明黑底作为失败兜底，导致“renderer 没起来”和“深色有效帧”在实机上无法区分，最终表现为纯黑。

修复：

- `background.html` 改为动态 import `./amll-background.js`，在 bootstrap 内捕获并通过 `backgroundDebug` 回传 `bootstrap-start`、`module-imported`、`renderer-created`、`bootstrap-ready`、`bootstrap-failed`、`error` 和 `unhandledrejection`。
- `AMLLMeshGradientBackgroundView` 新增 `backgroundDebug` message handler，开启 WebKit developer extras / file URL access，并只在收到 `backgroundReady` 后下发 config、artwork、playing 状态；`didFinish` 只记录导航完成日志。
- `background.html` 增加非黑 CSS fallback 与生成式 fallback album。无封面时仍调用 `setAlbum(fallback)`，动态背景关闭时 pause renderer 但保留可见静态背景。
- `AppleStyleSkin` 移除黑色 WebView 背景，改为主题色 Swift fallback 放在 Mesh WebView 下方。

全屏歌词 opacity 根因与修复：

- 初版 `fullscreenAppleStyleMode` CSS 放在较早位置，之后的经典 fullscreen CSS 又把行内 child/subline opacity 强制为 `1`，并把 background vocal hidden/opacity 归零，所以 Apple 风格实际仍呈现经典全屏的完全不透明语义。
- 新增最后声明的 `.amll-surface-fullscreen-apple-style` 专属 override，只作用于 Apple 风格 fullscreen：
  - inactive line opacity `0.42`；
  - active 行容器保持 `1`，但未播放到的 word/char base opacity `0.48`；
  - translation/subline opacity `0.34`，active translation `0.58`；
  - background vocal opacity `0.18`，active background vocal `0.36`；
  - active highlight 层 opacity `1`，bright mask alpha `1`，dark mask alpha `0`。
- 时间轴相关自定义没有改变：lead-in、near switch、exit catch-up、completed highlight、discrete highlight 仍走原有 App/fork 链路。

预览卡片：

- 移除彩色 AngularGradient、频谱柱和海报化元素。
- Apple 风格预览现在只保留单色 56x56 卡片、两条抽象流体曲线和经典封面 glyph，与其他 skin preview 的线框 / 单色 / 简化布局保持一致。

验证：

- `git diff --check` 通过。
- Xcode Debug clean build 通过：`rm -rf /tmp/kmgccc_player_derived && xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -derivedDataPath /tmp/kmgccc_player_derived SWIFT_ENABLE_INCREMENTAL_COMPILATION=NO build`。
- 实机可见验证使用 `/tmp/kmgccc_player_derived/Build/Products/Debug/kmgccc_player.app`：窗口 Apple 风格已从纯黑变为可见流体 / fallback 背景，经典前景封面与 LED 正常；设置 bundle 中 `background.html` / `index.html` 均确认包含本次修复后的 diagnostics 与 Apple fullscreen override。

## 2026-05-17 Apple 风格全屏歌词改走 Cover Blur Lighter Path

目标：

- 修正 Apple 风格 fullscreen 歌词方向：不再从经典全屏歌词逻辑另起一套 AppleStyle opacity overlay。
- Apple 风格 fullscreen 歌词改为复用已经打磨稳定的全屏大封面渐变模糊 generic lyric path，只固定为 `lighter` profile / `plus-lighter`。
- 修复 fullscreen 快速设置切换 skin 后，歌词颜色与 surface 语义不立即刷新的问题。

根因：

- 上一版 `fullscreenAppleStyleMode` 在 `index.html` 中维护了 Apple 专属 line/subline/background vocal/interlude dots opacity 规则。
- 这些规则没有复用 cover blur generic path 的成熟状态语义，导致 interlude dots 被固定为半透明、translation current/inactive 透明度分叉、exit fade/catch-up 与 cover blur 不一致。
- Swift 侧 `fullscreenLyricsConfigSignature` 没包含 `settings.fullscreen.skinID`，且 `settings.fullscreen.skinID` 变化时只在涉及 cover blur skin 的转场中 reload lyrics surface。快速设置卡片切换到其他歌词语义 skin 时，旧 WebView CSS vars/config 可能继续保留，直到手动刷新歌词。

修复：

- `FullscreenPlayerView` 新增 `usesCoverBlurLyricsRenderingPath`，Apple fullscreen 与 cover blur fullscreen 在歌词合成层走同一判断。
- Apple fullscreen 的主 AMLL WebView blend mode 固定为 `.plusLighter`，不使用 compositing group；普通经典 fullscreen 保持 `.normal`。
- `applyFullscreenLyricsTheme()` 中 Apple fullscreen 不再调用独立 `makeAppleStyleLyricsColorSet()`，而是构造固定 `.lighter` 的 `FullscreenCoverBlurLyricsTheme`：
  - theme color 来自 `resolveFullscreenLyricsBaseColor()` / 主题取色引擎；
  - color set 复用 `makeCoverBlurLyricsColorSet(from:profile:.lighter)`；
  - config 下发 `coverBlurFullscreenGenericMode=true`、`coverBlurFullscreenGenericProfile=lighter`、`coverBlurFullscreenThemeColor=<theme color>`；
  - `fullscreenAppleStyleMode=false`，避免旧 Apple 专属 CSS 重新参与。
- `index.html` 删除 `.amll-surface-fullscreen-apple-style` 的专属 opacity / dots CSS。
- `index.html` 将 generic cover blur 的 interlude dots 也纳入 cover blur dots visibility 规则：默认 hidden，只有 renderer 打上 `enabled` 状态才 visible；dot body 使用 cover blur blend var，并在 generic root state 写入 `--amll-cb-main-blend`。
- skin 切换时无论是否进入/离开 cover blur，都会强制 `applyFullscreenLyricsTheme(force:true)`；同时把 `settings.fullscreen.skinID` 纳入 `fullscreenLyricsConfigSignature`，保证快速设置和完整设置页都触发 config/theme 重新下发。

边界：

- 未改 fork core，未改 `amll-core.js` 生成链路。
- Window Apple 风格不受影响：窗口只使用 Mesh Gradient 背景和经典前景，不改窗口歌词。
- Cover blur 自动 lighter/darker profile 保持原逻辑；Apple 只固定为 lighter，不使用 `plus-darker` 或 cover blur 背景。
- 普通经典 fullscreen 仍使用原有不透明/明度层级语义。

验证：

- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build` 通过。
- 本轮按用户要求不继续执行 App UI 实机验证，由用户接手验证 fullscreen Apple 风格实际可见效果与快速设置切换结果。

## 2026-05-17 Apple 风格设置与 Cover Blur Generic Dots 回归修复

目标：

- 修复 Apple fullscreen 与全屏大封面渐变模糊皮肤间奏点出场时重复缩放 / 闪回最小的问题。
- Apple 风格窗口 / 全屏 LED 始终使用偏亮配色。
- 提升 Apple Mesh Gradient 三档流体速度。
- Apple fullscreen 豁免背景压暗层，并在选中 Apple 风格时隐藏 `背景压暗强度` 设置项。
- 全屏 skin picker 将 `大封面` 排在第一；优化大封面与 Apple 风格预览图。

根因与修复：

- Dots 抽搐：
  - 根因是上一轮把 legacy cover blur 的 interlude dots `visibility:hidden` / `[enabled]` 可见性规则扩展到了 `.amll-surface-fullscreen-cover-blur-generic`。
  - Generic cover blur path 本来由 AMLL renderer 自己管理 dots show/scale-in。新增 visibility 规则会在 renderer 切 `enabled` 状态时重新参与可见性，造成 scale-in 动画看起来被重启或闪回最小。
  - 修复为移除 generic root 的 visibility hack；只保留 generic dots body 的颜色 / blend 适配，legacy cover blur 仍保留原规则。
- LED：
  - 根因是 Apple 风格复用 `ClassicCoverArtworkView`，而该 view 只有在 `artBackgroundIsUltraDark` 时才传 `forceBrightLEDColors`。浅色 App 外观下 LED resolver 会走偏暗策略。
  - `ClassicCoverArtworkView` 新增可选 `forceBrightLEDColors` 参数，Apple 风格调用时固定传 `true`；其他皮肤默认值不变。
- Mesh 速度：
  - 三档 `flowSpeed` 上调为：`gentle 0.32`、`standard 0.58`、`active 0.92`。FPS 仍为 `30/30/60`，renderScale 仍为 `0.6`。
  - `background.html` 默认 flowSpeed 同步更新为 `0.58`，避免 bridge config 前 fallback 使用旧标准速度。
- 背景压暗：
  - 根因是 `FullscreenPlayerView.fullscreenBackgroundLayer` 对所有 custom background skin 都统一叠 `effectiveDimmingIntensity * 0.7` 的黑层。
  - Apple fullscreen 现在跳过这层；`FullscreenSkinTabView` 在 Apple skin 选中时隐藏 `背景压暗强度`，切回其他 skin 后恢复。
- Picker / preview：
  - `SkinRegistry.fullscreenOptions` 仅对 fullscreen selector 排序，把 `fullscreen.coverGradientBlur` 放到第一；window selector 不受影响。
  - 大封面 preview 从小 `photo` glyph 改为更大的 60x60 单色圆角矩形 + photo glyph。
  - Apple preview 删除流体细线，改为 56x56 单色圆角矩形 + `A`。

边界：

- 未改 AMLL fork core。
- Apple fullscreen 仍复用 cover blur generic lighter / plus-lighter lyric path。
- Cover blur 自动 lighter/darker profile、经典 fullscreen、窗口歌词、Mesh 背景采样生命周期均未改。

验证：

- `git diff --check` 通过。
- Xcode Debug build 通过（使用独立 DerivedData：`xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug -derivedDataPath /tmp/kmgccc_player_codex_build build`）。
- App 内可见效果仍需手动确认：Apple / cover blur dots 单次出场、Apple LED 在浅/深色模式均偏亮、Apple 背景压暗项隐藏与预览卡片视觉。

## 2026-05-17 Cover Blur Generic Interlude Dots Opacity 回归修复

目标：

- 只修 Apple fullscreen 与全屏大封面渐变模糊皮肤的 interlude dots 抽搐 / 三颗点全亮问题。
- 不改 LED、Mesh flowSpeed、preview、背景压暗、AMLL fork core。

正常路径 vs 异常路径：

- 普通 fullscreen 正常路径只给 `[class*="interludeDots"] > *` 设置主题 `background-color`，不碰 dots root 的 `visibility` / `transition` / `transform`，也不碰三个 dot child 的 inline `opacity`。
- AMLL core `InterludeDots.update()` 每帧直接写三颗 dot child 的 `style.opacity`：初始受 `globalOpacity` 控制为 0，随后 dot0 / dot1 / dot2 分阶段从 `0.25` 走到 `1`；root `style.transform` 负责出场 scale。
- 异常 generic cover blur path 仍和 legacy cover blur 共用 dots child selector，强制写了 `opacity: 1 !important` 和 per-dot `mix-blend-mode`。上一轮只移除了 generic root visibility hack，但没有移除 child opacity 覆盖，所以 AMLL 写入的分阶段 opacity 仍被 CSS 压掉，三颗点一出现就全亮；全亮也让本应被 `globalOpacity` 隐藏的早期 scale 曲线直接暴露，视觉上像 scale-in 被重启/抽搐。

修复：

- 将 `.amll-surface-fullscreen-cover-blur-generic [class*="interludeDots"] > *` 从 legacy cover blur dots selector 中拆出。
- Generic cover blur dots 现在只接收 cover-blur theme `background-color`。
- Generic cover blur dots 不再覆盖 `opacity`、`visibility`、`transition`、`transform`、animation，也不再对 dot child 强制 `mix-blend-mode`；整体 plus-lighter 语义继续由 fullscreen WebView/skin blend 层承担。
- Legacy `.amll-surface-fullscreen-cover-blur` dots 规则保持原状，避免扩大到旧 cover blur final-layer 兼容路径。

验证：

- `git diff --check` 通过。
- 本轮按用户要求不做 App 内实测；需由用户确认 Apple fullscreen 与大封面渐变模糊 fullscreen dots 恢复初始半透明、逐颗变亮、单次出场和正常消失。

## 2026-05-17 AMLL 渲染质量与窗口 Emphasis 回落调查

目标：

- 三档歌词渲染质量保持为低 `0.5x`、中 `0.75x`、高 `1.0x`，默认中。
- 解释为什么恢复 CJK Segmenter 后，窗口歌词 emphasis 在 `0.75x` 下正常，但 `1.0x` / `0.5x` 仍可能出现上浮回落后的突降。
- 不恢复旧离散高亮、exiting suppress 或旧 emphasis 动画 patch。

根因：

- 渲染质量的真实旧实现是 Swift host 的 WKWebView 几何路径：缩小 WebView frame、设置同档 `pageZoom`，再用 layer transform 放回宿主尺寸。
- 本轮新增三档时，一度把 `settings.amllLyricsRenderQuality` 同时传给了 AMLL JS config 的 `renderScale`，导致 `LyricPlayer.setRenderScale()` 从原本稳定的 `0.75` 切到 `1.0` 或 `0.5`。
- `0.75x` 正常不是因为它神奇修复 WebKit，而是因为它恰好等于窗口、fullscreen、cover blur 的 DOM renderer 默认 scale。`1.0x` / `0.5x` 异常来自“WebView backing quality”和“AMLL DOM renderer scale”被耦合后，WebKit 文本 transform / emphasis WebAnimation 在不同 CSS/layout 栅格上重新取整。
- CJK Segmenter 修复解决的是长时值中文被逐字 chunk 导致的 emphasis envelope 断裂；本次问题是另一个层面：DOM renderer scale 改变后的 WebKit text/transform rasterization。

修复：

- `LyricsSurfaceRole.renderScale` 重新只表示 AMLL DOM renderer 的 per-surface 默认值：窗口、fullscreen、cover blur 为 `0.75`，batch preview 为 `0.45`。
- 用户三档质量只由 `AMLLWebView` / `LyricsWebViewStore` 应用到 WKWebView frame、`pageZoom`、layer transform、hit-test scale。
- `LyricsWebViewStore` 增加统一布局日志，记录 role、host bounds、web frame、`pageZoom`、layer scale、window backing scale、layer contents/rasterization scale、effective host backing scale。
- `index.html` 增加 `[AMLLScaleMetrics]`，记录 surface role、DOM renderer scale、`devicePixelRatio`、visual viewport scale、CSS viewport 与 player rect，用于后续区分 CSS viewport 问题和 AppKit layer 问题。

边界：

- 未修改 fork core，未手改 generated `amll-core.js`。
- 未改 lead-in、seek、pause、exit catch-up 或 CJK chunking。
- Fullscreen 与 cover blur 仍使用同一用户质量设置控制 WebView backing scale；batch preview 保持独立默认，不受用户质量影响。
