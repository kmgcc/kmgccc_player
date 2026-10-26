# 原生皮肤开发

皮肤包使用原生场景 v2，由 App 渲染布局、数据绑定、材质、交互和效果。包内可以包含图片、字体、循环视频和 Metal 源码。普通用户在播放页或全屏设置中导入 ZIP，再从列表选择皮肤。

本文描述开发中的 v2 接口。JSON v1 不再接受。

## 包结构

ZIP 根目录包含 `manifest.json`。场景可直接写在 manifest 的 `scene` 中，也可写成包内 JSON 相对路径；`scenes.window` 和 `scenes.fullscreen` 可以提供各自布局。两个模式的选择与参数独立保存。

```json
{
  "formatVersion": 2,
  "hostAPIVersion": 2,
  "version": "1.0.0",
  "descriptor": {"id": "example.reading", "name": "阅读"},
  "requires": ["scene@2", "theme@1"],
  "scene": {
    "root": {
      "type": "text",
      "text": "=track.title",
      "fontSize": 32,
      "color": "=theme.appForeground.primary"
    }
  }
}
```

[JSON Schema](skin-package-v2.schema.json)用于编辑器补全和结构检查。表达式、组件与能力的最终校验由 App 的 `skin.check` 完成。

包只能引用自身目录内的本地资源。路径使用相对路径，不能包含上级目录、绝对路径或链接。包中最多 4096 个条目、展开后最多 512 MiB，单个资源最多 128 MiB；JSON 最多 4 MiB，字体最多 16 个。ZIP 使用普通存储或 Deflate 压缩。

## 布局与节点

`layer` 自由定位子节点；`row`、`column`、`stack`、`grid` 组合布局；`scroll` 提供纵向滚动，`scrollTo` 绑定一个 repeat 序号时，该行变化后滚到中央。`switch` 按第一个满足 `when` 的分支选择，未命中时用 `default`。`repeat` 的 `items` 绑定数组，`template` 中使用 `item`、`index` 与 `count`。绑定动态数组时，`limit` 给出最多绘制的行数，展开后的节点按它计入 2000 个节点的上限；未写时按 1024 行计。直接放在 `scroll` 中的纵向 repeat 只构建可见的行，按最多 48 行计入。`"layout": "free"` 的 repeat 像 `layer` 一样按每格自己的 frame x/y 定位，适合逐词排版；它直接放在带 `camera` 的图层里时，每格各按自己的 `depth` 跟随镜头。

`frame` 包含 `x/y/width/height/size`、尺寸上下限、`aspectRatio`、`padding`、`fill` 和 `anchor`。数值是逻辑点；尺寸还接受 `50%`、`10vw`、`10vh`、`vmin` 与 `vmax`。百分比相对父容器，视口单位相对实际宿主。

内容节点包括 `text`、`lyricLine`、`symbol`、`image`、`artwork`、`video`、`shape` 与 `gradient`。未写 `color` 的文字、符号和形状使用主题的主要前景色。

任一节点写上 `"adaptive": true`，宿主就读取它所在位置下方的背景明暗，为整棵子树选择可读的前景：未写颜色的文字、符号和形状随之变色，系统材质与配色方案随之翻转，`control.miniPlayer` 等原生控件改用相应的前景与玻璃。节点表达式可读 `self.backdrop`（`light` 或 `dark`）、`self.foreground` 与 `self.secondaryForeground`。判断以封面铺满视口为背景估计，并计入 `background.host` 与 `background.dimming` 的压暗；只在节点移动、封面或压暗变化时重算。文字可设 `font`、`fontSize`、`weight`、`design`（rounded、serif、monospaced）、`italic`、`tracking`、`lineSpacing`、`lineLimit`、`alignment` 与 `minScale`。`gradient` 的 `mode` 为 linear、radial、elliptical 或 angular；`stops` 写成 `{"color": …, "at": 0.4}` 的数组，未写时 `colors` 均匀分布；径向渐变以 `start` 为中心，`radius` 为相对节点长边的半径，在非正方形的框里会被短边截断；椭圆渐变随框拉伸，`radius` 为 0.5 时恰好在框边缘收尽，适合宽幅光晕。形状支持矩形、圆、椭圆、胶囊和单位正方形坐标内的路径。路径命令使用大写 M/L/C/Q/H/V/Z，坐标为绝对值。

