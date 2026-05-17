# AMLL 歌词性能诊断

> 更新日期：2026-05-16  
> 范围：只整理诊断结论，不修改代码。本文保留必要代码定位，但不把尚未测量的推断写成定论。

## 1. 结论摘要

这次复查修正了两条旧判断：

1. **不能再把 Liquid Glass 背景写成歌词面板拖慢 Home 的首要瓶颈。**  
   代码能确认的是：窗口歌词使用透明 `WKWebView`，它嵌在较深的 SwiftUI + AppKit 宿主层级中，播放时 Web 内容持续动画。这些因素叠加后，可能增加同一窗口的合成压力。  
   但代码不能证明 glass material 本身是关键瓶颈。此前 Home 性能排查也已经验证过，系统材质本身不是主要开销。更准确的嫌疑对象是持续动画的透明 WebView、Web 内容自身的 CSS/WAAPI 开销，以及透明 WebView 与原生窗口层级之间的合成路径。  
   **玻璃材质存在，但它是不是关键性能瓶颈，目前没有直接证据。**

2. **浅色模式窗口歌词里的黑色暗影，不是 upstream emphasis 的白色 glow。**  
   已确认的来源是根节点静态样式：

   ```css
   text-shadow: 0 1px 2px <shadowColor>
   ```

   这条阴影由 App 主题色链路传入，并继承到每个字和每一行歌词。旧文档把浅色模式暗影归因到白色 emphasis halo，是错误判断。本文已直接修正。

当前较稳妥的性能结论是：

- 开歌词面板会让 Home 更容易掉帧，这一点成立。
- 原因不是“就是玻璃慢”，而是窗口里多了一个持续工作的歌词 WebView。
- 这个 WebView 内部有 RAF 渲染循环、WAAPI 强调动画、`text-shadow`、`mix-blend-mode`、blur/filter 等工作。
- 这些工作和 Home 的滚动、resize、SwiftUI/AppKit 合成共享同一个窗口帧预算。
- Safari 实验场更顺并不矛盾：同样是 WebKit，不等于同样的宿主合成路径。

## 2. App 中 AMLL 的基本渲染结构

App 使用 AMLL 的普通 DOM renderer，也就是 `LyricPlayer`。不是 canvas，也不是 `dom-slim`。这一点在迁移文档和 `index.html` 初始化路径中保持一致。

### Surface 角色

`LyricsSurfaceRole.swift:12-30` 定义了多个歌词 surface：

| 角色 | 用途 | 备注 |
|---|---|---|
| `main` | 窗口歌词面板 | Home 里打开的歌词栏 |
| `fullscreen` | 普通全屏歌词 | 全屏主歌词 WebView |
| `fullscreenCoverBlurHighlight` | 封面模糊全屏高亮层 | 只在封面模糊全屏模式启用 |
| `batchPreview` | 批量编辑预览 | 独立实例 |
| `standalone` | 独立窗口预留 | 未来用途 |

`LyricsSurfaceManager.swift:206-210` 会在进入全屏时销毁 `main` store，在回到窗口时销毁 fullscreen stores。也就是说，普通 Home + 歌词面板场景下，主要关注的是 `main` 这个 WebView。

### WebView 是透明的

透明链路有两处代码证据：

- `index.html:9-20`：`body`、`html` 和 `#player` 都是 `background: transparent`。
- `LyricsWebViewStore.swift:1540-1541`：`WKWebView` 创建后执行 `webView.setValue(false, forKey: "drawsBackground")`。

这说明歌词 WebView 的内容会以透明层的形式合成到 App 窗口里。

### Swift 到 JS 的时间更新不是主瓶颈

代码显示 Swift 侧并没有高频把时间灌进 WebView：

- `LyricsPanelView.swift:318-319` 监听 `playbackCoordinator.presentation.currentTime`，然后调用 `lyricsVM.syncTime(newTime)`。
- `PlaybackCoordinator.swift:420-423` 的 `presentationTimer` 是 0.25 秒一次，约 4 Hz。
- `LyricsWebViewStore.swift:542-554` 对 `setCurrentTime` 做 10 ms 去重。
- `LyricsWebViewStore.swift:1637-1675` 对正在处理中的时间同步做 in-flight gate，只保留最新的排队值。
- `index.html:4937-4944` 在非全屏、播放中且不是 seek 的小步时间更新中会提前返回，减少外部时间同步对主窗口路径的干扰。

