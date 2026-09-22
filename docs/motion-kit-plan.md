# MotionKit 动画标准化与渐进迁移计划

> 状态：调查完成，待 Phase 0 评审
>
> 更新时间：2026-09-22
>
> 适用范围：`kmgccc_player` 以及后续可复用同一套基础设施的 macOS App

## 1. 目标与结论

### 1.1 目标

建立一个独立、可复用的 `MotionKit`，把应用中分散的动画参数、曲线选择、无障碍策略和 Core Animation 适配统一起来，然后分批将**歌词渲染之外**的状态动画迁移到这套体系。

目标不是把每一处代码都替换成同一个数值，而是让每处动画都能回答三个问题：

1. 这是哪一种交互语义，例如按钮按下、布局展开、页面切换或拖拽松手。
2. 这类动画的默认 `duration`、`bounce` 和打断行为是什么。
3. SwiftUI、Core Animation、手写 `CADisplayLink` 是否使用同一份运动定义。

### 1.2 关键结论

1. **不需要自己重写弹簧求解器。** macOS 原生已经提供 SwiftUI `Animation.spring(duration:bounce:)`、`Spring` 的物理参数与 `value/velocity` 评估能力，以及 Core Animation 的 `CASpringAnimation`。`MotionKit` 应该封装这些 API，而不是再实现一套竞争的物理公式。
2. **`duration` 与 `bounce` 作为应用层主入口是正确的。** `duration` 是 Apple 定义的感知时长，不应被当作严格的动画结束时间；`bounce = 0` 表示视觉上无超调的平滑弹簧，不等于普通的三次贝塞尔 `easeInOut`。
3. **动画 token 应按语义分层，而不是按视图命名。** 组件可以有少量局部覆盖，但不能让每个页面继续拥有自己的 `response`、`dampingFraction` 和 timing curve 常量。
4. **不是所有动画都应该弹簧化。** 连续播放进度、跑马灯、频谱、音频电平、粒子、着色器和部分转盘动作属于时间/相位驱动，应保留对应的时钟或关键帧模型。MotionKit 负责统一状态动画和物理适配，不负责消灭所有非弹簧运动。
5. **歌词渲染保持独立边界。** MelismaKit/NativeLyrics 已有自己的歌词时钟、位置弹簧、seek 语义和 AMLL 兼容逻辑。本计划不把歌词渲染器改造成应用级 token 消费者；只在未来需要时提供明确的桥接层。歌词面板外壳的显示/隐藏可以另行迁移，但不能影响歌词时序和渲染器生命周期。

## 2. 调查快照

### 2.1 当前代码规模

本次以 2026-09-22 的工作树为调查基线，使用符号索引与源码搜索交叉确认：

| 项目 | 调查结果 | 解释 |
| --- | ---: | --- |
| `.animation(` 调用 | 54 处 | 包含值驱动动画和少量宽范围动画修饰器 |
| `withAnimation(` 调用 | 76 处 | 包含交互提交、状态切换和局部过渡 |
| 含动画相关调用的 Swift 文件 | 约 43 个 | 还不包含全部由子视图或 Core Animation 间接驱动的运动 |
| 直接 Core Animation 动画 | 至少 2 组显式调用 | 另有 `CADisplayLink`、`TimelineView` 和自定义关键帧逻辑 |
| 当前动画来源 | 多套并存 | `spring(response:dampingFraction:)`、`smooth`、`snappy`、`ease*`、`linear`、自定义 display-link |

这些数字是迁移前的搜索基线，不是最终验收指标。后续需要把每个调用点标记为“应迁移”“保留并说明”“属于歌词边界”或“重复/死代码”。

### 2.2 已存在的有价值基础

当前代码并非没有统一意识，已有几处可以直接成为 MotionKit 的接入点：