`component` 通过 `component` 名称调用宿主组件，`props` 传参数。`lyrics` 是 `lyrics.native` 的简写。原生歌词（含 `lyrics.panel`）每个可实现布局最多一份，不能放入 repeat；自绘歌词没有这个限制。

作者模板放在场景的 `components` 字典或包内 `components/*.json`，通过 `use` 的 `name` 和 `props` 调用。模板不能循环引用。

编译错误给出文件与 JSON 路径；拼错的节点、属性、组件、操作或事件名会附上最接近的正确名称。

## 宿主组件

内置五套皮肤的每个部件都可以单独调用，尺寸由节点的 `frame` 决定。

| 分组 | 组件 |
| --- | --- |
| 歌词 | `lyrics.native`、`lyrics.panel` |
| 封面 | `artwork.basic`、`artwork.classicFrame`、`artwork.appleStyle`、`artwork.rotatingDisc`、`artwork.coverGradientBlur` |
| 磁带 | `cassette.shell`、`cassette.label`、`cassette.reels`、`cassette.waveform`、`cassette.kmgLook`、`cassette.overlay` |
| 背景 | `background.host`、`background.unifiedMesh`、`background.amllMesh`、`background.coverGradientBlur`、`background.art`、`background.artworkBlur`、`background.dimming`、`transition.bokeh` |
| 可视化 | `visualizer.capsuleSpectrum`、`visualizer.pillSpectrum`、`visualizer.led`、`visualizer.waveform`、`visualizer.progressSpectrum` |
| 控制 | `control.miniPlayer`、`control.leadingCapsule`、`control.volumeCapsule`、`control.transport`、`control.playPause`、`control.skip`、`control.previous`、`control.next`、`control.progress`、`control.volume`、`control.expandableVolume`、`control.playbackMode`、`control.like`、`control.dislike`、`control.outputDevice`、`control.queue`、`control.lyricsToggle`、`control.fullscreen`、`control.settings`、`control.quickPanel`、`control.actionButton`、`control.glassButton`、`control.glassTriplePill` |
| 文字 | `text.trackInfo`、`text.marquee` |
| 面板 | `panel.queue`、`panel.quickAppearance`、`panel.trackDetail`、`sheet.trackEdit`、`sheet.externalInfo`、`sheet.settings`、`menu.trackContext`、`menu.player` |
| 行为 | `behavior.autoHide`、`behavior.lyricsEndAutoHide`、`behavior.scrollVolume`、`behavior.pointerOcclusion`、`behavior.windowDrag` |

`control.miniPlayer` 默认与全屏播放条等长，并在节点 `frame` 内居中。`props` 可调：`width` 为 1 倍尺寸下的总长度，`align` 为 leading、center 或 trailing；`showsLeading`、`showsVolume`、`showsTrackInfo`、`showsTransport`、`showsPlaybackMode`、`showsProgress` 与 `showsLyricsButton` 控制各部分显隐。隐去进度后，播放条按内容收紧。

`background.host` 绘制宿主在该皮肤后方的背景：用户开启艺术背景且皮肤不自带背景时显示艺术背景，否则显示 `preset` 指定内置皮肤的背景，并沿用全屏压暗。`background.art` 直接调用艺术背景。

`control.leadingCapsule` 与 `control.volumeCapsule` 须在同一布局中成对出现。行为组件包住 `children`：`behavior.autoHide` 在指针静止后隐藏内容，`delay` 为 0 时常显，`behavior.scrollVolume` 让滚轮调节音量，`behavior.windowDrag` 让拖动内容即可移动窗口。

