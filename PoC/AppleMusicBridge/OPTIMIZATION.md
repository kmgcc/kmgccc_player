# AppleMusicBridge 资源占用优化分析

## 当前问题

每 0.5 秒执行一次 AppleScript，实测平均耗时 **251ms**，CPU 估算占用 **50%**，这是不可接受的。

---

## 根本原因

`osascript` 每次调用都是完整的进程创建 + AppleScript 编译执行：

```
调用链:
[Swift] → Process("osascript") → AppleScript 编译器 → Music.app → 返回
          ↑_____________________________↑
                    ~200-300ms
```

---

## 优化方案对比

| 方案 | 实现复杂度 | 单次延迟 | CPU 占用 | 推荐度 |
|------|-----------|----------|----------|--------|
| **A. 降低轮询频率** | 低 | 1-2s | 低 | ⭐⭐⭐ 临时方案 |
| **B. ScriptingBridge** | 中 | ~10ms | 极低 | ⭐⭐⭐⭐ 推荐 |
| **C. NSAppleScript 复用** | 中 | ~50ms | 低 | ⭐⭐⭐⭐ 推荐 |
| **D. Distributed Notifications** | 高 | 实时 | 零 | ⭐⭐⭐⭐⭐ 最佳但复杂 |

---

## 推荐方案 C: NSAppleScript 复用

复用编译后的 AppleScript，避免每次都重新编译：

```swift
class OptimizedAppleMusicBridge {
    // 复用编译的脚本
    private let fetchScript: NSAppleScript
    private let controlScript: NSAppleScript

    init() {
        // 预编译脚本，只编译一次
        let fetchSource = """
            tell application "Music"
                return {player position, player state as string}
            end tell
        """
        fetchScript = NSAppleScript(source: fetchSource)!
        fetchScript.compileAndReturnError(nil)
    }

    func getPosition() -> Double {
        // 只执行，不重新编译
        var error: NSDictionary?
        let result = fetchScript.executeAndReturnError(&error)
        return result?.doubleValue ?? 0
    }
}
```

### 预期性能

| 指标 | osascript | NSAppleScript 复用 | 提升 |
|------|-----------|-------------------|------|
| 单次调用 | 250ms | 20-50ms | 5-10x |
| CPU 占用 | 50% | <5% | 10x |

---

## 临时方案: 降低轮询频率

如果暂时无法重构，直接降低频率到 1-2 秒：

```swift
// 歌词同步: 1 秒足够
startMonitoring(interval: 1.0)

// 显示刷新: 2 秒足够
startMonitoring(interval: 2.0)
```

### 延迟对比

| 轮询间隔 | 理论延迟 | 歌词同步效果 | CPU 估算 |
|---------|---------|-------------|----------|
| 0.5s | 0-0.5s | 流畅 | 50% ❌ |
| 1.0s | 0-1s | 可接受 | 25% ⚠️ |
| 2.0s | 0-2s | 略有延迟 | 12% ✅ |

---

## 长期方案: Distributed Notifications (零轮询)

Music.app 在 macOS 上广播播放状态变化通知，可以被动监听：

```swift
// 注册监听
DistributedNotificationCenter.default.addObserver(
    self,
    selector: #selector(handleMusicChange),
    name: Notification.Name("com.apple.iTunes.playerInfo"),
    object: nil
)

@objc func handleMusicChange(_ notification: Notification) {
    // 实时获取变化，零轮询
    let info = notification.userInfo
    let position = info?["Player Position"] as? Double
    let state = info?["Player State"] as? String
}
```

### 优点
- **零 CPU 占用**（事件驱动）
- **零延迟**（实时通知）
- 包含完整播放信息

### 缺点
- 实现复杂
- 需要处理各种边界情况
- macOS 版本兼容性

---

## 实施建议

### Phase 1: 紧急缓解 (今天)
将轮询频率从 0.5s 降低到 **1.5s**，CPU 降至 ~17%

### Phase 2: 短期优化 (本周)
迁移到 **NSAppleScript 复用**，CPU 降至 <5%

### Phase 3: 长期方案 (可选)
实现 **Distributed Notifications**，零 CPU

---

## 结论

当前 `osascript` 方案在 0.5s 轮询下 **不可用于生产环境**。

**建议立即降级轮询频率到 1.5s 以上，或优先实现 NSAppleScript 复用。**