- `kmgccc_player/Utilities/FullscreenBottomControlsAnimationPolicy.swift` 已经集中处理全屏底部控件的几何动画 transaction、渲染隔离和 reduce-motion 分支。这说明动画所有权和渲染隔离应继续由策略层持有，而不是在每个叶子 view 里重新拼装。
- `kmgccc_player/Services/Animation/BackgroundAnimationClock.swift` 已经是共享的背景动画 cadence clock。它解决的是“什么时候更新”，不是“状态如何弹到目标值”；迁移时必须保留这条边界，不能把 cadence clock 错当成 spring token。
- `kmgccc_player/Views/Controls/AnimatedMediaControlButtons.swift` 已经是窗口与全屏共用的媒体控制按钮实现，但文件头部仍记录多组局部的按下、取消、退出和 handoff 参数。这是最适合验证 semantic token 的第一批组件。
- `kmgccc_player/Skins/NowPlaying/CapsuleSpectrumHostView.swift` 使用 `CADisplayLink` 和连续的阻尼振子跟随音频数据。它是一个需要统一物理语义、但不适合直接套 SwiftUI `.animation` 的高级适配案例。
- `kmgccc_player/Utilities/SlidingSelector.swift` 已经把拖拽中“不动画”和松手后“回弹”区分开来。它可以验证初速度、retarget 和 token 覆盖是否设计正确。

### 2.3 当前主要问题

当前问题不是“所有曲线都不自然”，而是运动语义分散：

1. 同一类控件在不同页面使用了不同的 `response`、`dampingFraction`、`easeInOut` 或 `snappy` 参数。
2. 物理参数和产品语义混在一起，调用点只能看到数字，看不出这是“按钮按下”还是“布局展开”。
3. SwiftUI 状态动画、Core Animation 图层动画和 display-link 自定义动画没有共同的定义或验证方式。
4. reduce-motion 逻辑有局部实现，容易出现某处仍然弹跳、某处直接消失、某处又使用另一套 timing curve 的不一致。
5. 交互动画的动态初速度、打断和重新目标化行为没有作为一等概念暴露；仅替换曲线名称不能解决拖拽松手或连续快速切换的手感问题。

## 3. MotionKit 的边界

### 3.1 MotionKit 负责什么

- 定义 `duration`、`bounce`、`blendDuration` 和可选物理参数。
- 提供 SwiftUI `Animation`/`Spring` 适配。
- 提供 Core Animation `CASpringAnimation` 适配。
- 为需要自己绘制每一帧的组件提供统一的 spring value/velocity 评估器。
- 提供语义化 motion token 和应用级 token 集合。
- 提供 reduce-motion、关闭动画和测试注入策略。
- 约束 retarget、初速度和动画完成回调的使用方式。
- 提供单元测试、跨后端一致性测试和可选的诊断信息。

### 3.2 MotionKit 不负责什么

- 不拥有播放状态、歌词状态、主题状态、窗口状态或业务状态。
- 不创建第二套 `PlaybackCoordinator`、`ThemeStore` 或歌词服务。
- 不修改 AMLL submodule、生成的 AMLL 资源或 MelismaKit 的歌词时序算法。
- 不把背景 cadence、频谱采样、跑马灯循环、音频 meter 和关键帧编排强行转换为 spring。
- 不用一个全局的隐式 `.animation` 包住整个 App。
- 不把每个视图的视觉特例都加入公共 token；公共 token 只表达稳定的交互语义。

## 4. 推荐架构

### 4.1 包的形态

`MotionKit` 应作为独立 Swift Package 维护，以便其他 macOS App 复用。当前 App 可以先通过本地 package 依赖迭代，API 稳定后再切换到版本化远程依赖；不建议把实现复制进 `kmgccc_player`，也不建议把它放到某个页面目录下伪装成局部工具。

建议的产品/target 划分：

```text
MotionKit
├── MotionKitCore        // Foundation；MotionSpec、tokens、policy、物理映射
├── MotionKitSwiftUI     // SwiftUI Animation、Environment、View modifier
├── MotionKitCoreAnimation // QuartzCore/CASpringAnimation 适配
├── MotionKitTests
└── MotionKitDemo        // 可选；展示 token、打断、reduce-motion 和后端一致性
```

如果初版只面向 macOS，可先把三个运行 target 合并为一个产品；但源码边界仍应保留，避免 SwiftUI 依赖渗入核心模型，也避免将 Core Animation 适配逻辑复制到每个 App。

