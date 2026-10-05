# 原生皮肤开发

P3 提供两条入口：用 JSON 组合 App 已提供的组件，或编写 SwiftUI 场景/组件并编译入 App。两者使用相同的组件目录和场景宿主。外部 HTML/CSS/JavaScript 的运行时在 P5 接入。

## 先做一个可导入的包

皮肤是普通 ZIP，根目录放 `manifest.json`，可附图片、README 和 LICENSE。当前原生版本为 `formatVersion: 1`、`hostAPIVersion: 1`（旧包省略后者时按 1 解析），场景与参数先写在 manifest 中；后续文件拆分通过版本演进处理。

```text
my-skin.zip
├── manifest.json
├── assets/
│   └── decoration.png
├── README.md
└── LICENSE
```

组合定义的基本结构如下；正式皮肤还应提供下文的必要操作。`descriptor` 必需字段只有 `id`、`name`，默认同时支持普通播放页和全屏。`version` 是作者版本；组件类型是 App 已登记的身份。

```json
{
  "formatVersion": 1,
  "version": "1.0.0",
  "descriptor": { "id": "my.reading", "name": "Reading" },
  "scene": {
    "root": {
      "id": "reading",
      "type": "column",
      "spacing": 16,
      "layout": { "padding": 24, "fillsWidth": true, "fillsHeight": true },
      "children": [
        { "id": "title", "type": "component", "component": "native.trackInfo" },
        {
          "id": "lyrics", "type": "component", "component": "native.lyrics",
          "layout": { "fillsWidth": true, "fillsHeight": true }
        },
        { "id": "controls", "type": "component", "component": "native.transport" }
      ]
    }
  }
}
```

三个完整示例位于：

- [歌词主导](examples/skins/lyrics/manifest.json)
- [封面主导](examples/skins/artwork/manifest.json)
- [上下布局与宽窄分支](examples/skins/vertical/manifest.json)

从仓库根目录打包，例如：

```sh
/usr/bin/ditto -c -k docs/examples/skins/vertical /tmp/vertical-skin.zip
```

在既有皮肤设置点击“导入”，包加入列表，由用户选择。安装内容由 App 保存，之后移动源 ZIP 不影响素材路径。普通与全屏沿用原来的独立选择。

内置皮肤的导出按钮置灰，原件始终留在 App 中。第三方包若引用内置身份，导入时生成副本；同 ID 用户包提供替换和另存副本。空白处右键可刷新当前场景或恢复外观；设置内“重载”重新读取已安装包并重建使用它的场景；“删除”移除用户包，正在使用它的普通/全屏选择分别切回默认内置皮肤，播放、时间和队列继续运行。市场与开发目录监听属于后续阶段。

## 场景节点与自适应

节点使用 `id` 和 `type`。同一个容器的子节点 ID 应互不重复，宽窄分支可使用相同语义的 ID。

| type | 内容 |
| --- | --- |
| `component` | `component` 类型名，可有 `values` 与 `bindings` |
| `row` / `column` | `children` 数组、可选 `spacing` |
| `overlay` | `children` 数组，后面的元素默认在前面；可用层级与锚点 |
| `adaptive` | `minimumWidth`、可选 `minimumHeight`（默认 0）、`wide` 与 `compact` 两个完整节点；可用宽高同时满足阈值时选 `wide`，否则选 `compact`；可嵌套 |
| `spacer` | 弹性空白 |

`layout` 可省略；尺寸单位为 macOS 逻辑点。支持：

- `width`、`height`，`minimumWidth`、`minimumHeight`，`maximumWidth`、`maximumHeight`。
- `fillsWidth`、`fillsHeight`，`aspectRatio`，`padding`。
- `alignment`：`topLeading`、`top`、`topTrailing`、`leading`、`center`、`trailing`、`bottomLeading`、`bottom`、`bottomTrailing`。
- `zIndex`、`offsetX`、`offsetY`、`rotationDegrees`、`opacity`、`allowsHitTesting`。

这些属性作用于原生布局和当前节点。优先用弹性区域、尺寸上限、宽窄分支和锚点，少依赖固定偏移；普通用户不调整位置与断点。歌词在真实区域按实际尺寸排版，整幅画面的缩放不作为场景适配方法。

JSON 是轻量组合树，复杂原生布局可直接用 SwiftUI `Layout`、`ViewThatFits` 或自己的响应式视图。无需继续扩充宿主协议来表达每个皮肤的几何规则。

## 当前组件

