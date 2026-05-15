# 更新弹窗 & 新功能公告 维护指南

本文档说明每次发布新版本时，开发者需要改哪些文件、改哪些值，才能让远程更新弹窗、What's New 公告、Feature Tips 这三套机制正确运作。

## 架构总览

三套机制**独立运行、可能同时触达**，不互相阻塞：

| 机制 | 触发方式 | 判断依据 | 载体 |
|---|---|---|---|
| 远程更新弹窗 | 异步 HTTP 请求 | 远程 version.json 的 `latestVersion` > 本地版本 | NSPanel (440×500) |
| What's New 公告 | 同步，启动即判断 | `lastSeenWhatsNewVersion < targetVersion` | NSPanel (520×620) + WhatsNewKit |
| Feature Tips | 用户触发时判断 | 开发者启用清单 + 跨过 introducedVersion 门槛 + 未 dismiss + 未超次数上限 | NSPopover / SwiftUI overlay |

## 启动执行顺序

`AppSessionHost.setupIfNeeded()` 中按以下顺序调用（`AppSessionHost.swift:60-66`）：

```
1. AppVersionGate.shared.recordCurrentAppLaunch()
      ↓  维护 previousInstalledVersion / latestInstalledVersion 迁移状态
2. WhatsNewWindowManager.shared.showIfNeeded()
      ↓  同步，基于 UserDefaults 版本比较，不阻塞 UI
3. UpdateWindowManager.shared.checkAndShowIfNeeded()  (Task 异步)
      ↓  发起 HTTP GET 到远程 version.json，比较版本后弹窗
```

---

## 一、远程更新弹窗

### 涉及文件

| 文件 | 职责 |
|---|---|
| `myPlayer2/Services/UpdateCheck/UpdateChecker.swift` | 网络请求 + 版本读取 |
| `myPlayer2/Services/UpdateCheck/UpdateWindowManager.swift` | 弹窗生命周期 |
| `myPlayer2/Services/UpdateCheck/UpdateAlertView.swift` | SwiftUI 弹窗视图 |
| `myPlayer2/Services/UpdateCheck/RemoteVersionInfo.swift` | 数据模型 + 版本比较 + JSON 修复 |
| `myPlayer2/Utilities/AppVersion.swift` | SemVer 结构体 |

### 本地版本号来源

`Bundle.main.infoDictionary?["CFBundleShortVersionString"]`，即 Xcode target 的 `MARKETING_VERSION`（在 `project.pbxproj` 中设置，当前为 `2.0.0`）。

### 远程 version.json

**地址**：`https://kmgcc.github.io/kmgccc_player/version.json`

**格式**：
```json
{
    "latestVersion": "2.0.1",
    "releaseURL": "https://github.com/kmgcc/kmgccc_player/releases/latest",
    "notes": "本次更新内容：\n- 修复了某某问题\n- 新增了某某功能"
}
```

**字段说明**：

- `latestVersion`：字符串，语义化版本号（`major.minor.patch`），必须与 `AppVersion(from:)` 的解析兼容。
- `releaseURL`：用户点击"前往下载"时优先打开的地址。为空、缺失或无法构造 URL 时，代码 fallback 到 `https://github.com/kmgcc/kmgccc_player/releases/latest`。
- `notes`：字符串，显示在弹窗正文区域。**注意 JSON 转义**——见下文。

### 版本比较规则

`AppVersion` 实现 `Comparable`，按 `major → minor → patch` 逐级比较。解析只接受 1 到 3 段非负数字点分版本（如 `2`、`2.0`、`2.0.0`），不会把非法分段静默吞掉。只有 **`remote > local`** 才弹更新窗口。

例如：
- local `2.0.0`, remote `2.0.1` → **弹**
- local `2.0.0`, remote `2.0.0` → 不弹
- local `2.0.0`, remote `1.3.1` → 不弹
- 任意一边解析失败 → 不弹（返回 `.failedToParse`）

### notes 字段的 JSON 转义问题

`version.json` 是手动维护的静态 JSON 文件。如果 `notes` 字段包含换行、制表符等控制字符，**必须在 JSON 中正确转义**：

