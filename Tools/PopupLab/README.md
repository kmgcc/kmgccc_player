# Popup Lab

独立的 macOS 26 SwiftUI 弹窗样式实验室。包内包含可复用的 `PopupKit` library 和 `PopupLab`
executable。依赖仅有系统框架，示例使用虚构内容。

## 启动

在本目录执行：

```sh
./script/build_and_run.sh
```

脚本编译 Debug demo，生成 `dist/PopupLab.app` 并打开。构建目录、进程与 bundle ID 均属于
PopupLab；主播放器的 Xcode 工程和资料库不参与。需要 macOS 26 与相应 Xcode SDK。
也可以在 Xcode 打开本目录的 `Package.swift`，选择 PopupLab scheme。

若将本目录单独作为 Codex 项目打开，Run 动作使用同一脚本。`--debug`、`--logs`、
`--telemetry`、`--verify` 分别提供调试、日志和进程检查入口；进程检查不代表界面验收。

## 调整

- 左侧选择短确认、编辑表单、任务进度、阅读面板或轻量选择。
- 右侧调整宽度、圆角、内边距、区域间距、字号、按钮高度、材质和强调色。
  默认“玻璃”使用原生 Liquid Glass；“清透玻璃”使用 clear glass，另有磨砂和实色。
  切换素色、色彩或明暗背景，观察玻璃对底层内容的折射。
- 切换浅深色、长文案和禁用操作。任务状态与进度由右侧控制，取消操作切换为取消中。
- 按钮独立支持玻璃、清透玻璃和实色。相邻按钮由 `PopupActionGroup` 集中渲染；
  按钮字号、最小高度、最小宽度和间距可调整。按钮组的上、下、左、右外边距独立
  调整，可选择靠左、居中或靠右；右上角关闭按钮独立控制距上边缘、右边缘的距离
  与尺寸。外边距作用于整块按钮。
- 阅读与任务列表使用 `PopupScrollRegion`：上下沿按滚动距离淡出，在开头或末尾
  逐渐恢复对应边缘的不透明度；内容全部可见时，上下沿保持清晰。
- 悬浮按钮贴近右下角，内容可延伸到其左侧及后方。按钮周围增加柔和遮罩，最低
  不透明度默认 36%；可调整范围、最低不透明度与按钮组外边距。末尾留出滚动余量，让最后
  一行能够避开按钮。关闭“悬浮按钮”可比较普通页脚布局。
- 下方打开实际 sheet、浮动 NSPanel、锚点 popover 和系统 Alert。前三者使用同一
  `LabSampleView` / `PopupKit`；Popover 固定展示轻量选择，系统 Alert 用于外观对照。
- 浮动面板打开后，可继续调整右侧参数。sheet 具有原生模态行为，关闭后再调整参数。
- 导出 JSON 预设或复制 Swift 参数；JSON 可以重新导入。新会话默认使用定稿样式：宽 510、圆角 15、内容边距 24、
  标题 18、按钮 14、边缘淡出 9、局部遮罩范围 8；按钮组外边距上下 13、左右 14。
  完整定稿保存在 `Presets/Standard.json`，与 `PopupStyle` 的存储属性默认值一致。

调节区按按钮、右上角关闭按钮、滚动与操作区、布局、文字与标题、列表分组，共有
36 项界面调节与 37 项可导出的样式参数（预设保留按钮原有内部左右留白）；外观、强调色、背景和样例状态另行调节。旧版 JSON 预设仍可导入，新参数采用
默认值。旧版的内容边距与悬浮内缩会转换成外边距。新会话先展示长文阅读样例，便于直接检查滚动与悬浮按钮。

标题图标与大标题、副标题第一行的实际字形中心对齐，副标题续行不改变图标位置。底部已有取消或关闭时，
隐藏右上角叉，避免重复退出入口。进行中和取消中的任务由状态控制。实验室自身工具按钮保持固定样式。

普通页脚的上外边距控制与正文的间隔；悬浮时上边距限制按钮进入内容区顶部。左、右
外边距界定按钮可用区域；靠左按左边距定位，靠右按右边距定位，居中在区域内居中。
下边距在两种布局中均从弹窗底边计算。

画布保留样例以方便连续调整；实际容器内的关闭按钮会关闭容器。画布不注册 Return / Esc，
避免触发后台样例。实际容器中，普通主要操作支持 Return、取消和关闭支持 Esc，破坏性
操作由明确点击触发。进行中和取消中的任务保留面板，完成或失败后允许关闭。

## 组件边界