`menu.player` 给 `children` 附上迷你播放器的完整菜单，分为 `info`（音乐资料）、`track`（喜欢与不喜欢、添加到播放列表、查看详情、编辑歌曲信息、查看艺人与专辑、从资料库删除）、`external`（外部播放覆盖信息）、`order`（四种播放顺序）、`view`（播放队列、歌词、快速外观与全屏）和 `output`（输出设备）。`include` 选出其中几段；`trigger` 为 `click` 时单击即弹出，适合“更多”按钮，默认为右键。`menu.trackContext` 是同一菜单，默认只含前三段。全屏中不显示查看艺人与专辑。

`control.playPause`、`control.previous` 与 `control.next` 是迷你播放器中带动画的按钮，可分开摆放：`size` 为点击区域边长（默认 26），`symbolSize` 为图标大小，`color` 与 `disabledColor` 为可用与禁用时的颜色，`blendMode` 为混合方式。`control.transport` 把三者排成一行，另有 `spacing` 与 `navSymbolSize`。按钮动画读取 MotionKit token，所在节点写上 `motion` 即可调节。`control.playbackMode` 是播放顺序滑块胶囊，可调 `scale`、`iconSize`、`color` 与 `expanded`。

`visualizer.led` 是迷你播放器的 LED 频谱：`count` 为灯数（1 至 64），`levels` 为亮度级数（2 至 16），`color` 为灯色，`tone` 为 `light`、`standard`、`bright` 或 `miniPlayer`，`scheme` 为 `dark` 或 `light`，`bright` 提亮灯色，`direction` 为 `leftToRight` 时从左侧点亮（默认自中间向两侧），另有 `dotSize`、`spacing`、`tint`、`pill`、`statusLight`、`paddingX` 与 `paddingY`。`visualizer.capsuleSpectrum` 的 `count` 为胶囊数，`color` 为主色，`artworkColors` 为 false 时不取封面色，`darkForeground` 改用深色，`scale` 缩放，`paused` 为 `dots` 时暂停后只留圆点。

`control.like` 与 `control.dislike` 切换当前曲目的喜欢与不喜欢；`symbol` 指定轮廓图标，选中时用其 `.fill` 版本，另有 `fontSize`、`color` 与 `activeColor`。`control.outputDevice` 显示当前输出设备的图标与名称，单击列出可选设备，`showsName` 为 false 时只显示图标。

`builtin.<皮肤>.artwork`、`.background` 与 `.overlay` 按内置皮肤自身的绘制调用整层，皮肤为 `coverLed`、`appleStyle`、`rotatingCover`、`kmgccc.cassette` 与 `fullscreen.coverGradientBlur`。默认在节点 `frame` 内绘制；`props.layout` 为 `host` 时铺满视口，按宿主的画布、封面列和封面缩放排布，与内置皮肤位置一致。`template.classicLED`、`template.appleStyle`、`template.rotatingCover`、`template.cassette` 与 `template.coverGradientBlur` 以 `background.host`、宿主排布的图层、原生歌词和迷你播放器组成完整场景，可直接作为起点。

`lyrics.native` 的 `props` 接受原生歌词设置，例如 `fontSize`、`fontWeight`、`textColor`、`alignPosition`、`showTranslation`、`hidePassedLines`、`surface`、`translationLanguage`、`romanizationLanguage`、`obscenity`，以及 `palette` 与 `motion` 记录。渲染精度、缓存与时间偏移由 App 管理。

几项常用写法：

- `highlight`：`smooth` 为扫光，`discrete` 为逐字亮起，`line` 只按行切换。扫光宽度用 `wordFadeWidth`，余晖用 `preserveCompletedHighlight`，强调与辉光用 `enableEmphasis`、`enableGlow` 与 `glowRadiusScale`，行间弹性用 `enableSpring`、`springDuration` 与 `springBounce`。
- `hierarchy`：未唱与远处的行如何退后。`opacity` 降低当前色的透明度，`brightness` 让颜色朝背景过渡、保持不透明。`activeColor` 为当前色，`inactiveLevel` 与 `translationLevel` 为 0 到 1 的层级，`hierarchyBase` 指定过渡的终点色，默认按当前色的明暗取黑或白。显式写出的 `palette` 优先。
- `userSettings`：留给用户在设置中调整的歌词选项，可写 `all`（默认）、`none`，或 `font`、`highlight`、`spring` 的数组。未列出的分组按 App 默认值起算，再应用皮肤的设定；设置页会注明哪款皮肤使用自己的设定。

