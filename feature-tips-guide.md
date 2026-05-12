# Feature Tips 实现指南

本文档描述 App 内"新功能提示 Tip"的通用实现模式，供后续新增 Feature Tip 时参考。

## 架构概览

Feature Tip 系统分为两层：

- **下层：`AppVersionGate`** — 通用门控逻辑，管理版本升级检测、dismiss 状态、显示次数上限。位于 `myPlayer2/Services/FeatureTips/AppVersionGate.swift`。
- **上层：具体 Tip 的 UI 呈现** — 在合适的时机（通常是用户触发相关功能时），通过 `NSPopover`（AppKit 场景）或 SwiftUI `.overlay`（SwiftUI 场景）弹出提示。位于各自的功能模块中。

依赖的版本号工具：`myPlayer2/Utilities/AppVersion.swift`（`AppVersion` 结构体，支持 `major.minor.patch` 解析与比较）。

## AppVersionGate 门控 API

`AppVersionGate` 是单例 (`AppVersionGate.shared`)，底层使用 `UserDefaults` 持久化。

### 核心判断方法

```swift
func shouldShowFeatureTip(
    featureKey: String,
    introducedVersion: AppVersion,
    maxDisplayCount: Int = 4
) -> Bool
```

三个条件**全部满足**才返回 `true`：

1. 该 Tip 未被用户永久关闭（`isFeatureTipDismissed == false`）
2. 已显示次数未达上限（`featureTipDisplayCount < maxDisplayCount`）
3. 用户是从低于 `introducedVersion` 的版本升级上来的；如果缺少 `previousInstalledVersion`，按“很旧版本”处理，允许新版提示正常显示

### 状态记录方法

```swift
// 是否已被永久关闭
func isFeatureTipDismissed(featureKey: String) -> Bool
func markFeatureTipDismissed(featureKey: String)

// 已显示次数
func featureTipDisplayCount(featureKey: String) -> Int
func recordFeatureTipDisplayed(featureKey: String)

// 版本升级检测
func wasUpgradedFromVersionBelow(_ version: AppVersion) -> Bool
```

### 启动时调用

在 `AppSessionHost` 或 `App` 入口处调用 `AppVersionGate.shared.recordCurrentAppLaunch()`，它负责维护 `previousInstalledVersion` / `latestInstalledVersion` 的迁移状态。

兼容要求：如果用户本地没有 `previousInstalledVersion`（常见于旧版本首次升级到带门控系统的新版本，或旧数据迁移不完整），不要把它视为“没有升级”。相关门控应把缺失的 previous version 当作低于所有已知 introduced version 的旧版本处理，确保 Feature Tip、What's New 和更新提示不会因为历史字段缺失而全部失效。

### UserDefaults Key 约定

- Dismiss 标记：`kmgccc_player.dismissedFeatureTip.<featureKey>`
- 显示次数：`kmgccc_player.featureTipDisplayCount.<featureKey>`
- 上次安装版本：`kmgccc_player.previousInstalledVersion`
- 当前已记录版本：`kmgccc_player.latestInstalledVersion`

## Tip 关闭行为的两种模式

### 模式 A：多次显示（推荐）

适用于用户可能无意中关掉、需要多次提醒的场景。

- ✕ 按钮仅**临时关闭**当前 Tip，不调用 `markFeatureTipDismissed`
- 用户下次触发条件时（如重新进入全屏），Tip 会再次出现
- 通过 `maxDisplayCount` 控制最多显示次数，达到上限后自动不再显示
- 用户不会因为误触而永久错过提示

```swift
// 关闭回调：仅隐藏，不永久 dismiss
private func dismissTip() {
    showTip = false
}
```

### 模式 B：一次关闭永久不再显示

适用于用户明确不需要该提示的场景。

- ✕ 按钮调用 `markFeatureTipDismissed` 永久关闭
- 一旦关闭，即使 `maxDisplayCount` 未达上限也不会再出现
- 适合操作提示明确、用户一旦理解就不再需要的功能