### 4.2 数据流

```text
MotionTokens + MotionPolicy
          │
          ▼
      MotionSpec
          │
    ┌─────┼──────────────┐
    ▼     ▼              ▼
 SwiftUI  Core Animation  Display-link evaluator
 Animation CASpringAnimation Spring.value/velocity
```

同一个 `MotionSpec` 可以有多个后端，但每个后端不应各自重新解释产品参数。差异只能来自后端所需的表示形式，例如 SwiftUI 需要 `Animation`，图层需要 `CASpringAnimation`，手写渲染需要每帧的位移和速度。

### 4.3 应用接入位置

应用根部或组合根创建一份当前 `MotionTokens` 与 `MotionPolicy`，通过 SwiftUI environment 向下传递。长期服务仍由现有组合根管理；MotionKit 的 token 集合是 UI 配置，不应在叶子 view 中创建 singleton，也不应让 `ThemeStore` 兼任 motion owner。

建议的调用形式如下，代码仅表示目标 API 方向：

```swift
withAnimation(.motion(.control)) {
    isExpanded.toggle()
}

SomeView()
    .motionAnimation(.layout, value: isExpanded)

let animation = motion.tokens.gestureSettle.animation(initialVelocity: dragVelocity)
```

调用点只选择语义 token；只有真正需要特殊运动学的组件才可显式调用物理构造器，并且必须说明原因。

## 5. API 设计

### 5.1 `MotionSpec`：基础运动描述

建议把 `MotionSpec` 设计成 `Sendable`、`Hashable` 的值类型，至少包含：

```swift
public struct MotionSpec: Sendable, Hashable {
    public var duration: Double
    public var bounce: Double
    public var blendDuration: Double

    public init(
        duration: Double,
        bounce: Double = 0,
        blendDuration: Double = 0
    )

    public func animation(initialVelocity: Double = 0) -> Animation
    public func spring(initialVelocity: Double = 0) -> Spring
    public func coreAnimation(initialVelocity: Double = 0) -> CASpringAnimation
}
```

上面是目标形状，不是要求原样照抄的最终签名。实际实现需要以当前 macOS SDK 的可用 initializer 和 SwiftUI 类型签名为准，并用 availability wrapper 保护跨 App 的最低部署版本。

规则如下：

- `duration` 和 `bounce` 是默认的产品层入口。
- `blendDuration` 用于连续 retarget 时抑制跳变，不应被每个调用点随意填写。
- 初速度属于运行时输入，不属于静态 token；拖拽组件应把释放速度传给 `MotionSpec` 的解析方法。
- 物理构造器仍应保留，例如 `mass`、`stiffness`、`damping`、`allowOverDamping`，但只作为高级 API 或后端适配 API，普通 App 页面不直接使用。
- `settlingDuration` 只能用于诊断或测试，不用于业务层延迟、下一阶段排程或人为拼接动画。
- `bounce = 0` 的 token 必须用测试确认没有可见超调；不要把它重新实现成固定的 `easeInOut`。
- 共享 token 的 bounce 初始限制在保守范围内。超过约 `0.4` 的弹跳只能用于明确的强调动作，并需要视觉验收，不作为默认值扩散。

### 5.2 `MotionTokens`：语义层

第一版建议只保留少量稳定类别：

| Token | 语义 | 首批使用位置 |
| --- | --- | --- |
| `microInteraction` | 极短的状态反馈，不抢焦点 | 图标切换、轻量高亮、局部透明度 |
| `control` | 按钮、开关、选择器的普通状态变化 | 媒体按钮、音量、设置选择器 |
| `layout` | 同一容器内的尺寸、间距和展开收起 | MiniPlayer、工具条、面板 |
| `navigation` | 页面、侧栏、全屏层级变化 | 侧栏、全屏控制、页面切换 |
| `gestureSettle` | 拖拽、排序、滑块松手后的回到目标 | `SlidingSelector`、可重排行、拖拽控件 |
| `emphasis` | 用户明确触发的强调反馈 | 跳转、确认、特殊媒体操作 |
| `contentReplacement` | 内容替换但容器语义不变 | 数字文本、标签、封面内容替换 |
| `backgroundTransition` | 主题、封面和背景层的低频过渡 | 背景、模糊、渐变层 |