```
正确："notes": "第一行\\n第二行"
错误："notes": "第一行
第二行"       ← 原始换行导致 JSON 非法
```

代码中 `RemoteVersionInfo.repairInvalidJSONStringControlCharacters` 会尝试修复原始控制字符（`\n`→`\\n`、`\r`→`\\r` 等），修复成功时会打印 `⚠️ Remote version.json was malformed; recovered by escaping raw control characters in strings`。但**不应依赖这个容错逻辑**，请直接写合法的 JSON。

### 每次发布新版本时的操作步骤

1. 修改或确认 Xcode 项目中 `kmgccc_player` target 的 `MARKETING_VERSION` 为新版本号。
2. 更新本地 docs/version.json：
   - `latestVersion` 改为新版本号；
   - 更新 `notes` 为本次 release 说明；
   - `releaseURL` 通常无需改（始终指向 `/releases/latest`），也可以指向某个具体 release 页面。
   - 线上 `https://kmgcc.github.io/kmgccc_player/version.json` 何时更新属于发布流程；本地文件不会被运行中的 App 自动同步到远端。2.0.0 尚未发布时，线上文件仍停留在旧版本是正常状态。

### 强制调试

将 `UpdateWindowManager.shared.forceShowForTesting` 设为 `true` 可无视版本比较结果直接弹窗。**发布前务必确认该标志为 `false`**。

---

## 二、What's New 新功能公告

### 涉及文件

| 文件 | 职责 |
|---|---|
| `myPlayer2/Services/WhatsNew/WhatsNewConfig.swift` | 目标版本号 + 门控逻辑 |
| `myPlayer2/Services/WhatsNew/WhatsNewWindowManager.swift` | NSPanel 弹窗生命周期 |
| `myPlayer2/Views/Settings/WhatsNewConfiguration.swift` | 公告内容定义 |
| `myPlayer2/Services/FeatureTips/AppVersionGate.swift` | 底层 UserDefaults 版本存储 |

### 第三方依赖

- **包名**：`WhatsNewKit` v2.2.1
- **仓库**：`https://github.com/SvenTiigi/WhatsNewKit.git`
- **接入方式**：Swift Package Manager（在 Xcode 项目中直接引用）

### 门控逻辑

```
shouldShowWhatsNew() ⇔ lastSeenWhatsNewVersion < targetVersion
```

- `lastSeenWhatsNewVersion`：存储在 `UserDefaults` 中，key 为 `kmgccc_player.lastSeenWhatsNewVersion`，值是版本字符串如 `"1.3.1"`。
- `targetVersion`：定义在 `WhatsNewConfig.swift` 第 13 行。
- 如果用户从未见过（`lastSeenWhatsNewVersion == nil`）→ 显示。
- 如果用户上次见的版本 < `targetVersion` → 显示。
- 否则不显示。

首次安装时 `lastSeenWhatsNewVersion` 为空，因此 What's New 可以显示；这属于当前产品语义。

### 内容配置

在 `myPlayer2/Views/Settings/WhatsNewConfiguration.swift` 中定义，使用 WhatsNewKit 的声明式 API：

```swift
static let current = WhatsNew(
    version: WhatsNewConfig.whatsNewVersion,  // 版本标识
    title: "kmgccc player 新功能！",
    features: [
        WhatsNew.Feature(
            image: .init(systemName: "text.magnifyingglass", foregroundColor: .indigo),
            title: "功能标题",
            subtitle: "功能描述"
        ),
        // ... 更多 feature
    ],
    primaryAction: .init(
        title: "继续",
        backgroundColor: .accentColor
    )
)
```

每个 feature item 的配置项：
- `systemName`：SF Symbol 图标名
- `foregroundColor`：图标颜色，使用 SwiftUI `Color` 类型
- `title`：功能标题（简短）
- `subtitle`：功能描述（一句话说明）

### 每次发布新版本时的操作步骤