这些属性都可以绑定 `params`，配合 `isUserVisible` 的参数就能出现在快速面板里。

完全自绘时不放 `lyrics.native`，改用 `lyrics` 数据域：`lyrics.lines` 是全文与逐词时间，`lyrics.current`、`lyrics.lineProgress`、`lyrics.wordIndex` 与 `lyrics.wordProgress` 逐帧更新。当前行与原生歌词一样提前进入，换行不落后于演唱。`lyricLine` 节点显示相对当前行第 `index` 行的文字，`mode` 为 `translation` 或 `romanization` 时显示译文或罗马音；写上 `highlightColor` 后，已唱部分自左向右染色，按逐词时间推进，适合单行显示；`highlightStyle` 为 `word` 时改为逐词由 `color` 过渡到 `highlightColor`，换行也准确。

## 数据与表达式

以 `=` 开头的字符串是表达式，其他值是常量。支持算术、比较、布尔、条件表达式、成员与下标访问，以及固定函数表；没有任意函数调用、循环或网络。

常用数据域：

| 域 | 内容 |
| --- | --- |
| `track`、`artwork` | 跨来源曲目信息、来源、封面身份、色板及动态封面可用状态 |
| `playback`、`clock` | 控制可用性、播放状态、音量、播放顺序、音频与歌词时钟 |
| `lyrics` | 全文、逐词时间、翻译、罗马音、背景人声、当前行与间奏 |
| `theme` | ThemeStore 的语义角色、分析结果与控件前景策略 |
| `audio` | 共享 PCM、FFT、RMS、峰值、LED、频段与可用状态 |
| `viewport`、`host` | 实际视口、显示比例、宿主、可访问性与可见性 |
| `like`、`library` | 喜欢状态（`like.state` 为 none、liked 或 disliked）、播放列表 |
| `output` | 当前输出设备的名称与图标、是否跟随系统、可选设备列表 |
| `queue` | 播放队列：数量、位置、接下来的曲目，以及完整队列 |
| `params`、`state` | 持久皮肤参数与当前场景的临时状态 |

`host.layout` 给出内置宿主为皮肤安排的位置，单位为视口点：`artwork`、`lyrics`、`miniPlayer` 与 `canvas` 各含 x、y、width、height、midX、midY，`scale` 为宿主缩放。歌词显隐时随之更新。把节点 `frame` 写成 `"x": "=host.layout.lyrics.x"` 并配 `"anchor": "topLeading"`，即可与内置皮肤对齐。`prefs.artBackgroundEnabled`、`prefs.artworkScale` 与 `prefs.miniPlayerAutoHide` 按当前界面读取用户设置。

播放队列可以完全由皮肤绘制。声明 `queue.items@1` 后，`queue.items` 是队列中每首曲目的记录（id、index、title、artist、album、duration、isCurrent），`queue.currentIndex` 为当前曲目的序号，`queue.title` 为队列名称，`queue.available` 表示当前来源有本地队列。用 `scroll` 包住 `repeat`，`scrollTo` 绑定 `queue.currentIndex`，只绘制可见的行；`artwork` 写上 `"track": "=item.id"` 即显示该曲目的缩略图；点击行时执行 `{"do": "queue.play", "value": "=item.index"}`。面板随 `host.queueVisible` 显隐，宽高、背景与排版都由皮肤决定。根节点的 `controls` 列出 `queue` 后，宿主不再叠加自己的队列面板。

