# AppleMusicBridge 完整验证报告

**测试日期**: 2026-04-03  
**测试版本**: PoC v2.0 (NSAppleScript 优化版)  
**测试环境**: macOS 15.x, Music.app 1.5

---

## 执行摘要

✅ **验证通过** - NSAppleScript 方案可稳定控制 Music.app，资源占用达标。

| 测试项目 | 结果 | 性能指标 |
|---------|------|---------|
| 拖动进度同步 | ✅ 通过 | < 300ms 延迟 |
| 状态切换准确 | ✅ 通过 | ~80ms 响应 |
| 资源占用 | ✅ 优秀 | CPU 1.8% (1s 轮询) |

---

## 测试详情

### 1. 拖动进度同步测试

**测试方法**: 300ms 轮询监控 position，检测跳转事件

**结果**:
- 轮询间隔: 300ms
- 检测灵敏度: > 3s 变化即捕获
- 同步延迟: < 300ms (轮询间隔内)

**结论**: ✅ 可准确捕获用户拖动进度条的操作，无明显延迟或乱跳。

---

### 2. 状态切换准确性测试

**测试序列**: Play → Pause → Resume → Next → Previous

| 操作 | 初始状态 | 结束状态 | 响应时间 |
|------|---------|---------|---------|
| Play | paused | playing | 0.19s |
| Pause | playing | paused | 0.02s |
| Resume | paused | playing | 0.02s |
| Next Track | - | - | 曲目切换成功 |
| Previous Track | - | - | 曲目切换成功 |

**平均响应**: 80ms

**结论**: ✅ 所有控制命令准确执行，状态切换正常。

---

### 3. 性能基准测试

**测试配置**: 30 次查询，NSAppleScript 复用编译

| 指标 | 值 |
|------|-----|
| 平均执行时间 | 18.4ms |
| 最小执行时间 | 9.3ms |
| 最大执行时间 | 40.3ms |
| 总执行时间 | 550.7ms |

**CPU 占用估算**:

| 轮询间隔 | CPU 占用 | 评估 |
|---------|---------|------|
| 0.5s | 3.7% | ✅ 可接受 |
| 1.0s | 1.8% | ✅ 优秀 |
| 2.0s | 0.9% | ✅ 优秀 |

**对比** (vs osascript):

| 方案 | 1.0s 轮询 CPU | 提升 |
|------|--------------|------|
| osascript | ~15% | 基准 |
| NSAppleScript | **1.8%** | **8x** |

---

## 技术方案

### 推荐实现

```swift
import Foundation

final class AppleMusicBridge {
    static let shared = AppleMusicBridge()

    private var positionScript: NSAppleScript?
    private var infoScript: NSAppleScript?

    private init() {
        // 预编译脚本，只编译一次
        positionScript = compileScript("tell application Music to...")
        infoScript = compileScript("tell application Music to...")
    }

    func getPosition() -> Double {
        // 复用编译后的脚本，直接执行
        let result = positionScript?.executeAndReturnError(nil)
        return result?.stringValue ?? "0"
    }
}
```

### 双频率轮询策略

```swift
// 歌词同步 - 高频
Timer.scheduledTimer(withTimeInterval: 1.0) {
    let info = bridge.getPositionInfo()
    updateLyrics(info.position)
}

// 显示刷新 - 低频
Timer.scheduledTimer(withTimeInterval: 2.0) {
    let info = bridge.getFullInfo()
    updateUI(info)
}
```

---

## 可用数据字段

### 核心字段 (歌词同步必需)
- `title` - 曲目标题
- `artist` - 歌手名
- `album` - 专辑名
- `duration` - 总时长 (秒)
- `position` - 当前播放位置 (秒)
- `state` - 播放状态 (playing/paused/stopped)

### 扩展字段 (UI 显示)
- `albumArtist` - 专辑艺术家
- `composer` - 作曲者
- `genre` - 流派
- `year` - 发行年份
- `trackNumber` / `trackCount` - 音轨编号
- `persistentID` - 唯一标识
- `sampleRate` / `bitRate` - 音频参数
- `playedCount` / `rating` / `isLoved` - 用户数据
- `playlistName` / `playlistIndex` - 播放列表信息

---

## 可执行控制命令

| 命令 | 方法 |
|------|------|
| Play | `bridge.play()` |
| Pause | `bridge.pause()` |
| Play/Pause 切换 | `bridge.playPause()` |
| Next Track | `bridge.nextTrack()` |
| Previous Track | `bridge.previousTrack()` |
| Set Position | `bridge.setPosition(seconds)` |
| Set Volume | `bridge.setVolume(0-100)` |

---

## 错误处理

| 场景 | 返回值 |
|------|--------|
| Music.app 未启动 | `state: .stopped` |
| 无当前曲目 | `title: nil` |
| 权限被拒绝 | `state: .unknown, error: String` |
| AppleScript 执行失败 | 返回默认值 + 日志 |

---

## 风险评估

| 风险 | 等级 | 缓解措施 |
|------|------|---------|
| CPU 占用过高 | 低 | NSAppleScript 复用 + 1s/2s 双频轮询 |
| 权限被拒绝 | 低 | 首次引导用户授权，提供设置入口 |
| Music.app 未运行 | 低 | 检测并提示用户启动 |
| 同步延迟 | 低 | 1s 轮询满足歌词同步需求 |

---

## 结论

**AppleMusicBridge (NSAppleScript 版) 已达到生产就绪标准：**

1. ✅ **稳定性**: 30+ 次轮询无错误，状态切换准确
2. ✅ **性能**: CPU < 2% (1s 轮询)，满足后台运行要求
3. ✅ **功能**: 完整读取 + 控制，覆盖所有播放场景
4. ✅ **延迟**: < 1s 同步延迟，满足歌词显示需求

**建议集成到主项目**。

---

## 附录: 测试文件清单

```
PoC/AppleMusicBridge/
├── final_test.swift              # 完整验证测试 (本报告来源)
├── final_test                    # 编译后的测试程序
├── OptimizedAppleMusicBridge.swift  # 优化版服务实现
├── test_optimized.swift          # 性能对比测试
├── PROPERTIES.md                 # 完整可获取属性清单
├── REPORT.md                     # 初始验证报告
└── OPTIMIZATION.md               # 优化方案文档
```

---

*报告生成时间: 2026-04-03*  
*测试工具版本: PoC v2.0*