1. **必须**将 `WhatsNewConfig.targetVersion` 更新为**当前要发布的版本号**。否则 `lastSeenWhatsNewVersion` 可能已经等于旧 `targetVersion`，导致不再显示。

   位置：`myPlayer2/Services/WhatsNew/WhatsNewConfig.swift:13`
   ```swift
   static let targetVersion = AppVersion(major: X, minor: Y, patch: Z)
   ```

2. 同步更新 `whatsNewVersion`（同一文件第 14 行），保持与 `targetVersion` 一致。
   ```swift
   static let whatsNewVersion = WhatsNew.Version(major: X, minor: Y, patch: Z)
   ```

3. 在 `myPlayer2/Views/Settings/WhatsNewConfiguration.swift` 中更新功能条目：
   - 替换为本次版本的新功能；
   - 可以增减 feature 数量（不要求固定 5 条）；
   - 移除旧版本的功能条目，只保留**当前版本**的新内容。

### What's New 弹窗 UI

- 窗口：`NSPanel`，520×620，最小 480×560
- 无标准交通灯按钮（close/miniaturize/zoom 全部隐藏）
- 背景为纯 `NSColor.windowBackgroundColor`
- 注入 `ThemeStore` 和 `AppSettings` 环境对象，跟随 App 主题色
- 关闭行为：点击"继续"或直接关闭窗口 → `WhatsNewConfig.markAsSeen()` 写入 UserDefaults → 淡出动画 0.2 秒

> 一般情况下无需更改 UI，每次更新只要替换里面的内容就行

### 调试：重新显示 What's New

删除 UserDefaults 中的已读记录：
```bash
defaults delete kmgccc.player kmgccc_player.lastSeenWhatsNewVersion
```

---

## 三、Feature Tips（功能小提示）

### 涉及文件

| 文件 | 职责 |
|---|---|
| `myPlayer2/Services/FeatureTips/AppVersionGate.swift` | 版本迁移追踪 + Tip 门控逻辑 + `FeatureTipCatalog` 开发者启用清单 |
| `myPlayer2/AppKit/AppKitMainToolbarController.swift` | Shift 连续选择 Tip |
| `myPlayer2/AppKit/AppKitMainSplitWindowController.swift` | 外部音乐 App 播放 Tip |
| `myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift` | 播放队列展开 Tip |
| `myPlayer2/Views/Settings/SettingsView.swift` | v2.0 设置面板资料库 Tip |
| `myPlayer2/Utilities/AppVersion.swift` | SemVer 支持 |

另有 `feature-tips-guide.md` 提供详细的实现步骤模板。

### AppVersionGate 版本追踪

每次启动调用 `recordCurrentAppLaunch()`，维护三个 UserDefaults key：

| Key | 含义 |
|---|---|
| `kmgccc_player.previousInstalledVersion` | 本次升级前安装的版本 |
| `kmgccc_player.latestInstalledVersion` | 当前版本（最新安装的版本） |
| `kmgccc_player.lastSeenWhatsNewVersion` | 上次看过 What's New 的版本 |

`wasUpgradedFromVersionBelow(_:)` 判断逻辑：
```
previousInstalledVersion < version && latestInstalledVersion >= version
```

**兼容规则**：首次安装也允许显示 Feature Tips。如果 `previousInstalledVersion` 缺失（常见于首次安装、旧版本首次升级到带门控系统的新版本，或旧数据迁移不完整），但 `latestInstalledVersion` 存在，则视为用户来自一个很旧的版本，门控正常放行。只有 `previousInstalledVersion` 和 `latestInstalledVersion` 同时缺失时才视为完全没有版本记录。

**版本字符串格式**：`AppVersion.stringValue` 始终输出完整 `major.minor.patch` 格式（如 `2.0.0`），不再缩写 `2.0.0` 为 `2`。UserDefaults 中版本 key 的值必须保证稳定可比较。

### Feature Tip 门控判断

```swift
shouldShowFeatureTip(featureKey: String, introducedVersion: AppVersion, maxDisplayCount: Int = 4) -> Bool
```