`track.audio` 记录本地文件的 format、codec、bitrate、sampleRate、bitDepth、channels，以及 `isLossless` 与 `isHiRes`；外部来源为空记录。`track.hasMusicInfo` 表示有无音乐资料。

颜色提供 sRGB、Display P3 与 OKLCH 成员。`contrastRatio(a, b)` 给出 WCAG 对比度；`readable(背景, 候选1, 候选2)` 返回在背景上更易读的候选色，候选默认为白与黑，适合自绘面板上的文字。外部播放源没有本地 PCM 时，`audio.availability` 为 `externalAudioUnavailable`。只在可见节点引用音频时租用共享分析。

`clock.position` 是音频进度；`clock.lyrics` 是含视觉偏移的歌词文档时间。点击歌词使用 `seekToLyric` 或 `lyricTime(index)`，避免把视觉提前量带进跳转。

常量在编译时折叠；曲目、主题和参数按变化更新；只有引用时钟、音频或逐帧效果的节点进入显示时间线。进入时间线的节点每帧只重算逐帧的属性，其余属性保留到数据变化；但它每帧重建自身与全部子节点，所以逐帧的值应写在叶子节点上，不要写在包着控件的图层上。`camera`、`filter` 与 `bloom` 各自带时间线，只逐帧改变几何与着色，不重建子树，因此镜头漂移可以放心写在根图层上。`host.pointerIdle` 只在指针停下或再次移动时变化，可以放心用来隐藏整组控件；`host.pointerIdleTime` 逐帧更新。时间线跟随显示器，不另设帧率上限。只依赖时钟、歌词或音频的节点在暂停播放时停下；`time` 与动画函数照常运行。

## 交互与动画

节点的 `on` 可以绑定 tap、doubleTap、longPress、hoverStart、hoverEnd、appear、disappear、scroll、dragStart、drag 与 dragEnd。拖动事件提供 `gesture.x/y/fractionX/fractionY/translationX/translationY`；滚轮提供 deltaX/deltaY。操作可以是名称或对象：

```json
{"on":{"drag":{"do":"seek","value":"=gesture.fractionX * playback.duration"}}}
```

可调用播放、切歌、跳转、音量、播放顺序、喜欢、队列、歌词显隐、全屏、Quick Panel、设置、详情与编辑，以及皮肤重载、恢复和临时状态操作。操作由原有服务执行；来源不支持的控制应显示禁用状态。

菜单里的每一项也都是操作：`toggleDislike` 与 `setLike`（value 为 none、liked 或 disliked），`playlist.add`（value 为 `library.playlists` 中的 id）与 `playlist.new`，`track.delete`（先请用户确认），`musicInfo.open`，`artist.show` 与 `album.show`（全屏时先退出全屏），`output.select`（value 为设备 id，空字符串表示跟随系统），以及 `queue.show`、`queue.hide`、`lyrics.show` 与 `lyrics.hide`。

`transition` 让节点随 `visible` 淡入淡出，可用 `+` 叠加 `scale`、`blur`、`fromTop`、`fromBottom`、`fromLeading`、`fromTrailing`，例如 `"transition": "fade+fromBottom"`；写成记录时可加 token、duration、bounce、distance、scale 与 blur。`glyphs` 用于文字：进入时每个字各自从模糊中显现，先后错落，`stagger` 为 0 到 1，越大越分散；离开时按其余写法整体退场，例如 `"glyphs+blur"` 让旧行整体模糊淡出。带 transition 的节点隐藏后仍保留，不接收点击；减弱动态效果时只保留淡入淡出。

`key` 的值变化时，旧内容按 `transition` 离开、新内容进入，未写 transition 时淡入淡出；离开的一份朝反方向移动。把歌词行写成 `"key": "=lyrics.currentIndex"`，换行时上一行就会被新行推走。离开的一份默认只用一半时长，可在 transition 中以 `leaveDuration` 指定。

`"measure": true` 让节点表达式读到自身在场景中的位置与尺寸：`self.x`、`self.y`、`self.width`、`self.height`、`self.midX`、`self.midY`。适合把装饰对齐到文字，不要用来决定节点自身的尺寸。