初始值只作为校准起点，不在没有用户路径验收前冻结。建议先从以下范围开始：

| Token | `duration` 建议范围 | `bounce` 建议范围 | 备注 |
| --- | ---: | ---: | --- |
| `microInteraction` | 0.14–0.20 | 0–0.03 | 通常不应明显回弹 |
| `control` | 0.24–0.36 | 0–0.08 | 先替换旧的短 `response` |
| `layout` | 0.38–0.56 | 0–0.12 | 重点观察快速连续切换 |
| `navigation` | 0.45–0.68 | 0–0.12 | 与窗口层级和遮挡关系一起验收 |
| `gestureSettle` | 0.30–0.50 | 0.06–0.20 | 初速度优先于静态 bounce |
| `emphasis` | 0.32–0.52 | 0.08–0.28 | 只用于确有强调意图的动作 |
| `contentReplacement` | 0.16–0.32 | 0–0.06 | 数字滚动和文字替换可能需要专用适配 |
| `backgroundTransition` | 0.50–0.85 | 0–0.08 | 不应拖慢交互反馈 |

### 5.3 三层覆盖规则

为了支持不同层级的参数 token，同时避免配置失控，最多保留三层：

1. **全局基础层**：`MotionTokens.default`，定义产品的基准手感。
2. **语义上下文层**：窗口、MiniPlayer、全屏、设置、资料库等 surface 可以对少量 token 做上下文覆盖。
3. **运行时层**：手势初速度、当前 reduce-motion policy、交互是否正在拖拽等动态输入。

组件特例不能再增加第四层“页面私有 token”。如果某个组件必须有独立参数，应先判断它是否已经形成新的语义类别；否则保留局部 override，并记录迁移原因和删除条件。

### 5.4 Motion policy

建议提供三种策略：

| Policy | 行为 |
| --- | --- |
| `full` | 使用完整弹簧和正常 token |
| `reduced` | 保留状态可理解性，但去除明显弹跳、缩短或改用淡入淡出 |
| `disabled` | 不执行隐式动画，状态直接到达目标 |

`reduced` 不是把所有代码都替换成 `.none`，也不是在每个调用点写一套新的 `.easeInOut`。策略应在 MotionKit adapter 层集中解析，调用点只表达语义。测试必须能够注入三种 policy，而不依赖真实系统设置。

## 6. 动画分类规则

迁移前先对每个调用点分类，禁止按搜索结果机械替换。

### A. 应迁移为标准 spring token

- 按钮按下、取消、选中和焦点状态。
- 选择器 knob、滑块、排序行松手后的 settle。
- 面板展开收起、工具栏布局变化、MiniPlayer 模式切换。
- 侧栏选中、全屏控制条显隐和布局重排。
- 主题/封面相关的离散状态切换，前提是它们不是持续采样或编排动画。

### B. 迁移到 token，但保留专用 content transition

- 数字时间文本。
- 标签、封面或播放信息的替换。
- 需要先清除旧值、再设置新值的两阶段状态变更。

这类场景可以使用 `contentReplacement` 或专用 modifier，不应因为“标准化”而强行制造文字弹跳。

### C. 保留时间/相位驱动模型

- `BackgroundAnimationClock` 的 cadence 和通道调度。
- `SeamlessMarqueeText` 的线性循环和 reset。
- `LedMeterView` 与频谱的持续采样。
- 粒子、着色器、旋转和连续背景漂移。
- 卡式皮肤中由关键帧表达的连续编排。

这些组件可以在后续使用 MotionKit 的时间源、policy 或物理 evaluator，但第一阶段不改为 SwiftUI 隐式 spring。

### D. 需要高级适配器

- `CapsuleSpectrumHostView` 的音频跟随阻尼振子。
- 需要 `CADisplayLink` 且必须保留每帧速度的组件。
- 使用 Core Animation layer tree、`CAKeyframeAnimation` 或多阶段完成回调的皮肤。