四个条件**全部满足**才返回 `true`：
1. `featureKey` 仍在 `FeatureTipCatalog.enabledFeatureKeys` 开发者启用清单中
2. 未被永久关闭（`isFeatureTipDismissed == false`）
3. 已显示次数 < `maxDisplayCount`（默认 4 次）
4. 用户跨过了 `introducedVersion` 门槛：之前记录的版本低于该版本，当前记录的版本达到或高于该版本

### 参数说明

- **`featureKey`**：唯一标识，命名建议 `<模块>.<功能>`，如 `playlist.shiftRangeSelection`。
- **`introducedVersion`**：该功能引入的版本号。判断基于“是否跨过这个版本门槛”，不要求当前 App 版本必须恰好等于 `introducedVersion`。
- **`maxDisplayCount`**：最多展示次数。用户每次触发都会增加计数，达到上限后不再显示。默认 4。

### 开发者启用清单

`FeatureTipCatalog.enabledFeatureKeys` 集中定义当前仍参与显示判断的 tip key：

```swift
enum FeatureTipCatalog {
    static let enabledFeatureKeys: Set<String> = [
        "fullscreen.playbackModeRetap",
        "playbackSource.externalAppPlayback",
        "playlist.shiftRangeSelection",
        "settings.v2DataManagement"
    ]
}
```

后续某条旧 tip 不想再出现时，优先从这份清单中移除或注释掉 key。不要改已发布 tip 的 key；key 变化会导致原有 dismiss 状态和 display count 历史失效。

### UserDefaults Key 规则

| 用途 | Key 格式 |
|---|---|
| 永久关闭标记 | `kmgccc_player.dismissedFeatureTip.<featureKey>` |
| 已显示次数 | `kmgccc_player.featureTipDisplayCount.<featureKey>` |
| 上次安装版本 | `kmgccc_player.previousInstalledVersion` |
| 当前已记录版本 | `kmgccc_player.latestInstalledVersion` |
| What's New 已读版本 | `kmgccc_player.lastSeenWhatsNewVersion` |

版本 key 的值使用完整 `major.minor.patch` 格式（如 `2.0.0`），由 `AppVersion.stringValue` 保证。

### 触发时机

Feature Tip 是在用户**触发相关功能时**才显示，而不是统一由启动入口直接弹出。例如 Shift 连续选择 Tip 在用户进入多选模式时弹出；外部音乐 App 播放 Tip 在主窗口可见并找到 sidebar 播放来源切换器锚点后尝试弹出。典型模式：

```swift
// 在功能 action 方法中
if shouldShowTip {
    DispatchQueue.main.async { [weak self] in
        self?.showMyFeatureTipIfNeeded()
    }
}
```

### 当前已有的 Feature Tip（示例）

**Shift 连续选择提示**（`AppKitMainToolbarController.swift:16-20, 622-650, 1329-1356`）：

- `featureKey`：`"playlist.shiftRangeSelection"`
- `introducedVersion`：`AppVersion(major: 2, minor: 0, patch: 0)`（v2.0.0 引入）
- `maxDisplayCount`：4
- 触发时机：用户点击工具栏 multiselect 按钮进入多选模式
- UI：`NSPopover`（`.semitransient` 行为），288×118，锚定在 multiselect 按钮下方
- 内容：标题"连续选择" + 关闭按钮 (×) + 说明"按住 Shift 点击歌曲，可以一次选择一段连续歌曲"

**v2.0 设置面板资料库提示**（`SettingsView.swift:28-33, 59-64, 101-117, 190-234`）：

- `featureKey`：`"settings.v2DataManagement"`
- `introducedVersion`：`AppVersion(major: 2, minor: 0, patch: 0)`（v2.0.0 引入）
- `maxDisplayCount`：2
- 触发时机：用户打开设置面板
- UI：SwiftUI overlay，`.leading` 对齐在设置窗口左侧，带滑入动画
- 内容：标题"v2.0 资料库管理升级" + 两条功能说明（自定义资料库位置 / 主动补全信息）

**播放队列展开提示**（`FullscreenPlayerView.swift:76-80, 1190-1196, 2171-2185, 3755-3785`）：