因此，Swift -> JS 桥接频率不是当前最可疑的性能瓶颈。真正持续运行的是 WebView 内部的 AMLL 动画和布局循环，例如 `index.html:5382-5384` 的 `requestAnimationFrame(animate)`。

## 3. 为什么开歌词面板会拖慢 Home

这里分成三层：代码事实、高可信推断、待验证假设。

### 已被代码确认的事实

- 窗口歌词面板里存在一个透明 `WKWebView`。证据见 `index.html:9-20` 和 `LyricsWebViewStore.swift:1540-1541`。
- WebView 通过 `AMLLWebView` 这个 `NSViewRepresentable` 嵌入 SwiftUI。`AMLLWebView.swift:45-72` 创建/更新宿主 view，`AMLLWebView.swift:221-268` 把 store 持有的 WebView attach 到 `WebViewHostView`。
- `WebViewHostView` 是 AppKit `NSView`，负责布局和命中测试。见 `AMLLWebView.swift:323-386`。
- 窗口歌词面板背景在 SwiftUI detail column 场景下可能包含 `.glassEffect(.regular, ...)`。见 `LyricsPanelView.swift:130-156`。
- 歌词播放时，Web 内容持续有动画工作：AMLL RAF、逐词 mask、emphasis WAAPI、CSS transition/filter 等。

### 高可信推断

开歌词面板后，Home 变慢的直接原因更像是“同一窗口内多了一个持续动画的透明 WebView”，而不是单独某个材质。

更具体地说：

- Home 滚动和歌词 WebView 动画都要在同一个窗口帧预算内完成。
- 透明 WebView 需要和后面的 SwiftUI/AppKit 内容合成。
- 窗口 main surface 还保留了 `mix-blend-mode: plus-lighter`，这会让 Web 内容走更复杂的合成路径。
- Web 内容内部还有 text-shadow、WAAPI、blur/filter、逐字符 transform layer 等成本。

这些因素叠加，足以解释“Home 自己优化过，但歌词打开后整窗仍更容易掉帧”。

### 仍需测量的部分

现在还不能从代码推出：

- glass material 本身是主瓶颈；
- 透明合成一定比 Web 内容自身更重；
- `mix-blend-mode`、静态阴影、emphasis glow、blur/filter 各自占比是多少。

这些需要 Instruments 或 A/B 才能排序。本文后面给出建议测试顺序。

## 4. 三种歌词 surface 的阴影和 glow 差异

这里要先把三个概念分开：

- **静态文本阴影**：根节点 `text-shadow: 0 1px 2px <shadowColor>`，不是动画。
- **upstream emphasis glow**：AMLL core 的 WAAPI 动画，在唱到强调字词时给字符加白色 `textShadow`。
- **App 注入的 fullscreen/cover-blur glow layer**：App adapter 克隆元素或动画，放到额外 layer 中显示 glow。

| Surface | 静态根级 `text-shadow` | upstream per-char emphasis `textShadow` | App 注入 glow layer | 关键代码 |
|---|---|---|---|---|
| 窗口歌词 `main` | 有。来自 `shadowColor`，继承到所有歌词文字 | 有。窗口模式不走 fullscreen suppress | 无 | `index.html:5226-5233`、fork `lyric-line.ts:813-827` |
| 普通全屏歌词 | 关闭。根节点设为 `text-shadow: none` | 被 App adapter 抑制/迁移 | 使用 `.amll-fs-glow-layer` | `index.html:469-481`、`index.html:839-871` |
| 封面模糊全屏歌词 | 关闭。不是窗口那套根级阴影 | base/highlight 路径会抑制、重染或弱化 | 使用 `.amll-cb-glow-layer` 或 generic `.amll-fs-*` cover-blur 路径 | `index.html:82-90`、`index.html:430-450`、`index.html:2293-2318`、`index.html:2843-2877`、`FullscreenPlayerView.swift:943-960` |

### 窗口歌词 main surface

窗口歌词有两类效果：

1. 静态黑色文本阴影  
   `index.html:5226-5233` 在收到 `shadowColor` 时设置：

   ```js
   lyricPlayer.getElement().style.textShadow = `0 1px 2px ${config.shadowColor}`;
   ```

   这个样式在 `.amll-lyric-player` 根节点上。CSS 的 `text-shadow` 会继承，所以每个字都会带这层阴影。它是常驻样式，不跟随 emphasis 动画启动或结束。