高级适配器的目标是让 Apple `Spring` 成为参考模型，而不是简单把每个 `response` 数字改写成 `duration`。

### E. 歌词边界

- MelismaKit/NativeLyrics 的位置、resize、seek、活动行和歌词背景动画不纳入本轮 MotionKit token 迁移。
- `LyricsPanelView` 中属于队列、面板或外壳的状态动画可以在普通页面迁移完成后单独处理。
- 任何涉及歌词时钟、显示链路、seek 后 wake-up、活动行提前量或 AMLL 配置映射的改动，都必须走歌词专项验收，不能作为普通 MotionKit 清理顺手修改。

## 7. 迁移优先级与文件范围

### 7.1 P0：公共控件和动画策略

这一批先验证 API 是否正确，范围小但能覆盖多数交互类型：

| 区域 | 代表文件 | 迁移动作 |
| --- | --- | --- |
| 媒体按钮 | `kmgccc_player/Views/Controls/AnimatedMediaControlButtons.swift` | 将按下、取消、退出、handoff、skip 的局部数字改为 `control`/`emphasis`/`microInteraction` token；保留手势生命周期和共享 owner |
| 音量 | `kmgccc_player/Views/Controls/ExpandableVolumeControl.swift` | 将旧 `response/dampingFraction` 与 reduce-motion 分支接入 token policy |
| 选择器 | `kmgccc_player/Utilities/SlidingSelector.swift` | API 从传入裸 `Animation` 逐步改为传入 `MotionSpec` 或 token；拖拽中保持无动画，松手传动态初速度 |
| 设置选择器 | `CapsulePicker.swift`、`SettingsTabSelector.swift`、`AppearanceSettingsView.swift` | 统一选中态、knob 和 tab indicator 的 control/layout 语义 |
| 工具条 | `GlassToolbarControls.swift` | 将 `.snappy` 作为过渡适配，不继续新增页面私有 snappy 数值 |
| 全屏策略 | `FullscreenBottomControlsAnimationPolicy.swift` | 保留 transaction/渲染隔离 owner，只把 animation 来源切换到 MotionKit |

**P0 退出条件**：同一 token 在 SwiftUI 调用点可用；reduce-motion 可注入；按钮和选择器的快速连续触发不会出现明显跳帧或错误完成回调；现有 transaction 隔离行为不改变。

### 7.2 P1：主播放路径和窗口层级

| 区域 | 代表文件 | 迁移动作 |
| --- | --- | --- |
| MiniPlayer | `kmgccc_player/Views/MiniPlayer/MiniPlayerView.swift` | 统一播放模式展开、布局变化和提交动作；避免在大容器上添加无界 `.animation` |
| 全屏播放器 | `kmgccc_player/Views/Fullscreen/FullscreenPlayerView.swift` | 将详情阅读器、面板值变化和底部控件接入 `layout`/`navigation`；保留两阶段状态提交 |
| 全屏 MiniPlayer | `kmgccc_player/Views/Fullscreen/FullscreenMiniPlayerView.swift` | 区分布局动画与歌词刷新外壳动画；歌词渲染器本身不动 |
| 封面与背景皮肤 | `kmgccc_player/Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift`、`CoverGradientBlurBackgroundView.swift` | 先把离散状态切换换成 `backgroundTransition`，再单独验收模糊上升、封面 crossfade 和背景层级 |
| 侧栏与导航 | `kmgccc_player/Views/Sidebar/SidebarView.swift`、`UIStateViewModel.swift` | 统一选中、显示/隐藏和导航状态动画；确认 owner 后再改，不从叶子 view 反向抢状态 |

**P1 退出条件**：MiniPlayer 展开、窗口全屏、底部控制显隐、侧栏切换和快速重复操作在真实 App 路径下可用；没有把 lyrics surface 的时钟或显示生命周期带入窗口动画 transaction。

### 7.3 P2：设置、资料库、弹窗和共享内容过渡

候选范围包括：