```swift
// 关闭回调：永久 dismiss
private func dismissTip() {
    showTip = false
    AppVersionGate.shared.markFeatureTipDismissed(
        featureKey: FeatureTips.myFeatureKey
    )
}
```

### 配置建议

| 场景 | 推荐模式 | 推荐 maxDisplayCount |
|------|---------|---------------------|
| 隐藏式交互（如再次点击、Shift+选） | 模式 A | 2–4 |
| 一次性操作引导 | 模式 A | 1–2 |
| 重要提示/警告 | 模式 B | 1 |

## 新增一个 Feature Tip 的步骤

### 步骤 1：定义 Tip 配置

在目标模块中定义一个私有枚举（或常量），包含三个必要参数：

```swift
private enum FeatureTips {
    static let myFeatureKey = "<命名空间>.<功能标识>"       // UserDefaults key
    static let myFeatureIntroducedVersion = AppVersion(major: X, minor: Y, patch: Z)
    static let myFeatureMaxDisplayCount = 3               // 最多显示次数
}
```

命名建议：`<模块>.<功能>`，如 `playlist.shiftRangeSelection`、`fullscreen.playbackModeRetap`。

### 步骤 2：选择触发时机

在用户触发相关功能时调用显示逻辑：

```swift
// 触发时机示例：
// - 进入某个模式时（如进入多选模式、进入全屏）
// - 首次交互某个控件时
// - 某个面板第一次出现时

func handleEnterMode() {
    // ... 功能本身的逻辑 ...
    showMyFeatureTipIfNeeded()
}
```

### 步骤 3：实现 Tip 显示方法

**AppKit 场景**（有 NSView 锚点可用）：

```swift
private var myFeatureTipPopover: NSPopover?

private func showMyFeatureTipIfNeeded() {
    // 1. 防止重复弹出
    guard myFeatureTipPopover?.isShown != true else { return }
    
    // 2. 门控检查
    guard AppVersionGate.shared.shouldShowFeatureTip(
        featureKey: FeatureTips.myFeatureKey,
        introducedVersion: FeatureTips.myFeatureIntroducedVersion,
        maxDisplayCount: FeatureTips.myFeatureMaxDisplayCount
    ) else { return }
    
    // 3. 找到锚点视图
    guard let anchorView = someAnchorView else { return }
    
    // 4. 创建 NSPopover
    let popover = NSPopover()
    popover.behavior = .semitransient   // 点击外部自动关闭
    popover.animates = true
    popover.contentSize = NSSize(width: 288, height: 118)
    popover.contentViewController = NSHostingController(
        rootView: MyFeatureTipView { [weak self] in
            // 关闭回调：根据模式选择是否永久 dismiss
            self?.featureTipPopover?.performClose(nil)
            self?.featureTipPopover = nil
        }
    )
    
    // 5. 显示并记录
    myFeatureTipPopover = popover
    popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .minY)
    AppVersionGate.shared.recordFeatureTipDisplayed(
        featureKey: FeatureTips.myFeatureKey
    )
}
```

**SwiftUI 场景**（无 NSView 锚点，用 overlay）：

```swift
@State private var showMyFeatureTip = false

private func showMyFeatureTipIfNeeded() {
    guard showMyFeatureTip == false else { return }
    guard AppVersionGate.shared.shouldShowFeatureTip(
        featureKey: FeatureTips.myFeatureKey,
        introducedVersion: FeatureTips.myFeatureIntroducedVersion,
        maxDisplayCount: FeatureTips.myFeatureMaxDisplayCount
    ) else { return }
    
    withAnimation {
        showMyFeatureTip = true
    }
    AppVersionGate.shared.recordFeatureTipDisplayed(
        featureKey: FeatureTips.myFeatureKey
    )
}

// 在目标视图上添加 overlay
SomeTargetView()
    .overlay(alignment: .top) {
        if showMyFeatureTip {
            MyFeatureTipView(onClose: dismissMyFeatureTip)
                .offset(y: -12)
        }
    }
```