- `featureKey`：`"fullscreen.playbackModeRetap"`
- `introducedVersion`：`AppVersion(major: 2, minor: 0, patch: 0)`（v2.0.0 引入）
- `maxDisplayCount`：2
- 触发时机：全屏播放器出现时
- UI：SwiftUI overlay，锚在底部 mini player 的顶部
- 内容：标题"播放队列" + 说明"再次点击已选择的播放顺序按钮，可快速展开播放队列"

**外部音乐 App 播放提示**（`AppKitMainSplitWindowController.swift:52-56, 258-357, 734-760, 778-782`）：

- `featureKey`：`"playbackSource.externalAppPlayback"`
- `introducedVersion`：`AppVersion(major: 2, minor: 0, patch: 0)`（v2.0.0 引入）
- `maxDisplayCount`：2
- 触发时机：主窗口首次 visible 后，sidebar 布局完成时延迟尝试
- UI：`NSPopover`（`.semitransient` 行为），锚定到 sidebar 顶部播放来源切换滑块背后的 `SourceSwitchAnchorProbe`，`preferredEdge: .maxX`
- 内容：标题"现已支持外部音乐 App" + 说明"授权必要权限后，可以在这里切换并使用其他音乐 App 的正在播放内容。"
- 特殊逻辑：递增重试（0.5s → 0.75s → ... → < 5.0s），仅在实际显示 popover 时记录 display count；窗口关闭时 pending flag 重置

### 新增 Feature Tip 步骤摘要

1. 在目标模块中定义私有枚举/常量，包含 `featureKey`、`introducedVersion`、`maxDisplayCount`。
2. 将 `featureKey` 加入 `FeatureTipCatalog.enabledFeatureKeys`。
3. 选择触发时机（通常在 action 方法中），异步 dispatch 调用显示逻辑。
4. 实现 `NSPopover` 或 SwiftUI overlay + SwiftUI `View`（标题 + 关闭按钮 + 说明，固定宽度 288pt）。
5. 根据提示类型决定关闭按钮是临时关闭，还是调用 `markFeatureTipDismissed` 永久关闭。
6. 在相关状态退出时调用 `closeFeatureTipPopover()` 或隐藏 overlay 清理。

详细步骤见 `feature-tips-guide.md`。

### 调试

删除某个 Tip 的 dismiss 标记和显示计数，使其重新显示：
```bash
defaults delete kmgccc.player kmgccc_player.dismissedFeatureTip.playlist.shiftRangeSelection
defaults delete kmgccc.player kmgccc_player.featureTipDisplayCount.playlist.shiftRangeSelection
```

---

## 四、每次发布新版本 Checklist

按顺序操作：

- [ ] **1. 改 App 版本号**
  Xcode → `kmgccc_player` target → General → Version（或直接改 `project.pbxproj` 中的 `MARKETING_VERSION`）。

- [ ] **2. 更新 version.json**
  修改本地 docs/version.json：
  
  - `latestVersion` → 新版本号
  - `notes` → 更新为本次 release 说明（注意 JSON 转义）
  - `releaseURL` 通常不变；如果写具体 release 页面，更新弹窗会优先打开它，缺失或无效时 fallback 到 `/releases/latest`
  - 按发布流程确认线上 GitHub Pages 的 `version.json` 已在需要公开更新提示时同步
  
- [ ] **3. 更新 What's New**
  - `myPlayer2/Services/WhatsNew/WhatsNewConfig.swift`：将 `targetVersion` 和 `whatsNewVersion` 改为新版本号。
  - `myPlayer2/Views/Settings/WhatsNewConfiguration.swift`：替换 feature items 为本次版本新功能。

- [ ] **4. 新增/更新 Feature Tips**
  如有本次版本引入的细粒度功能提示，按上述步骤新增 Feature Tip，`introducedVersion` 设为当前版本号，并把 key 加入 `FeatureTipCatalog.enabledFeatureKeys`。如果某条旧 tip 本版本不想再显示，从该清单移除 key 即可。