`variants` 用 `when` 覆盖属性，可绑定 `self.hovered`、`self.pressed` 与 `self.dragging`。`animation` 使用 App 的 MotionKit token：microInteraction、control、layout、navigation、gestureSettle、emphasis、contentReplacement 与 backgroundTransition。写成记录时可指定 duration 与 bounce，仍随用户设置的动画速度缩放；写上 stiffness 时改为物理弹簧，另读 mass 与 damping。transition 与 enter 的记录同样适用。

`motion` 为节点及其子树重设 token，宿主组件的动画也随之改变：

```json
{"motion":{"speed":1.2,"emphasis":{"bounce":0.3},"control":{"stiffness":320,"damping":24}}}
```

`enter` 让节点首次出现时按给定方式进入，取值与 transition 相同，另可加 `delay`。写在根节点上，就是切换到这款皮肤时的入场；切换皮肤时，新旧场景先按 backgroundTransition 交叉淡化。减弱动态效果时只保留淡入淡出。

`keyframes` 使用 duration、repeat、trigger 和 tracks；每条数值轨道按等距采样点插值。`watch` 的 value 变化时执行 do；写上 `"initial": true` 时，节点出现时也执行一次。

`glyphMotion` 让 `text` 与 `lyricLine` 的每个字各自运动。它是一个记录，x、y、rotation、scale、opacity、blur 与 tint 各写一条表达式，围绕字的中心生效，表达式里可读 `glyph`：

| 成员 | 含义 |
| --- | --- |
| `index`、`count`、`char` | 字的序号、总字数与字本身 |
| `word`、`line` | 所在词与所在行的序号 |
| `start`、`end` | 字的开始与结束时刻，秒 |
| `age`、`progress` | 自开始以来的秒数，以及在本字时长内的 0 到 1 进度 |
| `lineAge` | 自本行第一个字开始以来的秒数 |

歌词行按逐词时间分配到字，没有逐词时间时按整行均分；普通文字以文字最近一次变化为起点，`progress` 恒为 1。静止时的字波与逐字进入可以合写：

```json
{"glyphMotion":{
  "y":"=sin(time * 2.4 - glyph.index * 0.5) * 3 + (1 - easeOut(glyph.age / 0.5)) * 18",
  "opacity":"=easeOut(glyph.age / 0.35)",
  "blur":"=(1 - easeOut(glyph.age / 0.4)) * 10"
}}
```

`easeIn`、`easeOut`、`easeInOut` 与 `backOut` 把 0 到 1 的进度映射为缓动曲线，`backOut` 带回弹。表达式里的时长宜写成 MotionKit token 的倍数：声明 `motion@1` 后，`motion.emphasis`、`motion.contentReplacement` 等给出各 token 按用户动画速度换算后的秒数，`motion.speed` 为相对标准速度的倍率；上例的 0.5 可写作 `motion.emphasis`。颜色同理取自 `theme.*`，皮肤便随歌曲换色。逐字运动与 `glyphs` 过渡可以叠加；`outline` 为每个字描边，写成宽度，或 `{width, color, hollow}`，`hollow` 只留外圈，适合做空心衬底大字。`extrude` 为每个字加上实心的厚度，写成深度，或 `{depth, angle, color, endColor}`，颜色由近及远渐变。glyphMotion 另有 `split`（红蓝错开的点数，逐字色散）与 `smearX`/`smearY`（沿位移方向的拖影）。减弱动态效果时逐字运动停止，描边与厚度保留。

逐词排版用文字测量与列表函数完成，不必手算：

| 函数 | 结果 |
| --- | --- |
| `measureText(文字, 字号, 字重, 字体)` | 文字宽度（点），字重与字体可省略；字体可用包内字体的名称 |
| `measureEach(列表, 字号, 字重, 字体)` | 每项的宽度；列表项为文字或含 `text` 的记录 |
| `cumsum(列表)`、`offsets(列表, 间距)` | 累加和；每项的起点 |
| `pluck(列表, 字段)` | 取出每条记录的一个字段 |
| `argmax(列表)`、`argmin(列表)` | 最大、最小值的序号 |
| `addEach(列表, 数或列表)`、`mulEach(列表, 数或列表)` | 逐项相加、相乘 |