| 类型 | 用途与配置 |
| --- | --- |
| `native.artwork` | 原尺寸封面；`cornerRadius`、`artisticEdge`、`blur`、`fit`（fit/fill）、`opacity`；可放多个 |
| `native.background` | `mode`：solid、gradient、artwork、preset；`blur`、`preset`、RGB；空白右键菜单 |
| `native.trackInfo` | 标题与艺人；`fontSize`、`artistFontSize`、`alignment`（leading/center）、颜色 |
| `native.text` | `text`、`fontSize`、颜色；缺少文字时使用歌名 |
| `native.image` | `path` 指向包内相对路径，如 `assets/decoration.png` |
| `native.lyrics` | 唯一原生实例；字体、混合、特性、对齐、边缘淡出，见下方配置 |
| `native.transport` | 上一首、播放/暂停、下一首；颜色、`spacing` |
| `native.progress` | 拖动进度；仅该叶节点读取实时展示 |
| `native.volume` | 现有音量滑块与来源可用状态 |
| `native.like` / `native.queue` | 本地歌曲喜欢、播放队列；按播放来源启用 |
| `native.playbackMode` | 复用原播放顺序滑块，适配本地与外部来源；`expanded`、`scale`、颜色；默认采用原生控件尺寸，可用组件参数 `width`、`height` 覆盖 |
| `native.miniPlayer` | 中间播放器、左按钮胶囊、右音量胶囊始终成组；`scale` 为尺寸上限，按实际区域适配 |
| `native.actionsCapsule` / `native.volumeCapsule` | 左、右胶囊可独立摆放；`scale`；左侧可用 `showsLyricsButton` 隐藏歌词按钮 |
| `native.playPause` / `native.previous` / `native.next` | 单个官方播放按钮；`fontSize`、颜色 |
| `native.lyricsToggle` / `native.fullscreen` / `native.settings` / `native.quickPanel` | 独立入口；全屏按钮按宿主进入或退出 |
| `native.spectrum` | 共享频谱；`count`、颜色；宽高由组件区域决定 |
| `native.led` | 共享 LED；`dotSize`、`spacing` |
| `native.waveform` | 真实 PCM 窗口绘制；`gain`、`lineWidth`、颜色；外部来源无真实 PCM |
| `builtin.<id>.artwork` | 内置皮肤的完整封面效果，包含原效果已内聚的可视化 |
| `builtin.<id>.background` / `.overlay` | 内置背景和额外装饰 |

内置 ID 是 `coverLed`、`appleStyle`、`rotatingCover`、`kmgccc.cassette`、`fullscreen.coverGradientBlur`。例如 `builtin.kmgccc.cassette.artwork` 可以与自选歌词和控制栏组合。全屏预设部件保留设计画布，`canvasWidth` / `canvasHeight` 可指定局部参考画布。

`values` 支持普通 JSON 值，包括数组和对象，含义由组件解释；宿主不读取某个具体效果的参数。颜色基础覆盖使用 `red`、`green`、`blue`（0–1 的 Display P3 数值）和可选 `opacity`。原生歌词的颜色可使用现有 CSS 字符串或色彩对象映射，例如 `fullscreenActiveColor`；减少动态效果优先于作者开启的弹性动画。

一个可见场景最多一个 `native.lyrics`。宽窄分支各声明一个属于同一实例的不同挂载容器；多个封面、图形和可视化继续允许。注册自定义原生组件时同样遵守歌词唯一实例与共享分析服务的归属。

## 少量用户参数

用户参数声明在 `parameters`，仅 `isUserVisible: true` 且支持当前显示模式的定义显示在“{skinName} 选项”区。布局参数留在作者文件里。

```json
{
  "parameters": [
    {
      "id": "decorationOpacity",
      "title": "装饰",
      "defaultValue": 0.6,
      "control": { "type": "range", "min": 0, "max": 1, "step": 0.1 },
      "isUserVisible": true
    }
  ]
}
```

把同一参数绑定给多个组件，实现一个设置联动多处呈现：

```json
{
  "id": "decoration",
  "type": "component",
  "component": "native.text",
  "values": { "text": "♪", "red": 0.4, "green": 0.6, "blue": 0.8 },
  "bindings": { "opacity": "decorationOpacity" }
}
```

参数控件还支持 `{"type":"toggle"}` 和 `{"type":"choice","choices":[{"id":"calm","title":"沉静"}]}`。它们分别对应布尔值和选项 ID 字符串。复杂联动由组件或 Swift 场景解释同一个用户值；不把所有派生值暴露给用户。参数按皮肤 ID 与普通/全屏模式分别保存。替换和重载保留相同 ID、类型兼容的值；新范围收窄时限到范围内，选项被移除或类型变化时采用作者的新默认值。跨模式共享与多版本回退另行演进。

## 新增 Swift 原生场景或组件

场景只需稳定快照、实际视口与组件工厂。可省略任意已有组件，也可以使用任意 SwiftUI 布局；旧背景、封面工厂已有默认实现。

