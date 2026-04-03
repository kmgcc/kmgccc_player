# AppleMusicBridge 使用指南

快速集成 Music.app 控制到你的 macOS 应用。

---

## 1. 添加到你的项目

将 `OptimizedAppleMusicBridge.swift` 复制到你的项目中：

```swift
// 1. 导入框架
import Foundation

// 2. 添加 AppleMusicBridge.swift 到你的项目
```

---

## 2. 基础使用

### 2.1 检查 Music.app 是否运行

```swift
if AppleMusicBridge.shared.isMusicAppRunning() {
    // Music.app 正在运行
} else {
    // 提示用户启动 Music.app
}
```

### 2.2 获取当前播放信息

```swift
// 精简查询 (仅位置和状态) - 用于歌词同步
let info = AppleMusicBridge.shared.fetchPositionInfo()
print("位置: \(info.formattedPosition)")
print("状态: \(info.state)")  // playing / paused / stopped

// 完整查询 - 用于显示
let fullInfo = AppleMusicBridge.shared.fetchFullInfo()
print("歌曲: \(fullInfo.title ?? "未知")")
print("歌手: \(fullInfo.artist ?? "未知")")
print("专辑: \(fullInfo.album ?? "未知")")
```

### 2.3 控制播放

```swift
// 播放/暂停切换
AppleMusicBridge.shared.playPause()

// 下一首
AppleMusicBridge.shared.nextTrack()

// 上一首
AppleMusicBridge.shared.previousTrack()

// 设置音量 (0-100)
AppleMusicBridge.shared.setVolume(50)
```

---

## 3. 双频率轮询 (推荐)

### 3.1 自动监控模式

```swift
// 开始监控
AppleMusicBridge.shared.startMonitoring(config: .default)

// 监听歌词同步 (1.0s 频率)
AppleMusicBridge.shared.onLyricsTick = { info in
    // 更新歌词位置
    lyricsView.updatePosition(info.position)
}

// 监听显示刷新 (2.0s 频率)
AppleMusicBridge.shared.onDisplayTick = { info in
    // 更新 UI
    titleLabel.text = info.title
    artistLabel.text = info.artist
}

// 停止监控
AppleMusicBridge.shared.stopMonitoring()
```

### 3.2 自定义配置

```swift
// 自定义轮询频率
let config = AppleMusicBridge.MonitorConfig(
    lyricsInterval: 1.0,   // 歌词同步: 1秒
    displayInterval: 2.0   // 显示刷新: 2秒
)
AppleMusicBridge.shared.startMonitoring(config: config)
```

### 3.3 预设配置

```swift
// 默认配置 (歌词 1s, 显示 2s)
AppleMusicBridge.shared.startMonitoring(config: .default)

// 省电配置 (歌词 1.5s, 显示 3s)
AppleMusicBridge.shared.startMonitoring(config: .lowPower)
```

---

## 4. 手动轮询 (高级)

如果你需要完全控制轮询逻辑：

```swift
var timer: Timer?

func startCustomPolling() {
    timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
        let info = AppleMusicBridge.shared.fetchPositionInfo()

        // 检查状态变化
        if info.state == .playing {
            updateLyrics(info.position)
        }
    }
}

func stopCustomPolling() {
    timer?.invalidate()
    timer = nil
}
```

---

## 5. 错误处理

```swift
let info = AppleMusicBridge.shared.fetchFullInfo()

if let error = info.error {
    // 处理错误
    switch error {
    case "Music.app not running":
        showAlert("请先启动 Music.app")
    case "Permission denied":
        showAlert("请在系统设置中授权")
    default:
        showAlert("获取播放信息失败: \(error)")
    }
    return
}

// 正常处理
updateUI(info)
```

---

## 6. 完整示例

### 6.1 简单播放器控件