| 文件 | 职责 |
| --- | --- |
| `Sources/PopupKit/PopupStyle.swift` | 可导出的布局参数 |
| `Sources/PopupKit/PopupEnvironment.swift` | 宿主注入语义色与参数 |
| `Sources/PopupKit/PopupSurface.swift` | 单层 Liquid Glass / 磨砂 / 实色；减少透明度时使用实色 |
| `Sources/PopupKit/PopupFrame.swift` | 页眉、内容、页脚；分隔线由骨架唯一管理 |
| `Sources/PopupKit/PopupHeader.swift` | 可复用标题、accessory 与玻璃关闭按钮 |
| `Sources/PopupKit/PopupHeaderLayout.swift` | 标题与副标题首行字形测量、图标对齐与关闭按钮外侧位置 |
| `Sources/PopupKit/PopupAction.swift` | 胶囊按钮与显式键盘策略 |
| `Sources/PopupKit/PopupScrollRegion.swift` | 滚动距离、边缘淡出、按钮局部遮罩与紧凑悬浮操作区 |
| `Sources/PopupLab/Support/LabPanelPresenter.swift` | demo 的 NSPanel 生命周期 |

组件默认采用一层材质、轻量图标和颜色层级。宽度由宿主设置，内容可使用任意 View；
大编辑器保留自己的多栏布局，阅读内容和长任务列表在内容区域滚动。页脚可在内容区
中悬浮，或继续使用独立区域。按钮周围的遮罩只影响滚动内容，按钮保持可见和可点击。
Popover 和 sheet 的外部轮廓、箭头及系统窗口阴影属于 macOS 容器。

## 接入播放器

播放器的 Xcode 工程现已将此包作为本地 Swift Package 引入，只依赖 **PopupKit product**。
PopupLab executable、示例状态与面板 presenter 留在 demo 内，主 App 与实验室使用同一份渲染源码。

`AppPopupFrame` 与既有 `AppDialogFrame` / `AppDialogHeader` / `AppDialogFooter`、按钮现为薄适配层。
适配层从唯一的 ThemeStore / SemanticPalette 读取前景、强调色和表面色，构造
`PopupPalette`。独立实验室仍可单独编译与调参。定稿参数更新需同步 `PopupStyle` 默认值与 Standard.json；
App 不读取用户下载目录中的文件。

播放器仅将此处的按钮标准用于窗口右下角操作组和右上角关闭按钮。内容中的查找、导入、
删除等工具保持各自的紧凑字号与中性底面，危险操作仅显示红字；全屏 quick panel 保留原有
嵌入设置布局，材质与明暗状态同步 MiniPlayer。

```swift
PopupFrame(title: "新建播放列表", systemImage: "square.and.pencil") {
    existingEditorContent
} footer: {
    HStack(spacing: 8) {
        PopupAction("取消", shortcut: .cancelAction, action: dismiss)
        PopupAction("创建", kind: .primary, shortcut: .defaultAction, action: save)
            .disabled(!canSave)
    }
}
.frame(width: popupStyle.width)
.popupAppearance(style: popupStyle, palette: paletteFromThemeStore)
```

上述内容、保存与关闭回调由现有业务 owner 提供。确认与表单优先使用已有 sheet 宿主；
长任务保留需要的浮动面板；全屏内嵌面板继续由原有全屏路由和关闭协调器管理。
已按语义覆盖任务、表单、阅读、编辑工作台和提示；本地与外部编辑器继续共享 `TrackInfoEditorCore`。
完整分类、组件规则和真实流程验收矩阵见 [弹窗标准](../../docs/popup-standards.md)。

## 验收

源码交付阶段不自动编译或启动。以下需要在运行 demo 后检查：

| 场景 | 检查 |
| --- | --- |
| 短确认 | 长标题换行、禁用态、Esc 取消、Return 不触发删除 |
| 表单 | Tab 焦点、空白名称禁用、Return 创建、Esc 关闭 |
| 任务 | 进行中、取消中、完成、失败；忙碌时关闭行为；长列表首/中/尾淡出 |
| 阅读 | 长文首/中/尾、短文完全可见；上下沿恢复；局部遮罩、标题固定、关闭始终可见 |
| Popover | 锚点和箭头、选中态、点击外部关闭、重新打开 |
| 外观 | 浅深色、玻璃/清透玻璃/磨砂/轻磨砂/实色、三种背景、系统减少透明度、高对比度下可读性 |
| 参数 | 按钮组四边外边距与对齐、关闭按钮上/右边距；玻璃按钮与实色切换；悬浮/普通页脚；打开浮动面板后调整样式；新版/旧版 JSON、Swift 参数与画布一致 |

demo 的通过只说明组件与演示宿主可用。App 接入后仍需检查主窗口、系统全屏、模拟全屏、
全屏内嵌、MiniPlayer 与原有业务取消/保存路径。