```swift
struct ReadingSkin: NowPlayingSkin {
    var descriptor: SkinDescriptor {
        .init(id: "example.readingNative", name: "Reading Native",
              detail: "", systemImage: "text.alignleft")
    }

    var scene: SkinScene? {
        SkinScene { _, viewport, components in
            VStack(spacing: 16) {
                if viewport.size.width >= 720 {
                    components.component("native.artwork")
                        .frame(maxHeight: 240)
                }
                components.component("native.lyrics")
                components.component("native.transport")
            }
            .padding(24)
        }
    }
}
```

在组合根的 catalog 注册 `catalog.registerBundled(ReadingSkin())`。若需要新效果，先 `catalog.components.register("example.effect", isInteractive: false) { snapshot, configuration in ... }`，再从 Swift 场景或 JSON 节点调用。这样不必改普通/全屏宿主的皮肤判断。

内置模块保留包的登记形式，导出入口禁用。第三方包可以引用当前可用部件并携带自己的常见格式素材；任意新 Swift 实现仍须编译入 App，ZIP 当前不能加载外部原生可执行代码。五个内置模块保留旧设置适配，部件内部进一步拆分和设置的逐项迁移按需要继续推进。

组件通过环境获取 `skinSceneActions`，动作进入既有播放、队列和喜欢服务；通过 `skinPackageResources` 获取资源目录，通过 `skinSceneIsActive` 停止隐藏时的活跃工作。动画使用现有 motion tokens/policy。退出、恢复与全局快捷键由 App 保留。不要另建播放器、歌词 owner 或 audio tap，也不要把时钟与每帧分析塞进稳定快照。

## 当前边界

包格式尚处于原生 v1 演进期；公开 [JSON Schema](skin-package-v1.schema.json) 覆盖当前词汇。App 另检查组件是否存在、单个原生歌词、同级节点/参数 ID 唯一、参数范围与默认值类型。Debug 构建、主 App 启动已通过；当前 UI 操作工具断连，导入面板、样例视觉和全屏/频繁缩放需人工确认，见 [实施记录](skin-system-p3.md)。目录监听热重载、Web 桥接、Folia/Folium 兼容与市场均在后续阶段。


## 原生歌词配置

宽度由布局或 `maximumWidth` 指定。`mixBlendMode`、`blendOpacity` 和现有逐通道混合映射沿用 MelismaKit 适配。字体使用 `fontSize`、`fontFamilyLatin`、`fontFamilyCJK`、`translationFontSize`；对齐使用 `alignPosition`、`alignOffset`、`alignAnchor`。

特性包括 `showTranslation`、`showRomanization`、`showRuby`、`enableSpring`、`enableBlur`、`enableScale`、`enableGlow`、`enableEmphasis`、`hidePassedLines`、`lineTimingOnly`、`preserveCompletedHighlight`。减少动态效果偏好会覆盖作者的弹性动画开关。

`topEdgeOpacity` / `bottomEdgeOpacity` 控制上下边缘的透明度；`topFadeRange` / `bottomFadeRange` 控制羽化范围，使用组件高度的比例（0–0.5）。例如两个边缘透明度为 0、范围为 0.12，表示上下各 12% 高度渐隐。默认范围为 0、边缘不透明，作者主动选择淡出。

## 自绘数据与操作

原生 Swift 作者不必使用官方组件。`snapshot.track` 提供原尺寸 `artworkImage`、封面 `artworkData` 与 `artworkFileURL`，可自行绘制；`SkinPlaybackReader` 在叶视图中提供完整 `NowPlayingPresentation`（时间、时长、播放来源、音量、可用操作等）。实时数据不进入场景根快照。

```swift
SkinAudioReader { audio in
    Canvas { context, size in
        // audio.frame?.pcmSamples: 原始、未加窗的最新单声道分析窗口
        // audio.frame?.magnitudes: 完整 FFT 功率数组，不是 LED 归一化值
        // 同时提供 sampleRate、fftSize、hostTime、RMS 和 peak
        // 使用这些值画自己的波形、频谱或粒子效果。
    }
}
```

PCM 是共享音频 Hub 的最新 2048 个采样点，30 Hz 分析帧可能重叠；它适合绘图，不是无损录音流。读取组件出现时取得共享分析会话，隐藏或退出时释放。外部播放器无法提供真实 PCM/FFT，`availability` 明确为 `externalAudioUnavailable`；官方频谱沿用现有模拟器，不把模拟数据冒充原始音频。

`SkinLyricsReader` 提供原始 `LyricsDocument`、完整 TTML、词/行/翻译/罗马音、时间戳与当前歌词时钟。`rawDocumentTime` 已计入当前配置的歌词偏移；`revision` 表示歌词/配置更新，可用于作者的布局缓存；`timedGroups` 在已有 native 文档与当前输入及配置匹配时提供预处理后的时间范围，否则为 nil。即使场景不使用 `native.lyrics`，仍可取得歌词文档，不需挂载或启动第二个歌词渲染器。