```swift
import SwiftUI

struct MusicControlView: View {
    @State private var title: String = "未在播放"
    @State private var artist: String = "-"
    @State private var isPlaying: Bool = false

    var body: some View {
        VStack {
            Text(title)
                .font(.headline)
            Text(artist)
                .font(.subheadline)

            HStack {
                Button("上一首") {
                    AppleMusicBridge.shared.previousTrack()
                }

                Button(isPlaying ? "暂停" : "播放") {
                    AppleMusicBridge.shared.playPause()
                }

                Button("下一首") {
                    AppleMusicBridge.shared.nextTrack()
                }
            }
        }
        .onAppear {
            startMonitoring()
        }
        .onDisappear {
            AppleMusicBridge.shared.stopMonitoring()
        }
    }

    func startMonitoring() {
        AppleMusicBridge.shared.startMonitoring()
        AppleMusicBridge.shared.onDisplayTick = { info in
            self.title = info.title ?? "未在播放"
            self.artist = info.artist ?? "-"
            self.isPlaying = info.isPlaying
        }
    }
}
```

### 6.2 歌词同步

```swift
class LyricsSyncManager {
    func start() {
        AppleMusicBridge.shared.startMonitoring()
        AppleMusicBridge.shared.onLyricsTick = { [weak self] info in
            self?.syncLyrics(position: info.position)
        }
    }

    func syncLyrics(position: Double) {
        // 根据 position 查找对应歌词行
        let currentLine = findLyricLine(at: position)
        highlightLine(currentLine)
    }
}
```

---

## 7. 权限处理

首次使用时需要用户授权：

```swift
func checkPermission() {
    let hasPermission = AppleMusicBridge.shared.checkAutomationPermission()

    if !hasPermission {
        // 显示授权引导
        let alert = NSAlert()
        alert.messageText = "需要授权"
        alert.informativeText = "请在系统设置 > 隐私与安全性 > 自动化中允许本应用控制 Music"
        alert.runModal()
    }
}
```

---

## 8. 性能建议

| 场景 | 推荐轮询间隔 | CPU 占用 |
|------|------------|---------|
| 歌词同步 | 1.0s | ~2% |
| 播放信息显示 | 2.0s | ~1% |
| 进度条更新 | 1.0s | ~2% |
| 后台模式 | 3.0s | <1% |

---

## 9. 常见问题

### Q: 为什么获取不到信息？
A: 检查 Music.app 是否正在运行且正在播放歌曲。

### Q: 控制命令无效？
A: 检查是否有自动化权限（系统设置 > 隐私与安全性 > 自动化）。

### Q: CPU 占用高？
A: 确保使用 NSAppleScript 版本（预编译复用），不要每次新建 osascript 进程。

### Q: 歌词同步有延迟？
A: 使用 1.0s 轮询间隔，或考虑实现 Distributed Notifications（零轮询）。

---

## 10. API 参考

### 数据模型

```swift
struct NowPlayingInfo {
    let title: String?        // 歌曲名
    let artist: String?       // 歌手
    let album: String?        // 专辑
    let duration: Double      // 总时长(秒)
    let position: Double      // 当前位置(秒)
    let state: PlayerState    // 播放状态
    let volume: Int           // 音量(0-100)

    var isPlaying: Bool
    var progress: Double      // 0.0 ~ 1.0
    var formattedPosition: String  // "mm:ss"
    var formattedDuration: String  // "mm:ss"
}

enum PlayerState {
    case playing
    case paused
    case stopped
    case unknown
}
```

### 方法列表

| 方法 | 返回值 | 说明 |
|------|--------|------|
| `isMusicAppRunning()` | Bool | Music.app 是否运行 |
| `fetchPositionInfo()` | NowPlayingInfo | 获取位置和状态 |
| `fetchFullInfo()` | NowPlayingInfo | 获取完整信息 |
| `playPause()` | Bool | 播放/暂停切换 |
| `play()` | Bool | 播放 |
| `pause()` | Bool | 暂停 |
| `nextTrack()` | Bool | 下一首 |
| `previousTrack()` | Bool | 上一首 |
| `setPosition(_:)` | Bool | 设置播放位置 |
| `setVolume(_:)` | Bool | 设置音量 |
| `startMonitoring(config:)` | Void | 开始监控 |
| `stopMonitoring()` | Void | 停止监控 |

---

*指南版本: v1.0*  
*适用于: AppleMusicBridge PoC v2.0*