2. 强调字动态白色 glow  
   fork core 的 `packages/core/src/lyric-player/dom/lyric-line.ts:813-827` 会创建 `emphasize-word-*` WAAPI 动画，其中 keyframe 包含：

   ```ts
   textShadow: `0 0 ${Math.min(0.3, blur * 0.3)}em rgba(255, 255, 255, ${glowLevel})`
   ```

   这是唱到强调字词时才出现的白色 halo。它和上面的静态阴影不是一回事。

### 普通全屏歌词

普通全屏不使用窗口模式的根级静态阴影：

- `index.html:469-481` 把 `.amll-surface-fullscreen` 的 `text-shadow` 设为 `none`。
- `index.html:839-871` 定义 `.amll-fs-glow-layer`，用 `drop-shadow(...)` 显示全屏 glow。
- highlight-only 相关规则还会在 `index.html:967-980`、`index.html:992-997`、`index.html:1048-1059`、`index.html:1070-1084` 抑制普通文字或原始 `text-shadow`。

所以普通全屏的 glow 是 App adapter 重新组织过的，不等同于窗口 main 的原始 upstream emphasis glow。

### 封面模糊全屏歌词

封面模糊全屏也没有窗口模式那套静态根级阴影：

- `index.html:82-90` 把 cover-blur 根 surface 的 `text-shadow` 设为 `none`。
- legacy cover-blur 路径定义 `.amll-cb-glow-layer`，见 `index.html:430-450`。
- generic cover-blur 路径会识别 `emphasize-word-*` 动画，重染或缩放其中的 `textShadow`，见 `index.html:2293-2318`、`index.html:2361-2388`。
- `installFullscreenEmphasizedGlowLayer()` 只给 word stack 标记 `data-amll-fs-emphasis-body="1"`，让 highlight-only WebView 显示强调词主体。见 `index.html:2843-2877`。
- Swift 侧封面模糊全屏会同时渲染 base 和 highlight 两个 WebView：`FullscreenPlayerView.swift:943-960`。

这条路径比普通全屏更重，因为它可能同时运行两个歌词 WebView。它也不是窗口 main 的原始 glow 机制。

## 5. 浅色黑影与深色 glow 的真实来源

旧文档最重要的错误，是把浅色模式窗口歌词里黑字下方的暗影归因到 upstream emphasis 的白色 glow。

这个判断现在应改为：

- 浅色模式窗口歌词里，黑字下方明显暗影来自根节点静态 `text-shadow`。
- upstream emphasis 白色 glow 仍然存在，但它是“唱到强调字词时才出现”的动态效果。
- 两者可以同时存在，但视觉现象不同。

### 静态黑影链路

已确认链路如下：

1. `ThemeStore.swift:23-31` 定义 `ThemePalette.shadow`。
2. `ThemeStore.swift:394-400` 在浅色模式下生成 `shadow = "rgba(0, 0, 0, 0.15)"`，深色模式下生成 `shadow = "rgba(0, 0, 0, 0.5)"`。
3. `ThemeStore.swift:404-411` 把 `shadow` 放入 `ThemePalette`。
4. `LyricsWebViewStore.swift:1192-1217` 的 `applyEffectiveTheme()` 把 `palette.shadow` 作为 `shadowColor` 写入配置。
5. `LyricsWebViewStore.swift:1225-1235` 同时把它写进 CSS 变量 `--amll-shadow`。
6. `index.html:5226-5233` 收到 `shadowColor` 后，在 `lyricPlayer.getElement()` 上设置 `textShadow = "0 1px 2px <shadowColor>"`。

这解释了用户观察到的现象：

- 浅色模式：文字接近黑色，黑色阴影在亮背景上明显。
- 深色模式：阴影仍可能存在，但融入深色背景，不容易被看见。
- 这个现象与白色 emphasis glow 不是同一件事。

需要注意一个细节：`LyricsViewModel.swift:363-365` 在常规 config 中给 `shadowColor` 的默认值是透明黑色。但主题应用路径 `LyricsWebViewStore.applyTheme()` 后会下发真实 `palette.shadow`。所以诊断静态阴影时，应看 theme patch 后的最终值，而不是只看初始 config。

### 动态白色 glow 的来源

动态白色 glow 来自 AMLL core：