组件中的 `@Environment(\.skinSceneActions)` 提供播放/切歌、seek、音量、本地和外部播放顺序、喜欢、队列、歌词开关、进入/退出全屏、设置、Quick Panel、刷新和恢复。自绘歌词可读 `skinSceneLyricsVisible` 响应开关。官方组件之外的交互区域加 `.skinControlRegion()`，让原生歌词把这些区域的点击交还给 SwiftUI；位置按实际布局测量，支持遮叠和窗口缩放。

左右胶囊默认收起，hover 带原有动画展开；鼠标离开延迟收起，音量拖动结束后再收起。整组与独立调用均遵守同一规则，每个实例的 hover 状态独立。

全屏宿主使用完整窗口的坐标与点击区域，作者无需移动顶部控件来避开标题栏。官方组件已声明交互矩形，普通 SwiftUI/AppKit 控件也通过可访问性命中识别；自绘点击区域应使用 `.skinControlRegion()`，与原生歌词的遮挡规则共用。顶部没有交互控件的空白仍可拖动窗口，系统全屏沿用系统行为。

Vertical Scene 展示宽度与高度分支的嵌套：宽度低于 720 点时收起封面，宽度足够但高度低于 700 点时使用 112 点封面，高度充足时使用 204 点封面。歌词获得剩余空间，文字与原生控件按逻辑点重新排版。

完整 Mini Player 推荐优先使用。目录不提供中间大胶囊的独立身份；左右小胶囊、细分控件仍可自由组合。App 根据操作声明，在全屏场景补充缺少的退出、歌词和 Quick Panel 入口，恢复放在右键菜单中。普通用户继续只看到皮肤列表与作者声明的少量选项。

三个示例采用不同搭配：Artwork Scene 使用完整播放器；Lyrics Scene 使用独立左右胶囊和播放按钮；Vertical Scene 使用播放顺序、按钮、音量条及进度。三个示例的歌词均启用上下边缘淡出。

## 必要操作与作者自由

每个可用布局（包括所有宽高分支）应提供播放/暂停、上一首、下一首、进度、来源支持时的音量、歌词开关和全屏入口；全屏布局应提供退出和 Quick Panel。来源不支持的操作按现有可用状态禁用。作者可以自绘按钮、菜单或其他清楚可达的交互，调用 `skinSceneActions`，无需采用官方控件的形状、位置或排列。恢复外观保留在空白右键菜单，全局快捷键由 App 管理。

完整 `native.miniPlayer` 始终包含左右胶囊；不提供中间胶囊的独立身份。独立调用 `native.actionsCapsule` / `native.volumeCapsule` 时，同一有效布局中应成对出现；它们可以分别定位。完全自绘播放控件不要求使用胶囊。必要操作和胶囊配对属于作者交付约束，导入服务不按一份固定组件名单封锁自绘实现。

官方按钮会声明已提供的操作。自绘入口可在场景内容上声明：

```swift
customControls
    .skinControlRegion()
    .skinProvidesControls([.playPause, .previous, .next, .lyricsToggle, .fullscreen, .quickPanel])
```

`.fullscreen` 在普通场景表示进入全屏，在全屏场景表示退出。声明应与当前可见且可操作的控件一致；可把声明附在不同按钮上，宿主合并它们。全屏宿主只补充缺失的退出、歌词开关和 Quick Panel，不重复添加已有自绘入口。播放、进度与音量的完整性由作者按上述约束交付。

注册组件时用 `isInteractive: true` 声明整个组件区域属于控件；装饰、封面、背景和自绘可视化默认不声明整块点击区域，混合组件只在局部控件上使用 `.skinControlRegion()`。这决定原生歌词的遮挡命中和顶部窗口拖动，新增类型无需修改宿主白名单。

同 ID 替换和设置内重载会发布新的运行 revision，所有使用该皮肤的宿主取消旧会话工作并重建皮肤内容；隐藏的普通场景不抢占歌词视图。重载失败显示具体错误并保留已登记实例，完整新包准备成功前不删除旧安装。原生视图的暂态状态随重新挂载重置，播放服务和歌词时钟继续运行。P6 的开发目录监听与 P9 的在线更新复用此入口。

自绘组件可从 `skinSceneSession` 登记 `registerCleanup { ... }`，只释放自己的任务、纹理或共享服务 lease；离开组件时用 `removeCleanup` 解除登记并完成局部释放。切换/重载/退出会话统一调用仍登记的释放动作。`SkinAudioReader` 已采用此方式，作者不需自行创建 audio tap。