- `kmgccc_player/Views/Settings/` 下的设置页选择器、预览卡、标题和状态变化。
- `kmgccc_player/Views/Library/` 下的重排、多选、列表高亮、封面/标题切换和滚动边缘提示。
- `kmgccc_player/Utilities/AppDialogComponents.swift` 与 `DuplicateImportDialog.swift` 的弹窗过渡。
- `kmgccc_player/Views/Home/` 的卡片、洞察、播放列表和主页层级变化。
- `kmgccc_player/Utilities/NumericTimeText.swift` 的数字内容过渡。

当前工作树已经有 Home、AppKit、歌词和频谱相关未提交修改。P2 开始前必须逐文件确认这些 diff 的 owner；在此之前不得把当前 dirty 文件当作可安全重写的迁移目标。特别是 Home 相关文件和 `CapsuleSpectrumHostView.swift` 应先完成现有任务交接，再进入批量迁移。

**P2 退出条件**：共享控件迁移后，设置、资料库、弹窗和主页只消费语义 token；剩余裸动画调用都有明确的保留理由或已进入下一批。

### 7.4 P3：高级后端和显式保留项

这一批不以“替换成功数量”为目标，而以跨后端一致性和性能为目标：

- 为 `CapsuleSpectrumHostView` 增加 MotionKit evaluator 试验分支，比较现有音频跟随振子与 Apple `Spring.value/velocity` 的响应、能量衰减和掉帧情况；没有 A/B 证据不切换生产路径。
- 检查 `KmgcccCassetteSkin.swift` 的 `CABasicAnimation`/`CAKeyframeAnimation`，把真正的状态 settle 与连续编排分开；只迁移前者。
- 给必要的 Core Animation layer 动画提供 `MotionSpec` 到 `CASpringAnimation` 的转换，并验证 fill mode、removed-on-completion、delegate 完成时机和 retarget 行为。
- 保留 `BackgroundAnimationClock`、跑马灯、meter 和频谱的连续更新模型；只把 policy、时间源或物理参数的公共部分接入 MotionKit。

**P3 退出条件**：高级组件有明确的 backend 选择和性能证据，不存在“SwiftUI 版本看起来统一但实际破坏 120 Hz 或音频跟随”的替换。

## 8. 实施阶段与门禁

### Phase 0：冻结调查基线

1. 保存当前 `git status --short` 与各 dirty diff 的 owner，尤其是 Home、歌词、AppKit 和频谱文件。
2. 给每个动画调用点增加分类记录：迁移、保留、歌词边界、待确认。
3. 确认部署目标、Swift 工具链和可用的 `Spring`/`CASpringAnimation` initializer。
4. 确认 P0 的 token 名称、policy 行为和 MotionSpec 最小 API。
5. 为 P0 录制或记录可重复的交互基线，不以“编译通过”代替手感验收。

**门禁**：没有覆盖现有 dirty diff；没有把歌词 renderer 纳入普通 UI 动画范围；API 评审完成后才创建 package 源文件。

### Phase 1：建立 MotionKit package

1. 创建独立 package 的 core、SwiftUI、Core Animation 和测试 target。
2. 实现 `MotionSpec`、token 集合、policy 和三个后端 adapter。
3. 为 `bounce = 0`、正常 bounce、负/过阻尼边界、初速度、retarget 和 `blendDuration` 建立单元测试。
4. 建立一个最小 Demo：按钮按下、面板展开、拖拽松手、连续 retarget、reduce-motion。
5. 确认 package 不引用播放器业务模块、歌词模块或主题服务。

**门禁**：package 独立测试通过；SwiftUI、Core Animation 和 display-link 的基础输出符合预期；API 尚未绑定任何具体页面名称。

### Phase 2：接入应用级 policy 与 token environment

1. 在应用根部注入 `MotionTokens` 和 `MotionPolicy`。
2. 把系统 reduce-motion 状态映射到 policy；测试中可手动注入。
3. 将 `FullscreenBottomControlsAnimationPolicy` 改为消费 token，但保持它对 transaction 和渲染隔离的所有权。
4. 增加最小的诊断信息：token 名称、policy、后端和是否有动态初速度；不打印高频逐帧日志。

**门禁**：未迁移页面行为不变；全局 policy 不会让整个 view tree 产生无界隐式动画；日志不会污染正常播放。

### Phase 3：迁移公共控件