重要：overlay 应加在目标视图的**外部**（父视图侧），而非目标视图内部，以避免被目标视图的 clipShape / 圆角遮罩裁切。

### 步骤 4：编写 Tip UI（SwiftUI View）

```swift
private struct MyFeatureTipView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("功能标题")
                    .font(.headline)
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭")
            }

            Text("功能说明文字，一句话解释这个功能的用途")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 288, alignment: .leading)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }
}
```

布局约定：
- 标题 + 关闭按钮 (✕) 在同一行
- 说明文字使用 `.callout` + `.secondary` 颜色
- 固定宽度 288pt，高度自适应
- 关闭按钮 22×22，`.buttonStyle(.plain)`
- 使用 `.regularMaterial` 背景 + 圆角 + 阴影，确保在任何背景下可读

### 步骤 5：管理生命周期

```swift
private func dismissMyFeatureTip() {
    // 模式 A（多次显示）：仅隐藏
    withAnimation {
        showMyFeatureTip = false
    }
    
    // 模式 B（永久关闭）：解除下面注释
    // AppVersionGate.shared.markFeatureTipDismissed(
    //     featureKey: FeatureTips.myFeatureKey
    // )
}
```

SwiftUI 场景中需要关闭 Tip 的典型时机：
- 用户点击关闭按钮
- 用户退出当前模式 / 关闭相关面板
- 视图 disappear 时

AppKit NSPopover 场景中：
- `.semitransient` 行为会自动在点击外部时关闭
- 模式退出时调用 `closeFeatureTipPopover()` 清理

## NSPopover 行为选择

| `behavior` | 点击外部 | 切换 App | 适用场景 |
|------------|---------|---------|---------|
| `.semitransient` | 自动关闭 | 保持显示 | 大多数 Feature Tip（推荐） |
| `.transient` | 自动关闭 | 自动关闭 | 需要极短暂存在的提示 |
| `.applicationDefined` | 不自动关闭 | 不自动关闭 | 需要用户必须点击关闭按钮的场景 |

推荐使用 `.semitransient`：用户点击其他地方时 Tip 自然消失，不会造成阻塞感；同时切换 App 回来时 Tip 仍在，不会丢失上下文。

## 参考实现

| Tip | 文件 | 模式 | 场景 |
|-----|------|------|------|
| Shift 连续选择 | `myPlayer2/AppKit/AppKitMainToolbarController.swift` | NSPopover + 模式 B | AppKit 工具栏按钮 |
| 播放队列展开 | `myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift` | overlay + 模式 A | SwiftUI 全屏覆盖层 |
| v2.0 设置面板资料库 | `myPlayer2/Views/Settings/SettingsView.swift` | overlay + 模式 A | SwiftUI 设置窗口 |
| 外部音乐 App 播放 | `myPlayer2/AppKit/AppKitMainSplitWindowController.swift` | NSPopover + 模式 A | AppKit 窗口控制器，锚定 sidebar 播放来源滑块 |

**外部音乐 App 播放 Tip 特别说明**：anchor view 在 sidebar 内部（`SlidingSelector`），但 NSPopover 挂载在窗口控制器层级，不嵌入 sidebar。popover 通过 subview walk 找到 sidebar 内 NSHostingView 作为锚点，`preferredEdge: .maxX` 使弹窗出现在 sidebar 右侧，避免被 sidebar 裁剪。触发时机为窗口首次 visible 后延迟尝试，有递增重试逻辑应对 layout 未就绪的情况。

搜索关键词：`FeatureTips`、`showShiftRangeSelectionTipIfNeeded`、`showPlaybackModeRetapTipIfNeeded`、`externalPlaybackTipPopover`。
