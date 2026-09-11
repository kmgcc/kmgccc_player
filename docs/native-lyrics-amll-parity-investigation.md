# Native Lyrics / AMLL Parity Investigation

2026-09-06 的状态与交互修正见 [Native behavior regressions](../Tools/NativeLyrics/BEHAVIOR-REGRESSIONS.md)：更新模糊生命周期、从上到下的点击级联、无弹簧 scrub、空格与异常词时间、高亮退出、收敛的 resize reflow、中心锚点间奏点和公开 motion/channelBlend 接口。原生 gap anticipation 与稳定 BG reveal 是明确的产品差异，不能等同于逐项复制 upstream。

调查日期：2026-09-05。范围：可复用 macOS 原生歌词引擎及独立 Demo；不改变正式播放器现有渲染路径。本文件先于原生实现建立，作为实现和验收的规格。完成度和实测结果见 Demo 的 `VALIDATION.md`，不能从本文的设计目标推断已经达到 90%。

## 1. 源码基准与可复现性

| 基准 | 固定提交 | 用途 |
|---|---|---|
| 播放器调查起点 | `e097e93fe03b2217aa5b52168225a1d0eaec1947` | Swift owner、bridge、产品适配层 |
| 当前 submodule / 产品 fork | `91939107e9ec338c20c5a6a672e4d894868ecf2f` | 正式播放器目前使用的 core/parser |
| fork 最近合入的官方基线 | `243112b90890af708153f4c2a1ef1ba060c442b5` | 分离 fork 自定义净改动 |
| 调查日官方 main | `58ccd3ffae7ec4e9a6d1cdb0dd88ac8c767f68a8` | 最新官方行为，GitHub API 及独立 checkout 双重确认 |

官方与 fork 已经有显著差异，不能把两者称为同一版本。fork 相对合入基线净改动为 **20 个文件，863 insertions / 28 deletions**。官方从同一基线到调查日版本，仅 `core/src` 和 `ttml/src` 就有 42 个变更文件、5493 insertions / 2108 deletions；其 timeline/focus/scroll 已重构，TTML parser 在此区间没有源码差异。

源码缩写（均指上述固定提交，不指可变的 main）：