- [ ] **5. Debug 验证弹窗**
  - What's New：删除 `kmgccc_player.lastSeenWhatsNewVersion`，启动 App 验证弹窗内容。
  - 更新弹窗：将 `forceShowForTesting` 临时设为 `true`，验证弹窗样式和文案。
  - Feature Tip：删除对应 featureKey 的 dismiss + displayCount key，触发功能验证 popover。

- [ ] **6. 清理测试用 UserDefaults**

  ```bash
  # 清除 What's New 已读
  defaults delete kmgccc.player kmgccc_player.lastSeenWhatsNewVersion

  # 清除所有 Feature Tip 标记（按具体 key 逐个清除）
  defaults delete kmgccc.player kmgccc_player.dismissedFeatureTip.playlist.shiftRangeSelection
  defaults delete kmgccc.player kmgccc_player.featureTipDisplayCount.playlist.shiftRangeSelection

  # 清除版本追踪（如需模拟全新安装）
  defaults delete kmgccc.player kmgccc_player.previousInstalledVersion
  defaults delete kmgccc.player kmgccc_player.latestInstalledVersion
  ```

- [ ] **7. 打 Release 包前确认**
  - `UpdateWindowManager.shared.forceShowForTesting` **必须为 `false`**
  - `WhatsNewConfiguration.current` 内容为本次发布版本的新功能（而非旧版本或草稿）
  - `WhatsNewConfig.targetVersion` 与 `MARKETING_VERSION` 一致
  - `FeatureTipCatalog.enabledFeatureKeys` 只包含本次仍要参与显示判断的 tip key

---

## 五、常用调试命令

以下命令的 bundle ID 为 `kmgccc.player`。

### 查看所有相关 UserDefaults 值

```bash
defaults read kmgccc.player | grep -E 'kmgccc_player\.(lastSeen|previous|latest|dismissedFeatureTip|featureTipDisplayCount)'
```

### What's New 相关

```bash
# 查看当前已读版本
defaults read kmgccc.player kmgccc_player.lastSeenWhatsNewVersion

# 删除已读记录（下次启动会重新弹出）
defaults delete kmgccc.player kmgccc_player.lastSeenWhatsNewVersion
```

### Feature Tips 相关

```bash
# 查看某个 Tip 的关闭状态（1 = 已永久关闭）
defaults read kmgccc.player kmgccc_player.dismissedFeatureTip.playlist.shiftRangeSelection

# 查看某个 Tip 的已显示次数
defaults read kmgccc.player kmgccc_player.featureTipDisplayCount.playlist.shiftRangeSelection

# 删除关闭标记，使 Tip 可重新显示
defaults delete kmgccc.player kmgccc_player.dismissedFeatureTip.playlist.shiftRangeSelection

# 删除显示计数，重置为 0
defaults delete kmgccc.player kmgccc_player.featureTipDisplayCount.playlist.shiftRangeSelection
```

### 版本追踪相关

```bash
# 查看之前的版本号
defaults read kmgccc.player kmgccc_player.previousInstalledVersion

# 查看最新安装的版本号
defaults read kmgccc.player kmgccc_player.latestInstalledVersion
```

### 缺失 previousInstalledVersion 的兼容行为

如果 `latestInstalledVersion` 已设置但 `previousInstalledVersion` 缺失，门控会把它视为来自旧版本，允许 Feature Tips 正常显示。启动 App 一次后，`recordCurrentAppLaunch` 也会在当前版本未变化时把缺失的 `previousInstalledVersion` 补为 `0.0.0`。

也可手动写入：
```bash
defaults write kmgccc.player kmgccc_player.previousInstalledVersion -string "0.0.0"
```

### 一次性清除所有 kmgccc_player 开头的 key（仅限调试，会清除所有持久化状态）

```bash
defaults delete kmgccc.player
```

### 在代码中强制测试更新弹窗

在 `UpdateWindowManager` 初始化后设置：
```swift
UpdateWindowManager.shared.forceShowForTesting = true
```
然后调用 `checkAndShowIfNeeded()` 即可无视版本比较直接弹窗。