- fork 源码：`packages/core/src/lyric-player/dom/lyric-line.ts:813-827`
- 运行 bundle 中对应逻辑来自生成的 `amll-core.js`，但不要手改生成 bundle。

它是 `emphasize-word-*` WAAPI 动画的一部分。这个动画还包含 transform，所以不能简单把它等同于装饰阴影。

更准确的说法是：

- 深色模式中，白色文字 + 白色 glow 更容易让人看到“发光”。
- 浅色模式中，用户指出的黑色下投影主要不是它，而是静态根级阴影。

## 6. Safari 实验场为何可能更顺

Safari 和 App 内嵌 `WKWebView` 都使用 WebKit，但宿主环境不同。

Safari 更接近“浏览器直接渲染一整页 Web 内容”。App 里的窗口歌词是另一种路径：

- WebView 背景透明；
- WebView 嵌在 SwiftUI/AppKit 层级中；
- 它和 Home、歌词面板背景、窗口 chrome 一起参与原生窗口合成；
- 窗口 main 还保留 `mix-blend-mode: plus-lighter`。见 `index.html:23-27` 和 `style.css:1-8`。

所以，“同样内核”不代表“相同性能表现”。

GPU 数字也不能直接等同于流畅度：

- GPU 占用高，不一定更卡。它可能说明 GPU 被充分利用，管线比较顺。
- GPU 占用低，也不一定更轻。如果 CPU、IPC、WebContent 进程、AppKit/SwiftUI 合成或调度链路堵住，GPU 可能反而吃不满，但画面仍然掉帧。

这能解释“Safari GPU 更高但更顺，App 内 GPU 不一定更高但更卡”的观察。它不是矛盾，而是说明瓶颈可能不只在 GPU shader 或像素填充。

## 7. 当前最可信的性能嫌疑排序

下面是基于当前代码证据的排序。这里的“置信度”表示它是否值得优先测，不表示已经被量化证明。

| 排名 | 嫌疑因素 | 置信度 | 依据 |
|---|---|---|---|
| 1 | 歌词 WebView 持续动画，一直占用窗口帧预算 | 高 | RAF 循环见 `index.html:5382-5384`；播放状态通过 `index.html:4948-4958` resume/pause |
| 2 | 透明 `WKWebView` 嵌入复杂原生窗口层级，可能增加合成成本 | 高 | 透明背景见 `index.html:9-20`、`LyricsWebViewStore.swift:1540-1541`；宿主路径见 `AMLLWebView.swift:45-72`、`AMLLWebView.swift:221-268`、`AMLLWebView.swift:323-386` |
| 3 | 窗口模式静态根级 `text-shadow` | 中高 | 主题链路见 `ThemeStore.swift:394-411`、`LyricsWebViewStore.swift:1212-1217`、`index.html:5226-5233` |
| 4 | 窗口模式 upstream WAAPI emphasis `textShadow` glow | 中高 | fork `lyric-line.ts:813-827`；窗口模式没有 fullscreen suppress |
| 5 | 窗口 main 保留 `mix-blend-mode: plus-lighter` | 中高 | `index.html:23-27`、`style.css:1-8`；普通 fullscreen 在 `index.html:469-481` 改为 normal/none |
| 6 | 背景行 blur/filter 与 CSS transition | 中 | `LyricsSurfaceRole.swift:79-86` 对 `.main` 启用 blur；AMLL CSS 中背景行 transition/filter 路径存在 |
| 7 | 逐字符/逐词 `will-change: transform` 和 `backface-visibility` 导致 layer 数增加 | 中 | `style.css:32-39`、`style.css:150-167` |
| 8 | 封面模糊全屏双 WebView 架构 | 高，但只影响 cover-blur fullscreen | `LyricsSurfaceRole.swift:23-24`、`FullscreenPlayerView.swift:943-960`、`FullscreenPlayerView.swift:3012-3034` |
| 9 | Swift -> JS 时间桥接吞吐量 | 低 | 约 4 Hz presentation tick、10 ms 去重、in-flight gate，见 `PlaybackCoordinator.swift:420-423`、`LyricsWebViewStore.swift:542-554`、`LyricsWebViewStore.swift:1637-1675` |

这次排序刻意不把 “glass material” 单独放在第一位。它仍是窗口背景的一部分，代码位置是 `LyricsPanelView.swift:130-156`，但目前没有直接证据证明它是关键瓶颈。

## 8. 建议的下一步 A/B 与运行时测量