- **F**：[产品 fork](https://github.com/kmgcc/applemusic-like-lyrics-kmgcccplayer-integration/tree/91939107e9ec338c20c5a6a672e4d894868ecf2f)，本地 `Dependencies/Submodules/AMLLIntegration`。
- **U**：[当前官方](https://github.com/amll-dev/applemusic-like-lyrics/tree/58ccd3ffae7ec4e9a6d1cdb0dd88ac8c767f68a8)。
- **B**：[合入基线](https://github.com/amll-dev/applemusic-like-lyrics/tree/243112b90890af708153f4c2a1ef1ba060c442b5)。
- **A**：本播放器的 `kmgccc_player/Resources/AMLL/index.html`、`bridge.js` 及以下 Swift 文件。

复查命令：`git submodule status`；fork 中 `git merge-base HEAD upstream/main`（remote ref 可能变动，应用固定 B 核对）；`git diff --stat 243112b 9193910`；独立官方 checkout 中 `git diff 243112b 58ccd3f -- packages/core/src packages/ttml/src`。不要为了调查移动生产 submodule pin 或运行同步脚本。

## 2. 当前播放器的真实输入和生命周期

```text
PlaybackCoordinator.presentation / NowPlayingPresentation
  → LyricsPlaybackPipeline
  → LyricsViewModel (本地/外部来源、TTML、时间配置)
  → LyricsSurfaceManager (跨 surface snapshot / generation / role)
  → LyricsWebViewStore (持有 WKWebView、ready、queue、recovery)
  → bridge.js → window.LyricsRenderer / window.AMLL
  → index.html (解析、产品 timing、颜色、overlay、RAF)
  → DOM LyricPlayer → group → main/BG line → words/characters/masks
```

- `LyricsPlaybackPipeline.start/applyPresentation/syncPlaybackState` 从稳定的 presentation owner 取数据；进度差至少 0.01 秒才下发，播放态使用 effective lyrics state。面板可见性不是歌曲内容的第二来源。
- `LyricsSurfaceManager` 保存 track ID、TTML/hash、time、playing、每个 role 的 config 和主题快照。切换有 `targetMode/currentMode/switchGeneration` 和 preparing/awaitingReady/active 状态；过期回调不应重放旧曲。
- roles：main、fullscreen、batchPreview、standalone；`fullscreenCoverBlurHighlight` 是保留辅助 role，当前生产未启用第二层 WebView。系统全屏、窗口模拟全屏、主窗口内嵌是三个宿主入口。
- `LyricsWebViewStore` 处理 attachment identity、ready 前调用、page token、恢复和 replay。`handleOnReady` 先检查 token，再由 manager 或 store 之一重放 snapshot；不是两边都重放。新歌词要在最终 config 之后一次性装载。
- 普通切歌 `applyTrackState` 原子投递 TTML/time/playing。A `setLyrics` 先 parse 新内容，再 replace，禁止先 clear 成空白；renderer health diagnostics 只有限重放。
- 真正新歌词/新 surface：`setLyricLines(lines, initialTime)` → `setCurrentTime(..., true)` → `calcLayout(true)` → group 的 Y 从窗口高度两倍处 spring 入场。
- 已有歌词隐藏后显示：`revealExistingLyrics` 保留对象，通过公开 setCurrentTime + calcLayout 更新目标。持久 main/fullscreen 隐藏只暂停；真正切换/teardown 才释放。inactive role teardown grace 为 0.25 秒。
- A 的 RAF 从 `externalTimeMs + performance.now() - externalTimeAnchorPerfMs` 外推播放时间；暂停不推进媒体时间，仍允许 1500ms 的视觉 settle。seek/resize/config/reveal 会 wake。
- A 将相差超过 500ms 的时间更新判为 seek。暂停窗口模式对小于等于 500ms 的更新存在忽略路径；这是当前产品行为，原生 API 不应隐式继承这种桥接限制。
- render quality 在 Swift 通过 WebView frame、pageZoom、逆 layer scale 实现；不是 core renderScale。原生用 backing scale/缓存质量，鼠标坐标始终以 point 为准。

关键源码：`Services/Lyrics/LyricsPlaybackPipeline.swift:41–132`、`LyricsSurfaceManager.swift:17–92,574–597`、`LyricsWebViewStore.swift:902–921,1251–1311`；A `index.html:6482–6663,7245–7303`。行号会随后续维护变化，符号名是第二定位依据。

## 3. 产品时间适配：数据时间不等于视觉时间

Swift 设置：单曲偏移默认 0、范围 ±15000ms；全局 advance 默认 0，与外部 overlay 合并后 ±5000ms；lead-in 默认 600ms，near gap 默认 160ms。A bootstrap lead-in 为 300，最终应以 Swift 下发为准。Swift combinedOffset 为 `trackOffset - globalAdvance`（±20000），A 实际又 clamp 至 ±15000，不能仅按维护说明假设最大范围。

处理顺序（A `setLyrics`, `applyAppTimingPreprocessing:2065`）：

1. TTML parser → AMLL lines；先保存点击目标 `max(0, originalStart + trackOffset)`。
2. 将视觉 offset 应用于 line/word/ruby；逐行模式归一化。
3. 规范空白、按词重置 line 时间、处理多 BG、同步 main/BG、清理微重叠。
4. 保存 raw snapshot，反向计算提前起点。**延后统一裁剪前一行 end**，不能在反向遍历中立即裁剪。
5. core 装载。避免再应用另一遍 core 默认提前优化。

源码的实际 advance 规则：near-switch 使用 leadIn；其他情况（包括真实重叠）使用 1000ms。存在原始重叠或 near-switch 时允许直接提前，普通间隔不得早于上一主行 end。旧说明中“重叠使用 leadIn”的简述不能覆盖这条源码事实。

行首前两个有效词的提前量：near 为 `min(applied, leadIn,260)`，其他为 `min(applied,180,leadIn*0.6)`；再受行首剩余空间限制。通过首段时间进度线性衰减提前量，保持第二个词尾不动。不是统一移动两个词，更不是移动整行所有词。

微重叠清理：overlap 必须同时 >100ms 且 >下一行时长 10% 才保留。注意其输入是 reset/sync 后时间，不能宣称所有作者微重叠都被无损保留。报告必须区别作者原始表达、兼容优化、视觉提前和点击时间。

原生保留不可变 `sourceRange` 与派生 `presentationRange`；点击只返回 `sourceStart + seekTimeOffset`，不把 global visual advance 再叠加一次。`LyricsTimingConfiguration.trackOffset`/`globalAdvance` 只影响 presentation，`seekOffset` 对应 APP 的 `seekTimeOffsetMs`。产品 timing 是可选择 policy，标准 TTML parser 本身不提前歌词。LRC、ESLyric、QRC 等转换继续留给外部层。

## 4. fork 全部净差异登记

下表按 B → F 的完整文件清单，不用 commit 标题代替净差异。

| 文件（相对 fork） | 净改动及原生含义 |
|---|---|
| `.gitignore` | 忽略两个专用构建目录；无运行行为 |
| `core/src/lyric-player/base/consts.ts` | WordHighlightMode smooth/discrete |
| `base/group.ts` | group.posY 与 main.lineTransforms.posY 共享；disable 透传 isSeek |
| `base/index.ts` | 模式 getter/setter、disable 的 seek 因果信息 |
| `base/layout.ts` | 间奏 start 固定 gapStart，修复每次 layout 重启动画 |
| `base/line.ts` | line 层增加兼容 posY；disable 接受 isSeek |
| `dom/index.ts` | 改模式时重建所有 line 的 mask |
| `dom/interlude-dots.ts` | 同 end 的间奏不重启；保留 global×walk opacity，额外暴露独立 global/walk 给宿主 |
| `dom/lyric-line.ts` | seek-aware exit catch-up、discrete opacity、所有 float exit 回落、glow radius CSS 参数；详见动画表 |
| `core/src/myplayer-app.ts` | 普通 DOM-only core export |
| `core/src/myplayer-background.ts` | 独立背景 renderer wrapper；不是歌词布局职责 |
| `core/src/utils/lyric-split-words.ts` | 连续 CJK run 通过 Intl.Segmenter 合成语义 chunk；ruby 不参与合并；fallback 为旧行为 |
| `core/tsdown.myplayer.config.ts` | browser ESM bundle、raw-query shader loader、production define、全量打包依赖 |
| `core/tsdown.myplayer-background.config.ts` | 同上但独立 background entry/outDir |
| `lyric/src/myplayer-app.ts` | 优先中文翻译；upstream parser 结果为空时尝试 legacy plain TTML；保留其他格式 export |
| `lyric/tsdown.myplayer.config.ts` | 独立 parser ESM |
| `react-full/package.json` | 增加 @babel/core devDependency |
| `react-full/tsdown.config.ts` | jotai Babel 插件改显式 import |
| `pnpm-lock.yaml` | 对应 catalog/importer 依赖记录 |
| `pnpm-workspace.yaml` | @babel/core catalog |

上表省略了每行公共前缀 `packages/`，其中 base/dom 相对 `packages/core/src/lyric-player/`。完整 diff 可从固定 F/B 重建。无须移植背景 mesh、React 构建修复或 legacy 格式 fallback 到原生歌词内核。

产品 adapter 另有：window/fullscreen/CoverBlur/AppleStyle semantic colors、P3/sRGB、plus-lighter/plus-darker、background vocal 独立 tint、completed parallel highlight、per-character emphasized base/active stack、CSS/WAAPI clone、mouse wheel bridge、滚动期间隐藏 dots（220ms debounce）、emphasis retint、隐藏/重显和 renderer gating。这些并非 fork diff；正式接入时必须按 skin 逐个验收。特别是 emphasized word 的 base/active 必须同字同浮，不能添加静止词级 base clone。

## 5. 完整行为矩阵

| 领域 | F / 当前产品 | U 的变化或补充 | 原生责任/验收 |
|---|---|---|---|
| 普通逐行 | 全曲 nonDynamic 分支，无拆词 float/mask | 同时有数据 validate/稳定排序 | 行高亮，保留完整文本 shaping |
| 逐词 | chunk → timed atom → per-char emphasis | CJK split 有变化 | word/ruby 的时间映射与行宽路径 |
| 多行并行 | hot 与 buffered 不同；视觉还包含二者之间的组 | playing 与 highlighted 分离，短空隙保留高亮 | 不可仅二分找单条 current line |
| BG | 一组 main + 一条 BG；BG 可在主行之前；额外 BG 被升为主行 | 独立可见性/测量提交 | 不挤占隐藏 BG 高度；暂停全部展开 |
| duet | agent type person/other 交替换侧；group 始终左且不改变交替记忆 | 保留此 converter | 全曲含 duet 时留对侧 15% padding，BG 跟 main 侧 |
| 翻译 | parser 存多语言，converter 选一条；F 偏好中文 | parser 无差异 | 保留语言列表、可选语言、换行、高度 |
| roman | 行级在 translation 之后；词级占 0.5em 文本层 | ruby DOM 修复 | 不把 roman 误拼到主歌词，不重复显示 |
| ruby | base + timed ruby 数组；全行预留上层高度 | base 的 inline-flex 防换行 | ruby 时序分段驱动高亮，emoji/grapheme 不拆坏 |
| emphasis | 长词判定、32 帧 envelope、字符 stagger、尾词增强 | 核心曲线保留 | 字级 scale/XY/glow 和词级 float 叠加 |
| glow | white shadow，F 可缩半径；A 按主题 retint | 核心 envelope 保留 | 独立颜色/强度/半径，不能用均匀脉冲替代 |
| mask | 全行累计宽度、停顿、首尾 fade 补偿；支持 Ruby | CSS alpha transition 替代逐帧 alpha solver | 连续线性时间，不能加 easing 扭曲词时序 |
| discrete | 18 帧 log envelope、300–2000ms | 官方无此产品模式 | 可选兼容，不改变 smooth |
| enter/exit | Y spring、scale、blur、alpha；F exit catch-up | UI dirty/commit 解耦 | 保留位置速度，seek 取消 catch-up |
| scroll | wheel 50px/line；5s 回归；wheel 不设 touch flag | interaction idle150ms +5s；focus 冻结 | AppKit 事件坐标、momentum、回归，避免双重惯性 |
| focus | scrollToIndex 同时间线 | 独立 line/interlude/bottom 焦点 | 手动滚动期间冻结 focus，歌词时间继续 |
| resize | ResizeObserver→重测→同步 relayout；mask 重建按媒体时间恢复 | heights/prefix sums，先 bounds 再 commit | 新 layout 原子提交；保留 presentation pose，focus 变化保留速度，纯 resize 使用临界阻尼并清除旧速度 |
| pause/resume | word/mask 暂停，BG 展开，行 scale=1，布局仍 settle | 同类职责 | 媒体时钟与 UI 时钟分离，不能冻结所有层时间 |
| seek | 显式 seek 清 buffer，间隙选择下一组；F 无 catch-up | 重复/倒退也判 jump，gap 回填上一并行组 | profile 明确区别，seek 必须可重复、无旧 mask |
| interlude | >=4s（扣 next-start 250ms），+20ms 检测；无尾间奏 | 使用前缀最大 end 的区间并集，gap>=4s 不扣250；原生三点以 following row inset 对齐、中心锚点缩放，尺寸由 `interludeDotScale` 控制 | intro/中间/重叠/seek/resize/pause/duet 点位 |
| mouse | hover 全视图去 blur；group hover/pressed 底色；click/contextmenu | bottom wrapper 不 hover | 点击 main/BG 回同主行，命中实际动画位置 |
| bottom | 外部 bottom 内容，可获得末尾焦点 | 独立 renderer，与主行共享 layout | 元数据/credits 显示和结束焦点 |
| obscenity | full/partial + mask char，词长影响显示 | 转移到 data manager | 可选、默认关；保留作者 flag |
| 可见性 | overscan 300，离屏拆 DOM/words，重新构建恢复时间 | dirty commit、保留更多内容、viewport buffer 0.4H | 有界 glyph/raster cache，可见/运动区域挂载层 |
| 空/异常数据 | 空歌词、zero duration、无词、非有限时间存在各种 fallback | validateLyric/排序、zero-duration 不活跃 | XML错误可诊断；原子加载失败保留旧内容 |
| page/surface | pagehide 不 update；pageshow seek | 时钟 reset/visibility 流程改进 | window occlusion/miniaturize/detach 停 display link |

背景封面 shader、专辑切换属于 BackgroundRender，不是歌词组件的输入和职责。AMLL parser 保留 `emptyBeat` 元数据，但当前 DOM renderer 不用它生成一个独立的 beat 动画，不能凭名称虚构效果。

## 6. 时间线、焦点、布局状态机

### F 的状态转移（`base/timeline.ts:53–235`）

hot 命中半开区间 `[start,end)`。seek 时 buffered=hot，focus=min(buffered)，否则第一条 start>=time，超出尾部可对齐 bottom。普通推进出现新 hot 时加入 buffered、移除已结束 buffered 并更新 focus；没有新 hot 且全部 buffered 都结束时清空；仅部分结束时继续保留旧 buffered。因此 hot、buffered、视觉 active 不能合并成一个 Bool。

### U 的状态转移（`base/timeline.ts:275–735`）

playing 是当前区间命中；highlighted 保留刚结束的组直到新组开始、进入间奏或全曲结束。seek 用最后真正开始过且 duration>0 的行作 anchor，重建当 anchor 开始时仍未结束的全部组；短 gap 与普通播放结果一致。end-of-song 取所有行最大 end，不是最后一行 end。同 start 的行全部命中；零时长行不应阻塞游标。

U `SeekDetector`：首次只建立 baseline；media delta<=0 是 jump；wall delta最多800ms；播放容差 max(150ms,wallDelta*0.5)，暂停容差150ms；只对超出 expected 的正漂移判 jump。原生正式 API 提供明确 seek，时钟适配层可选此自动检测，display link 的重复采样不能反复生成 seek。

U `FocusController`：手动滚动挂起自动对齐时冻结上一 focus；若冻结在已结束 interlude，推进到后续行。正常时依次选择 interlude、end/bottom、scrollToIndex。空数据索引必须有定义。

原生采用两个明确 profile：`currentPlayer` 对照当前 F/A；`upstream` 对照 U。默认 Demo 以 currentPlayer 为主；profile 选择必须显示在导出结果里，禁止混合两个期望以提高分数。

### 布局与 resize

F 累计 group 高度，默认 anchor=center、alignPosition=0.35。base Y=`H*alignPosition - selectedHeight/2 - prefixHeight - userOffset`；间奏插入 dotsHeight+2×0.4em，duet dots 靠右。初测 fallback=H/5。播放中的 stagger 从0.05s开始，越过 focus 后每组除1.05；sync/seek 不 stagger。F 用累计行底>=0，U 用 `top+height>=0` 决定延迟开始。

U `LayoutCalculator.beginFrame/commit` 分离：先前缀和、focal top/height、scroll bounds，再 clamp user offset，最后生成 Y/visibility；对象池复用。新增 layout reason：playback、interaction end 保留 stagger；resize/config/seek/rebuild/discrete scroll 无 stagger；continuous touch scroll snap Y。新歌词 rebuild 仍从下方 spring 入场。原生在已有内容的 resize/config reflow 中使用可配置的临界阻尼 `motion.resizeSpring`，丢弃旧速度以避免长行换行时的过度弹性，同时保留旧 presentation pose。

原生重排不能销毁 timeline/word clocks。布局缓存 key 包含 TTML identity、font descriptor、font size、width、language selection、duet padding、backing scale。width 改变时按现有 glyph identity 保存 pose，重测后从旧 presentation 位置到新目标，携带速度；尺寸为0时延后，不产出 NaN。自动 focus 与用户滚动 anchor 分开保存。不要在 render frame 里反复 CTFramesetter 重排。

## 7. 动画的可执行参数规格

| 动画 | 参数、时间和叠加规则 | 来源 |
|---|---|---|
| group Y | mass .9, damping15, stiffness90；seek/interlude回到90/15；常规 interval clamp100…800ms，ratio=`(1-(interval-100)/700)^.2`，k=170+50×ratio，d=2.2√k | F base/index:107；layout:133 |
| 主行 scale | mass2/d25/k100；播放非 active=.97，active或暂停=1；transform origin左/duet右 | F base/group:88 |
| BG line scale | mass1/d20/k50；inactive播放=.75，其余1 | F base/index/group |
| BG wrapper | 默认 Spring100/10/1，slide 从±80%到0；progress=clamp(1-|slide|/80)，scale=.8+.2progress；BG在前时隐藏高度折叠 | F dom/lyric-group:84–164 |
| opacity/blur | group opacity .4s ease，filter .4s ease；blur=min(5,距离)，窄视口≤1024再×.8；hover禁blur | F CSS/base/layout |
| 词 float | -0.05em，BG×2；duration=max(1000,wordDuration)，delay=word.start-line.start；ease-out，add，fill both；exit反向播放 | F dom/lyric-line:643 |
| emphasis 条件 | CJK atom≥1000ms；Latin 1<trimmed UTF16 length≤7且≥1000ms；Latin chunk可整体判定，CJK chunk由成员触发 | F base/line:87；dom:554 |
| emphasis amount | du=max(1000,duration)；a=f(du/2000)×.6，b=f(du/3000)×.5；f(x)=x³ if≤1 else√x；尾词a×1.6,b×1.5,du×1.2；cap a1.2,b.8 | F dom:673–704 |
| emphasis envelope | 前半 cubic-bezier(.2,.4,.58,1)，后半1−bezier(.3,0,.58,1)；32 samples，offset=(j+1)/32 | F dom:27–48,724–762 |
| 字级 emphasis | stagger=`du/2.5/anchorCharCount * i`；anchor优先ruby UTF16 count；scale=1+e×.1a；dx=−e×.03a×(charCount/2−i)em；dy=−e×.025a em | F dom:727–747 |
| glow | opacity=e×b；shadow blur=min(.3,b×.3)em×radiusScale；半径不是随 e 一起缩放；transform replace，float add | F dom:748–790 |
| emphasis float | sin(πx)×−.05em，BG×2；duration=1.4du，delay=字delay−400ms；exit同普通float回落 | F dom:769–795 |
| 连续高亮 | 整行 timed width累计、每词独立裁切可见窗口；停顿保持；首词额外推进1.5fadeWidth、末词.5fadeWidth；fadeWidth=wordHeight×.5（可配置） | F dom:1000–1193 |
| 原生高亮时钟桥接 | `LyricsClock` 预测 media time，正常 mask 进度立即应用，不再使用拖尾滤波。暂停/seek 精确采样。词间空隙的小幅向前预走是原生产品扩展：AMLL 源码本身保留静止 keyframe；默认预走最多1.44pt且不超过下一段8%，不延迟正常词时序。 | F dom mask keyframes；Native `Motion.swift` / `TextLayout.swift` |
| Ruby扫光 | 每ruby的UTF16长度分配base词宽；使用ruby自身start/end并clamp在词内，逐段保持停顿 | F dom:1090–1151 |
| F mask alpha | scale factor=clamp((scale−.97)/.03)；dark=.2+.2factor，bright=.2+.8factor；solid令bright=dark；attack50/release7，`1-exp(-speed*dt)` | F dom:1236–1288 |
| U mask alpha | solid .2/.2→gradient1/.4；CSS ease-out，亮起.3s、暗下.45s，与scale解耦 | U CSS/property；dom:setRenderMode |
| F exit catch-up | 非seek且playing；mask剩余>16ms；duration clamp120…280，rate=max(1,maxRemaining/duration)；异步generation防旧完成回调 | F dom:225–314 |
| discrete | duration clamp300…2000ms；18段 `log1p(2.2x)/log1p(2.2)`；窗口inactive .28、BG .4、fullscreen0；CJK不合并词时序 | F dom:808–853,1194 |
| dots入场 | 前2000ms easeOutExpo；前500ms透明、500…1000ms线性淡入；base scale .7 | F/U dom/interlude-dots |
| dots持续/退出 | F breathe=D/ceil(D/1500)，sin(1.5π−2t/breathe)；U改4500且乘2π；最后750ms back easing，最后375ms fade；三点依次 .25…1 | F/U interlude-dots |
| 鼠标 | hover底色 #fff1、pressed #ffffff05、.25s；contextmenu与click都在group捕获；BG点击返回main索引 | F dom/index:89；CSS |

F Spring 的两个实现细节不应误当物理学：`soft || ζ>=1` 强制临界分支；arrived 中 velocity/acceleration 未取绝对值，U已修复。延迟队列在旧 solver 前进后才到期，retarget继承当前速度；同目标更新在 U 有近似去重。保留可感知曲线与速度，不复制旧 queue 清理缺陷。

## 8. AMLL TTML 输入契约

正式加载入口只接受 XML TTML Data/String，不接受 AMLL JSON、LRC、ESLyric 或任意 HTML。默认加载的是 AMLL absolute profile；真正的 W3C parent-relative profile 必须显式选择。文档模型要保存段落、词、Ruby、语言、agent、source timing、空白和 metadata；之后才生成 renderer profile。

**AMLL 与通用 W3C profile 必须显式区分。** AMLL parser 使用媒体绝对时间，不把嵌套节点的时间再加上父节点起点；音乐库中还存在无默认 TTML namespace 的历史文件。NativeLyrics 默认使用 `.amllAbsolute`，直接解析这些原始 bytes，并在模型中保留 namespace shadow、紧凑 `mm:ss`、裸十进制秒数、metadata 和 sidecar 兼容性。真正需要父子相对时钟的调用方必须显式选择 `.w3cRelative`；两个 profile 都不会改写输入 XML。

Demo 对玩家资料库的打开入口也遵守这条边界：`DemoTTMLImporter` 直接把原始 Data 交给 `TTMLDecoder`，没有 adapter、猜测性重写或二次序列化。显示标题优先使用歌曲目录旁的播放器元数据，其次才使用 TTML 的 `amll:meta musicName`。

支持的歌词 TTML profile：

- `tt/head/metadata/body/div/p/span/br`，TTML namespace；按 URI 解析 `ttm/tts/ttp/xml`，不用 prefix 拼写识别。
- AMLL 时钟支持 `hh:mm:ss.fraction`、紧凑 `mm:ss` 和裸秒数；同时保留显式 W3C profile 的 offset `h/m/s/ms/f/t`、frame/subframe、frameRateMultiplier/tickRate 解析。默认 media timeBase；AMLL 的父节点范围只用于结构校验，不给子节点时间加 origin。
- `xml:space`、xml:lang、xml:id、ttm:agent；角色 x-bg/x-translation/x-roman 是 namespaced lyrics extensions，不伪称为 W3C 内置角色。
- `tts:ruby` container/base/textContainer/text；保留注音时间。iTunes sidecar translation/transliteration按 key/for关联；语言选择和词音译对齐可配置。
- 基本 style/region 的字体/对齐可解析或给出诊断；字幕区域布局、TTML任意set/animate、图像/音频嵌入、vertical writing和wallclock/SMPTE/drop-frame不属于 AMLL 歌词 profile，遇到必须报告不支持，不能静默声称完整TTML2播放器。
- 非法XML/namespace/时间、不支持timeBase、无界活动段落可报错；零时长可保留但不活跃；输入失败不破坏已载入文档。

上游 `TTMLParser` 存多语言/words/ruby/agents，`toAmllLyrics` 降为 main+BG数组。词roman对齐优先start差≤2ms，否则按时间交并比≥.1选最优并推进游标。person agent切换翻转duet；首个other从右侧；group总左不更新person记忆。原生使用这些已有歌词语义；时间解析由 `TTMLDecoder` 直接按 AMLL absolute profile 完成，通用 W3C relative profile 仅显式启用。

## 9. Apple 原生方案与职责边界

### 系统 Spring：已经做过数值实验

选择 `SwiftUI.Spring(mass:stiffness:damping:allowOverDamping:false)` 的 value/velocity API，由 display link 采样。该 API 是独立值模型，不要求 SwiftUI animation transaction 或 View 树。soft 时将阻尼映射至临界阻尼。排队 target、延迟和回落由引擎的动画轨道负责。

2026-09-05 / Swift6.3.3 / macOS26：m=.9,k=170,d=[10,15,28.68,80]、delta200、initialVelocity75，0…2s按120Hz共964个采样；系统结果与 F `solveSpring` 公式最大绝对误差 `2.842170943040401e-14`。此结果证明这些曲线的基础求解可用系统API；不是全部retarget/queued状态验收，后续测试要覆盖它们。

`CASpringAnimation` 适合无须逐帧取状态的独立装饰，但当前歌词Y/scale会反复改目标，且要导出确定性轨迹、计算mask alpha与BG高度。选系统Spring值模型可以直接取得速度，避免从CALayer.presentation反推。无需自写微分方程求解器，也不套用duration/bounce近似公式。

### Core Text / Core Animation / AppKit / Metal

| 原生能力 | 使用方式 | 保留的自定义部分 |
|---|---|---|
| Core Text | 字体fallback、shaping、字形/advance、UTF16→glyph、CTLine绘制；普通行整行排版 | AMLL chunk边界及均衡断行成本不能用普通贪心换行代替 |
| CTRubyAnnotation | 标准静态ruby可用 | AMLL要求独立timed ruby mask及统一上层baseline时使用显式CTLine层 |
| CALayer | 持久group/line/word/character，transform、opacity、mask、shadow | group状态和animation composition，不重建DOM那样大量对象 |
| CAGradientLayer | 平滑mask边缘；active/base同一glyph mask | 全行mask路径、词间停顿、ruby时间分段 |
| CABasic/KeyframeAnimation | 标准ease-out、简单opacity、32帧emphasis可编码为系统keyframes | 可重复seek、暂停与UI时钟分离；测试模式确定性采样 |
| AppKit | NSWindow/NSView、NSEvent、tracking area、hit test、font/open panels、accessibility | focus/5秒回归和歌词点击事件；不另写触控板惯性 |
| NSView.displayLink | 与所在屏幕同步；隐藏/脱屏不回调 | 暂停settle后主动停、wake/occlusion/detach销毁 |
| Core Image | 必要时缓存有限模糊档位，避免每帧CPU卷积 | cache budget/纹理尺寸；不要依赖私有CAFilter |
| Metal | 保留为profile证明瓶颈后的可替换合成后端 | 当前不重写字体rasterizer、spring或全屏背景shader |

CoreText对象在同一工作队列构建/使用；不要在后台布局和主线程修改同一CTLine。布局完成作为不可变结果提交，UI state唯一owner。位图按backing scale生成；字体/宽度/颜色变化明确失效，不能整曲每帧栅格化。

## 10. 性能与内存

- 媒体时间来源是host快照+单调时钟，不累计1/60；UI spring独立随wall clock推进。暂停、倍速、长帧和seek不会使两个时钟互相污染。
- timeline存值数据；可见层按viewport+300pt+运动余量保留。避免逐字符NSView；通常只有一个NSView，字形在layer中。
- 缓存按byte计费，独立纹理不超过预算；大尺寸字符串避免创建整首歌词的超高位图。每帧记录活跃层数/缓存bytes/布局次数/耗时。
- resize合并最新请求，旧generation不能覆盖新布局；不在音频线程解析TTML或构建图层。
- paused+settled、hidden、miniaturized、occluded、detached分别测试；有窗口对象不等于有可见消费者。
- 性能目标（待实测，不是已达成数字）：60Hz主线程歌词帧p95<4ms；120Hz p95<3ms；1000词固定素材长播内存趋稳；连续resize不产生随次数线性增长。
- 对照时分开进程RSS、renderer cache、主线程CPU、GPU、frame interval。浏览器的WebContent进程必须一起计入；不能只比较宿主PID。

## 11. Demo 与后续接入

独立 package 放在 `Tools/NativeLyrics`，产出 NativeLyrics library、NativeLyricsDemo AppKit `.app`、测试和离线轨迹导出工具；父Xcode app保持原样。正式输入只有规范TTML。

Demo固定本机歌曲《Bet On Me (feat. Tyler Shaw)》/ Walk Off the Earth & Tyler Shaw，时长约172.020s，549个timed spans、18处BG、两agent；可以模拟单调媒体时间，也可选择对应音频播放。素材准备保留原文件hash并生成标准TTML；音频和实际音乐库路径不进入公共提交。Demo启动时预览第一条有时间的歌词词；`--start 0` 可回到精确前奏时间。若本地固定歌曲缺失或无效，则回退到从0秒有歌词的 Glow fixture。Demo 另有 `Library songs` 菜单扫描已登记的资料库 `Tracks` 目录，提供最多 48 首已通过导入验证的歌曲用于切换和人工对照。项目现有 complex/ruby/duet fixtures及自有边界fixture补足歌曲缺失场景。

控制：play/pause、seek slider/数值时间、±5s、点击歌词、手动跟随恢复、font/size、语言、profile、smooth/discrete、emphasis/glow开关、Glow 半径 0.5×–3×、间奏点尺寸 0.5×–2.5×、五组标准 TTML 示例（固定歌曲、动态运动、长词 Glow、Duet/Ruby、Chorus/BG）、资料库歌曲选择、resize、固定时间截图/轨迹、窗口关闭/重开。Native 的 Glow 以每个字形的 Core Text alpha 位图作为 mask，再用 Core Image 高斯滤镜；不填充带 padding 的 glyph tile，避免出现矩形光团。间奏点使用与歌词行相同的水平 inset、中心 transform anchor，duet 仍按右侧语义对齐。测试工具能以相同事件序列驱动native和独立浏览器reference。reference可用WebKit/Chromium，但不链接进原生引擎或Demo。

迁移阶段：

1. 此规格→不可变TTML模型/时间线/系统spring验证→完整原生layer renderer→独立Demo。
2. 在同一素材/尺寸/font/时钟/配置下完成下节parity；失败case成为回归fixture，不能按肉眼调一个总体“像”。
3. 为 `LyricsSurfaceManager` 增加可选择的renderer适配器，复用presentation/config/snapshot owner；先开发开关，继续保留WK回退。
4. 分别验证main/batch/fullscreen/CoverBlur/AppleStyle、三种全屏宿主、MiniPlayer/Dock/歌词来源/外部播放和颜色语义。原生engine不负责音频播放控制或主题推导。
5. 满足parity与实机性能门槛后才决定默认切换；删除Web实现需要单独阶段。

## 12. 90% parity验收

分母在测试前固定。测试场景包括：line/word/BG-first/BG-after/duet/parallel/nested overlap/translation/roman/ruby、CJK/Latin/emoji/combining、长词/长行/单行/空文档、intro/middle/end、pause中resize、seek进gap/interlude/word/tail、同start/zero duration、短前后seek、用户滚动+回归、hover/click/contextmenu、字体/颜色/缩放/质量变化、反复加载/隐藏/关闭。

每个case固定reference SHA、profile、标准TTML hash、native版本、OS、字体PostScript名、字体size/weight、viewport points/pixels、DPR、fps、媒体及wall时间序列。保存结构化timeline/geometry/transform/mask/glow轨迹和PNG/视频。

| 类别 | 权重 | 最低要求 |
|---|---:|---|
| timing/状态 | 30 | active/hot/highlighted/focus/seek目标逐事件一致；边界误差≤1帧；禁止seek错音频时间 |
| 几何/排版 | 25 | 文本无丢失；常用字体换行点匹配；focus baseline误差≤2pt，归一化bounds误差≤2% |
| 运动 | 25 | Y/scale/速度/peak/settling/delay曲线；关键峰时差≤1帧，归一化RMSE≤5% |
| 高亮/材质 | 15 | word/ruby高亮进度误差≤.03，glow envelope/半径/颜色、blur/alpha时序 |
| 交互/生命周期 | 5 | hover、click、scroll/5s回归、pause/resize/reveal、关闭释放 |

总分≥90且**每个主要歌词类型≥90**，无P0/P1状态或文本缺失才可称达标。SSIM仅作栅格化辅助指标；不能用背景大面积相同像素冲高分。文本/词mask/动画区域单独比较，颜色需统一色彩空间。当前F/A与U分别评分，不能互相替代。

resize额外硬门槛：同glyph identity首帧presentation位移连续，不突然回顶部/重演整曲enter；word进度不归零；0宽度恢复不闪空；持续拖拽期间命中测试对应屏幕当前位置。

性能与视觉分别出结果。build、单元测试、系统spring公式匹配不证明像素或全部运动parity。任何尚未自动化或人工确认的case写为未验证，不填虚构百分比。

## 13. 外部原生能力依据

- [Apple Spring：物理参数与value/velocity](https://developer.apple.com/documentation/SwiftUI/Spring)；本机SDK的SwiftUICore公开interface已核对。
- [Apple CASpringAnimation damping](https://developer.apple.com/documentation/quartzcore/caspringanimation/damping)；不可把它的settlingDuration等同产品duration滑块。
- [Apple NSView.displayLink](https://developer.apple.com/documentation/appkit/nsview/displaylink(target:selector:))：随视图所在display调度。
- [Apple Core Text](https://developer.apple.com/documentation/CoreText)：系统shaping、font cascade及布局对象队列约束。
- [W3C TTML1 timing](https://www.w3.org/TR/ttml1/)、[TTML2](https://www.w3.org/TR/ttml2/)：标准时间容器与命名空间依据。

AMLL源仓库带AGPL-3.0许可，spring.ts另标注pushkine MIT来源。实现若衍生其行为算法/测试应保留对应来源与许可证通知，不把这些源码标成自行原创。发布范围的许可审查随正式接入进行；本阶段不发布软件。

## 14. APP fork 适配层的额外合成状态

这部分来自当前播放器随 fork bundle 一起加载的 `index.html`/`bridge.js` 适配层，不是官方 core 的默认 API。原生实现已在 `LyricsConfiguration` 中保留同名语义，避免正式接入时把这些行为误丢掉：

| APP 适配字段 | 原生对应 | 行为边界 |
|---|---|---|
| `fullscreenCoverBlurMode` | `surface = .coverBlurLight/.coverBlurDark` 或 `coverBlurGenericMode` | lyric surface 自己只输出透明/不透明文字层；封面模糊背景仍由宿主合成 |
| `fullscreenCoverBlurProfile` | `coverBlurProfile = .lighter/.darker` | lighter 使用 `plus-lighter` 语义和较低 BG alpha，darker 使用 `plus-darker` 语义和较高 BG alpha；原生层用 Core Animation/CIFilter 合成提示，宿主可改为自己的 Metal 合成 |
| `coverBlurRenderLayer` | `coverBlurRenderLayer = .full/.base/.highlight` | base 只保留底字形，highlight 只保留 active mask/强调层，full 为单层；同一 TTML 可稳定生成两张可合成表面 |
| `coverBlurHideActiveMainLine` | 同名 | base 合成需要时隐藏 active 主歌词，避免与另一张 highlight surface 重叠 |
| `coverBlurSuppressEmphasisGlow` | 同名 | 关闭强调 halo，但不改变字符放大、位移和 mask 时序 |
| `coverBlurFullscreenGenericMode` | `coverBlurGenericMode` | 允许 fullscreen lyric dodge 使用 cover-blur 的亮/暗语义，即使背景并非当前 surface 直接拥有；普通 window surface 不会误启用 generic compositor |
| `coverBlurFullscreenThemeColor` | `coverBlurThemeColor` | 仅作为宿主背景调色的语义输入；歌词引擎不把它误当作封面图或自行推导 ThemeStore |
| `fullscreenAppleStyleMode` | `fullscreenAppleStyleMode` / `.appleStyle` | 保留 AppleStyle 的不透明文字层、翻译独立颜色和较小 glow 半径 |
| `fullscreenLyricDodgeMode` | `fullscreenLyricDodgeMode` | 把 surface 切到不透明合成路径；不会另起一套 WK/DOM 布局 |
| `completedParallelHighlight` | `preserveCompletedHighlight` | 并行歌词有新 hot group 时保留仍在退出动画中的 active layer；可为单层宿主关闭 |

同一适配层还会动态下发 `blendOpacity`、`mixBlendMode`、`renderScale`、
`fpsCap`、`alignOffset` 和可调的 spring 参数。原生配置对应为
`blendOpacity`、`blendMode`、`renderScale`、`fpsCap`、`alignOffset`；
位置 spring 仍可通过 `positionSpring` 直接提供质量/阻尼/刚度，避免把
APP 的 duration/bounce UI 值未经验证地伪装成同一条物理曲线。`automatic`
blend mode 会在 cover-blur surface 选择 lighter/darker 合成提示，并缓存
Core Image filter，避免每帧创建 filter；最终 plus-lighter/plus-darker
仍允许宿主以 Metal 或自己的 layer compositor 替换。

cover-blur 的背景图、blur radius、主题取色和全屏容器属于宿主渲染责任，不能塞进 TTML 或让歌词 view 读取音频/封面服务。Demo 现在保留可实际验证的窗口、采样、歌词样式、字体、glow、暂停/播放、seek、TTML/音频导入和三条独立混合通道；cover-blur 的 full/base/highlight、隐藏 active、抑制 glow、generic cover 与 lyric dodge 仍由公开 `LyricsConfiguration` 接口提供，生产接入时由 `LyricsSurfaceManager` 将 ThemeStore 的 Display P3/sRGB 语义颜色和宿主的背景 compositor 映射到同一配置。

当前 Demo 对 APP fork 的几何实测也已固定为验收基线：760pt 宽、主字号 38、翻译 28.5、主行 line-height 1.42em、line wrapper 前后留白抵消 `.lyricLine` 的负 margin；固定歌曲前 9 个可见组的 DOM/native 高度误差约 0.1pt、位置误差约 0.3pt。这个结果只代表当前字体和 viewport，不替代后续不同字体、resize、全屏和实机合成验收。

## 15. 当前可配置接口清单与评估

正式接入时，宿主只需要维护一个 `LyricsConfiguration`，再通过 `LyricsView` 的时钟和交互入口驱动渲染。当前接口已经覆盖 Demo 与 APP fork 的主要视觉、时序和交互差异：

| 类别 | 已开放接口 | 当前评估 |
|---|---|---|
| 字体与排版 | `fontName/fontSize/fontWeight`、翻译字体、`translationLanguage/romanizationLanguage`、`showTranslation/showRomanization/showRuby`、`alignPosition/alignAnchor/alignOffset`、`obscenity/maskCharacter` | 已足够覆盖 CJK/Latin、翻译、音译、Ruby、左右对唱和窄宽度换行；region 的动态 TTML 样式仍按 AMLL profile 诊断，不把任意 TTML2 region 当作歌词布局 |
| 基础颜色 | `palette.mainActive/mainInactive/translation/background* /emphasisGlow` 及两个 BG opacity | 已覆盖 window、AppleStyle、cover-blur 明暗皮肤；ThemeStore/P3 取色由宿主注入 |
| 合成 | `channelBlend.inactive/current/highlight`、`blendMode`、`blendOpacity`、`backdropColor`、`coverBlurRenderLayer` | highlight 在单字形 alpha mask 内合成；inactive/current 才可选整层 compositor，避免把高亮模式错误作用到背景 |
| 运动参数 | `motion.blurRadius/maximumBlurRadius/blurTransition/pointerExitDelay/clickStagger/backgroundTransition/resizeSpring/exitFade/catchUpMinimum/catchUpMaximum/highlightAnticipation`、`positionSpring` | 已将 resize 与 focus spring 分开；默认 resize 为临界阻尼并清除旧速度，避免半句换行时过度弹性。逐参数暴露便于皮肤调校，但不应由 UI 把 duration 伪装成 spring |
| 歌词行为 | `profile`、`highlightMode`、`lineTimingOnly`、`preserveCompletedHighlight`、`hidePassedLines`、`alwaysPostpositionBackground`、`emphasis`、`glow`、`glowRadiusScale`、`blur`、`scale`、`spring`、`hoverBackground`、`bottomText`、`interludeDotScale` | 已覆盖当前 fork/upstream、连续/离散高亮、退出追赶、并行歌词、BG 顺序、间奏、暂停、点击和滚轮。间奏点尺寸已开放，位置和缩放锚点由引擎固定为行内 inset + 中心 anchor |
| Cover-blur / fullscreen | `surface`、`coverBlurProfile`、`coverBlurGenericMode`、`coverBlurHideActiveMainLine`、`coverBlurSuppressEmphasisGlow`、`fullscreenAppleStyleMode`、`fullscreenLyricDodgeMode`、`coverBlurThemeColor` | 保留 APP 的语义开关；封面图模糊、背景 shader、surface 生命周期仍属于 `LyricsSurfaceManager`/宿主 |
| 时间与质量 | `timing.enabled/trackOffset/globalAdvance/leadIn/nearSwitchGap/seekOffset`、`renderScale`、`fpsCap`、`cacheBudgetBytes`、`overscan` | 输入仍严格是标准 TTML；offset 与点击 seek 分开，质量/缓存设置不会改歌词时间 |
| 驱动与交互 | `load(ttml:)`、`synchronize(time:playing:seek:motion:)`、`onSeek`、`onFrame`、`scroll(by:)`、`followCurrentLyrics()`、`setPointerInside`、`snapshotImage`、`automaticDisplayUpdates` | 足够接入播放器、拖拽 seek、点击跳转、滚轮回位、性能采样和窗口/全屏；宿主不需要触碰 layer tree |

仍建议在正式接入前补充，但不应阻塞当前原生 Demo 的项目：

- 如果产品皮肤需要，补充 `interludeDotColor`、`interludeDotSpacing` 和 hover/pressed 颜色；目前颜色继承主行 active，间距继承 AMLL 固定比例。
- 如果一首歌需要多条翻译同时显示，补充翻译层的选择策略和每层字体/颜色；当前接口明确选择一种语言，避免把 TTML 关联层静默叠加。
- 如果外部 accessibility 或测试工具需要逐行标识，补充稳定的 group/word accessibility element；现阶段 NSView 已有整体 Lyrics 语义和复制菜单。
- 任意 TTML2 region、图像/音频嵌入、wallclock/SMPTE、垂直书写和宿主背景 shader 不属于歌词引擎配置，应继续由输入适配器或宿主负责，不通过“万能 style”接口扩大职责。