例如每个词的起点：`"=offsets(measureEach(lyrics.current.words, 64, \"heavy\"), 12)[index]"`；唱得最久的词：`"=argmax(addEach(pluck(lyrics.current.words, \"end\"), mulEach(pluck(lyrics.current.words, \"start\"), -1)))"`。

`camera` 写在 `layer` 上，记录含 x、y、zoom、rotation、rotationX、rotationY 与 perspective。层内定位的子节点随镜头平移与缩放，幅度乘以 `1 / (1 + depth)`：`depth` 为 0 时完全跟随，越大越远、移动越少，负值则更近。旋转作用于整层，rotationX 与 rotationY 带透视。把镜头写成随 `time` 缓慢变化的表达式，画面便有持续的漂移与缓推。

`contextMenu` 是带 title 与 do 的菜单项数组。宿主保留全局快捷键、空白处恢复菜单和全屏所需入口。

## 材质、效果和素材

`material` 支持 ultraThin、thin、regular、thick、ultraThick、bar。`glass` 支持 regular、clear、identity、tint、interactive、shape 与 cornerRadius；`glassGroup` 提供融合容器。

通用效果有 opacity、rotation、scale、offsetX/Y、blur、brightness、contrast、saturation、grayscale、hueRotation、invert、blendMode、clip 与 mask。`blendMode` 可用 multiply、screen、overlay、darken、lighten、colorDodge、colorBurn、softLight、hardLight、difference、exclusion、hue、saturation、color、luminosity、plusLighter、plusDarker 与 destinationOut，任意节点都能使用，光斑常用 plusLighter。`"group": true` 先合成整个子树，内部的混合只作用于彼此，不影响下层。显式 border、shadow 是作者效果，不改变 App 设置的默认样式。

`filter` 给节点套上内置着色器，写成一个 `{type, ...}` 或按顺序叠加的数组：

| type | 参数 | 效果 |
| --- | --- | --- |
| `chromatic` | amount、angle | RGB 色散，红蓝沿角度错开 |
| `glitch` | amount、slice、rate、intensity | 水平切片随机错位，rate 为每秒跳变次数，intensity 为发作比例 |
| `motionBlur` | x、y、samples | 沿位移方向的运动模糊 |
| `scanlines` | spacing、intensity、speed | 扫描线 |
| `wave` | amplitude、wavelength、speed | 缓慢的液态扭曲 |
| `grain` | amount | 逐帧胶片颗粒 |

`custom` 调用包内预编译的着色器库，写法为 `{type: "custom", library: "fx.metallib", function, kind, args, reach, animated}`。`kind` 为 layer（可采样子树）、color 或 distortion；函数在 SwiftUI 规定的参数之后依次收到 `float2 size`（含外扩的画布尺寸）、`float time`，再按顺序收到 `args`：数为 float，2 至 4 个数的列表为 float2 至 float4，颜色为 half4。`reach` 为最大采样偏移，`animated` 为 true 时逐帧更新。用 `xcrun -sdk macosx metal -o fx.metallib fx.metal` 编译，源码以 `#include <SwiftUI/SwiftUI_Metal.h>` 开头，函数标注 `[[stitchable]]`。

`bloom` 让子树的亮部向外泛光并叠加回去，写成半径，或 `{radius, intensity, threshold}`。滤镜与泛光按效果所需的范围外扩绘制，不会被节点边框裁掉；它们作用于整棵子树，应写在文字或装饰等叶子节点上，不要套在整屏图层上。减弱动态效果时，glitch 与 wave 停止。