按 P0 顺序逐个组件迁移，每完成一个组件就做编译、局部测试和手动交互验收。禁止一次提交覆盖所有页面，避免无法定位视觉回归。

**门禁**：每个公共控件只有一个 token 入口；裸物理参数只存在于 MotionKit 或有记录的 adapter；连续快速操作和拖拽取消路径通过。

### Phase 4：迁移主播放路径

迁移 MiniPlayer、全屏控制、侧栏和封面背景。每个 surface 先确认 transaction owner，再替换曲线来源。涉及两阶段状态的地方，先保留状态机和 transaction 结构，只替换动画定义。

**门禁**：主窗口、全屏、MiniPlayer 三条路径分别验收；无第二套状态 owner；歌词渲染时钟没有被普通 UI transaction 改变。

### Phase 5：迁移设置、资料库、主页和弹窗

这一步主要清理重复的 `.ease*`、`.snappy` 和旧 spring recipe。主页必须在当前 dirty 修改完成审查后再迁移；不要用 MotionKit 改动掩盖主页状态刷新、性能或布局问题。

**门禁**：共享组件和各页面使用一致 token；保留项都有注释/清单记录；UI 一致性检查通过。

### Phase 6：高级后端、性能与收口

1. 评估频谱、meter、背景时钟和 cassette 的适配收益。
2. 删除已迁移调用点的局部参数和兼容 wrapper。
3. 增加静态检查，阻止新增裸 `Animation.spring(response:dampingFraction:)`、未标注的 `ease*` 和无理由的宽范围 `.animation`。
4. 对保留的连续动画建立 allowlist，避免静态检查逼迫错误迁移。

**门禁**：静态检查通过；关键路径没有性能回归；MotionKit 可以被另一 个 macOS App 以相同 API 接入。

## 9. 测试与验收矩阵

### 9.1 MotionKit 单元测试

- `duration`/`bounce` 到 SwiftUI `Spring` 的构造结果稳定。
- `bounce = 0` 在目标附近无可见超调，且不同初速度下仍能正确收敛。
- 动态初速度方向正确，正向和反向 retarget 不发生速度丢失。
- `blendDuration` 不会造成目标跳变或无限延迟。
- SwiftUI、Core Animation 和 display-link evaluator 在相同输入下的峰值、收敛趋势和最终值一致到可接受误差。
- `full`、`reduced`、`disabled` 三种 policy 的结果可预测。
- token 集合是值语义，surface override 不会污染全局默认值。

### 9.2 App 行为测试

至少覆盖以下真实路径：

| 场景 | 验收重点 |
| --- | --- |
| 媒体按钮按下、取消、连续点击 | 按下即时、取消不残留缩放、连续触发不堆积完成回调 |
| MiniPlayer 展开/收起 | 布局连续、快速反向没有跳变、内容 owner 不变化 |
| 全屏底部控制显隐 | transaction 隔离保持、控件与背景不互相拖动 |
| 音量和选择器拖拽 | 拖拽中不被隐式动画追赶，松手按速度自然 settle |
| 列表重排、多选、侧栏 | 选中/重排/取消路径使用同一语义，状态不丢失 |
| 封面与主题切换 | 背景过渡不阻塞操作，不把低频背景动画变成输入延迟 |
| 数字时间与内容替换 | 不出现错误的弹跳、闪烁或文字重叠 |
| reduce-motion | 仍能看清状态变化，不保留明显弹簧超调 |
| 窗口 resize、全屏切换、播放继续 | 不改变播放、歌词时钟、频谱服务和窗口生命周期 |

### 9.3 性能与人工验收

- 不把 `.animation` 放在大范围根 view 上，用值驱动和局部 transaction 限制失效范围。
- 主播放路径至少检查交互期间的 hitch、渲染延迟、CPU/GPU 变化和内存，不以平均 FPS 或空闲 trace 代替验证。
- 频谱和 meter 保持现有实时更新边界；MotionKit 试验不能引入第二个 audio tap 或第二个 display-link owner。
- 真实 App 验收仍遵守进程检查规则：先确认当前 `kmgccc_player` PID、启动时间和实际二进制，再启动或交互；不能用 Demo 代替主 App。
- 每一批迁移都保留回退点，视觉回归时只回退该批 token/adapter，不回退无关的业务修改。