优先目标是拆开“Web 内容成本”和“原生透明合成成本”。不要先调参数，也不要根据肉眼感觉直接改默认值。

### A/B 1：关掉窗口静态根级 text-shadow

目的：验证浅色模式黑影和一部分额外绘制成本是否来自静态阴影。

临时在 Web Inspector 中执行：

```js
const el = document.querySelector(".amll-lyric-player");
if (el) el.style.textShadow = "none";
```

观察：

- 浅色模式黑影是否立即消失；
- Home 滚动是否有可感知改善；
- GPU / Core Animation 时间是否下降。

### A/B 2：关掉窗口 emphasis textShadow glow

目的：单独验证动态白色 halo 的影响。

可用 DevTools 临时拦截或覆盖 emphasis 相关 `text-shadow`。如果走 CSS 覆盖，需确认实际命中的 class 名，因为当前 CSS module 类名会变化。

观察重点：

- 深色模式 glow 是否明显减弱；
- 行切换或强调词 sweep 时是否少掉帧；
- 这项不应再被用来解释浅色黑色下投影。

### A/B 3：把窗口 main 的 `mix-blend-mode` 改成 `normal`

目的：验证 additive blending 对合成路径和 GPU 成本的影响。

临时执行：

```js
const el = document.querySelector(".amll-lyric-player");
if (el) {
  el.style.setProperty("mix-blend-mode", "normal", "important");
  document.documentElement.style.setProperty("--amll-lp-mix-blend-mode", "normal");
}
```

观察：

- 歌词视觉是否可接受；
- Home 滚动和窗口 resize 是否改善；
- Instruments 里合成相关时间是否下降。

### A/B 4：关掉窗口歌词 blur/filter

目的：验证背景行 blur/filter 是否是局部热点。

只在临时测试中把 main surface 的 `enableBlur` 设为 false，或用 DevTools 覆盖相关背景行 filter。不要直接改默认产品行为。

观察：

- 背景行切换时是否更稳；
- Home 滚动是否变化明显。

### A/B 5：拆分透明合成与 glass

目的：验证“透明 WebView + 原生窗口合成路径”是否比 Web 内容本身更关键。

建议做两组：

1. 让 WebView 临时变成不透明背景。  
   这需要小范围本地实验，不建议直接提交。

2. 保持 WebView 透明，但把面板背景临时换成纯色或无材质。  
   这个实验只用于验证，不应直接得出“glass 是主因”的结论。只有当这组差异非常大，并且 Web 内容项已经排除后，才能提高 glass 相关判断的置信度。

### Instruments 建议

优先看这些：

- **Core Animation**：比较歌词面板开/关、静态阴影开/关、blend 开/关时的 frame time。
- **Time Profiler**：确认主线程、WebContent 进程、IPC 和 SwiftUI/AppKit 合成是否有明显等待或热点。
- **Metal System Trace**：看 GPU 是否真的满载，还是前面的 CPU/合成/调度链路导致 GPU 空闲。
- **WKWebView / Web Inspector Performance**：确认 RAF、WAAPI、style/layout/paint 的比例。

## 9. 当前文档结论边界

已经可以确认：

- 窗口歌词 WebView 是透明的。
- 窗口歌词播放时有持续 Web 动画。
- Swift -> JS 时间更新频率不是主瓶颈。
- 浅色窗口歌词暗影来自静态根级 `text-shadow`，不是白色 emphasis glow。
- 窗口 main 保留 `mix-blend-mode: plus-lighter`。
- 普通全屏和封面模糊全屏都有自己的 suppress / glow layer 路径，不应和窗口 main 混为一谈。
- 封面模糊全屏可以启用 base/highlight 双 WebView 架构。

高可信但仍需测量量化：

- 持续动画 WebView 与 Home 争夺帧预算，是歌词面板打开后 Home 降流畅度的主要方向。
- 透明 WebView 的原生合成路径可能放大 Web 内容成本。
- 静态 text-shadow、WAAPI textShadow、plus-lighter、blur/filter 都可能贡献不同程度的额外成本。

不再作为当前定论：

- “Liquid Glass 背景本身是最大性能瓶颈。”
- “浅色模式黑色暗影来自 upstream 白色 emphasis halo。”
- “GPU 占用更低说明路径更轻。”

后续如果要把某一项升级为确定结论，应先做 A/B，并把测试条件、截图或 Instruments trace 结果补回本文。