`fog` 节点绘制域扭曲的分形噪声雾，`colors` 给出由暗到亮的两色（只给一色时从透明过渡），`size` 为一团雾的尺度（点），另有 `speed`、`warp`（折叠强度）与 `gain`（对比）。叠一层低不透明度的 fog 即是网易云式的流雾，换成暗红两色便是流体底。

`shape` 的 `stroke` 改为描线，写成宽度，或 `{width, color, cap, join, dash}`；同时写了 `color` 时才另行填充。`trimStart` 与 `trimEnd` 截取线段，让 `trimEnd` 随时间从 0 走到 1，就是逐笔画出的线圈。

`spectrum`、`waveform`、`meter` 直接绘制共享音频。`particles` 提供确定性的粒子画布：默认是缓缓上浮的尘点；写上 `lifetime`（秒）后改为发射，每颗粒子在随机位置出现，沿 `angle` 度方向、在 `spread` 度内散开，以 `speed` 点每秒飞行，在一生中淡入淡出，`trail` 给出以秒计的拖尾，`colors` 为随机取用的颜色。配合 `blendMode: plusLighter` 与 `bloom`，就是带拖尾的彗星与火花。`shadow` 可以写成数组，按顺序叠加多层。`video.path` 加载静音循环视频，隐藏时停止；动态封面使用 `artwork`，沿用 App 的共享解码。

`fonts` 列出包内 ttf、otf 或 ttc 路径。字体按可见场景持有，退出后释放登记。

Metal 节点用 `path` 指向源码，`function` 默认为 skinFragment，须为常量标识符。源码定义以下函数：

```cpp
float4 skinFragment(float2 uv, constant SkinUniforms& u, texture2d<float> artwork)
```

宿主提供 resolution、time、lyricsTime、progress、bass、mid、treble 与 accent。编译异步进行，错误显示在该节点。请从[流彩样例](examples/skins/shader/shaders/flow.metal)开始。

## 参数、安装和开发

`parameters` 声明 id、title、defaultValue、control；control 支持 toggle、range、choice 和 color。`isUserVisible` 为 true 的参数出现在设置的皮肤选项与全屏快速面板中，只为少量重要选项开启。`visibleWhen` 可以引用其他 params，支持参数联动。相邻且 `section` 相同的参数归在同一小标题下。普通用户不编辑位置。场景用到 `control.miniPlayer` 时，快速面板同时列出播放条的可视化、自动隐藏与材质；用到 `background.host` 时，窗口设置列出艺术背景开关。

内置原件保留，导出置灰。导入同 ID 用户包时可替换或另存副本；失败保留当前版本。删除使用中的皮肤会把相关模式切回默认皮肤，播放继续。

“关联目录”登记作者目录，并监听文件变更。错误保留上一次可用场景；移除关联保留源码。右键刷新或设置内重载会重新编译当前包。

从仓库根目录检查和打包：

```sh
python3 scripts/check-skin-package.py --all-examples
/usr/bin/ditto -c -k docs/examples/skins/vinyl /tmp/vinyl.zip
```

结构检查不解析表达式。App 已运行且 Automation 获准时，使用现有 CLI 的通用调用：

```sh
player-automation automation call skin.capabilities
player-automation automation call skin.check --params-json '{"directory":"/absolute/author/directory"}'
player-automation automation call skin.reload --params-json '{"skinID":"example.vinyl"}'
player-automation automation call skin.runtime
```

skin.runtime 返回活动节点、帧求值次数与音频读取者计数；CPU、内存和帧时间仍需性能工具测量。

## 样例

- [唱片](examples/skins/vinyl/manifest.json)：自绘控件、旋转封面与音频绑定。
- [浮光](examples/skins/glass/manifest.json)：可切换的艺术背景、随背景明暗变化的播放条、可调长度与显隐，以及在快速面板切换歌词高亮与层次。
- [字里行间](examples/skins/poster/manifest.json)：全文歌词自绘、当前行逐词染色、滚动和点击跳转，控件在指针静止后淡出。
- [流彩](examples/skins/shader/manifest.json)：Metal 背景、粒子与原生歌词。