## 10. 静态检查和长期治理

迁移完成后建议增加一个轻量的 `check-motion-consistency` 检查，但不要在第一批就把它接入最严格的发布门禁。检查分三类：

1. **禁止新增**：业务代码新增裸 `response`、`dampingFraction`、未经说明的 `ease*`、宽范围 `.animation`。
2. **允许但需登记**：`linear` 跑马灯、TimelineView、频谱/meter、CA keyframe、背景 cadence 和歌词边界。
3. **必须走 token**：按钮、选择器、布局展开、导航、面板显隐、拖拽 settle 和普通内容替换。

检查脚本应输出文件、调用点、分类和建议 token，而不是只返回一个模糊的失败状态。初期以报告模式运行，确认误报范围后再切换到阻断模式。

## 11. 风险与处理方式

| 风险 | 处理 |
| --- | --- |
| 把 `duration` 当作精确结束时间 | 不用 `settlingDuration` 链接业务逻辑；用显式状态机或 completion 语义处理阶段关系 |
| 统一 token 后交互反而变慢 | 保持 `control` 与 `layout` 分开；先做主路径 A/B，不盲目提高 duration |
| 旧 `response/dampingFraction` 与新 `duration/bounce` 感受不等价 | 先按语义重新校准，不做机械数值换算；保留对照 Demo |
| 初速度被静态 token 覆盖 | token 只给基础曲线，手势 release 传入运行时 velocity |
| Core Animation 与 SwiftUI 结果不一致 | 共享 `MotionSpec`，加入跨后端测试；必要时以 `Spring.value/velocity` 作为参考 oracle |
| reduce-motion 在不同页面表现不同 | policy 在 adapter 层集中解析，页面不再自定义第二套分支 |
| 改动混入现有 dirty 工作 | Phase 0 逐文件记录 diff；每批只改已确认 owner 的文件 |
| 把歌词 renderer 误迁移 | 明确 package/host 边界；歌词专项变更必须单独立项和验收 |
| 性能优化变成性能回归 | 连续动画保留原模型；先采样真实播放交互，再决定是否换 evaluator |

## 12. Definition of Done

当以下条件全部满足，才认为“歌词外动画已完成标准化”：

1. MotionKit 作为独立 package 存在，具备 SwiftUI、Core Animation 和 display-link 所需的公共适配能力。
2. 应用通过统一的 `MotionTokens` 与 `MotionPolicy` 提供语义动画，页面不再直接散落默认物理数字。
3. 公共控件、MiniPlayer、全屏控制、侧栏、设置和主要资料库交互均完成 P0–P2 迁移或有明确保留记录。
4. 连续时间驱动动画、歌词 renderer 和高级皮肤动画不会被错误地替换成隐式 spring。
5. reduce-motion、快速反向、拖拽初速度、窗口 resize 和真实播放路径均通过验收。
6. 静态检查能区分“必须迁移”和“有意保留”，后续新增动画不会重新回到无语义的局部常量。
7. 另一个 macOS App 可以只依赖 MotionKit 的公开 API，复用相同的 token 和 policy，而不依赖播放器业务模块。

## 13. 第一批实际落地顺序

建议下一次实施按以下顺序开始，不要先修改所有调用点：

1. 建立独立 MotionKit package 的最小 API、policy 和测试。
2. 先接入 `FullscreenBottomControlsAnimationPolicy`，验证 transaction 所有权不变。
3. 迁移 `AnimatedMediaControlButtons`、`ExpandableVolumeControl` 和 `SlidingSelector`。
4. 用这三个组件校准 `control`、`gestureSettle`、`microInteraction` 的初始值。
5. 再进入 MiniPlayer 与全屏主路径。
6. 完成一批真实交互验收后，才扩大到设置、资料库和主页。

本计划本身不修改现有动画实现，也不要求本次构建或启动 App；下一阶段应先按 Phase 0 记录当前工作树，再创建 MotionKit 的第一批源文件。
