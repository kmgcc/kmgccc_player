# Track Meta Schema 迁移指南

## 概述

从 schemaVersion 3 开始，所有播放偏好统计统一迁移到 `preferenceStats` 对象中。顶层 `playCount` 字段已废弃。

## 废弃字段列表

| 字段路径 | 状态 | 说明 |
|---------|------|------|
| `playCount` | **废弃** | 仅用于旧 schema 迁移，不再写入新文件 |
| `preferenceStats` | **唯一权威来源** | 包含完整播放统计信息 |

## 新 Schema 结构 (schemaVersion 3)

```json
{
  "schemaVersion": 3,
  "id": "...",
  "title": "...",
  "artist": "...",
  "album": "...",
  "duration": 240.5,
  "addedAt": "2024-01-15T10:30:00Z",
  "importedAt": "2024-01-15T10:30:00Z",
  "lyricsTimeOffsetMs": 0,
  "originalFilePath": "...",
  "audioFileName": "audio.m4a",
  "artworkFileName": "artwork.jpg",
  "ttmlLyricsFileName": "lyrics.ttml",
  "ncmSourcePath": null,
  "preferenceStats": {
    "playCount": 15,
    "completePlayCount": 12,
    "skipCount": 3,
    "quickSkipCount": 1,
    "totalPlayedSeconds": 3250.5,
    "lastPlayedAt": "2024-06-10T14:22:00Z",
    "lastCompletedAt": "2024-06-10T14:22:00Z",
    "lastSkippedAt": null,
    "manualLikeState": "liked",
    "preferenceScoreCache": 42.5,
    "effectiveWeightCache": 1.85
  }
}
```

## 迁移逻辑

### 读取时 (Decode)

1. **如果 `preferenceStats` 存在**: 直接使用
2. **如果 `preferenceStats` 缺失但顶层 `playCount` 存在** (schemaVersion < 3):
   - 调用 `TrackPreferenceStats.fromLegacy(playCount:)` 创建 preferenceStats
   - 将 `playCount` 同时写入 `playCount` 和 `completePlayCount` (保守估计)

### 写入时 (Encode)

- **不再写入顶层 `playCount`** - 避免双份统计
- **只写入 `preferenceStats`** - 唯一权威来源
- CodingKeys 中保留 `playCount` 仅用于向后兼容解码

## 代码访问方式变更

### 旧方式 (废弃)
```swift
// 废弃: 直接访问 track.playCount
track.playCount += 1
```

### 新方式 (推荐)
```swift
// 读取统计
let stats = PreferenceStatsService.shared.getStats(for: track.id)
print(stats.playCount)
print(stats.completePlayCount)
print(stats.skipCount)

// 更新统计
PreferenceStatsService.shared.updateStats(for: track.id) { stats in
    stats.playCount += 1
    stats.completePlayCount += 1
}

// 保存到磁盘
LocalLibraryService.shared.writeSidecar(for: track)
```

### 便捷扩展 (Track+)
```swift
// Track.playCount 现在是计算属性，从 preferenceStats 获取
@MainActor
var playCount: Int {
    PreferenceStatsService.shared.getStats(for: id).playCount
}

// 使用示例
print(track.playCount)  // 读取 OK
// track.playCount = 5  // 写入无效果 (no-op setter)
```

## 受影响文件清单

| 文件 | 变更 |
|------|------|
| `Track.swift` | `playCount` 改为计算属性，从 preferenceStats 获取 |
| `TrackSidecar` | encode 时不再写入 `playCount` |
| `LocalLibraryService.swift` | `writeSidecar` 移除 `playCount` 参数 |
| `MusicLibraryScanner.swift` | 支持读取 `preferenceStats` |
| `PlayCountService.swift` | 标记为废弃，委托给 PreferenceStatsService |

## 向后兼容性

- **旧 meta.json (无 preferenceStats)**: 自动迁移，下次写回时升级为 schemaVersion 3
- **新代码读取旧文件**: 通过 `fromLegacy()` 自动转换
- **旧代码读取新文件**: `playCount` 字段不存在，默认为 0 (不影响功能)

## 统计数据完整性保证

1. 播放时通过 `PlaybackSessionTracker` 追踪行为
2. 切歌/完成时通过 `PreferenceStatsService.applyPlaybackOutcome()` 更新统计
3. 写回时统一写入 `preferenceStats`，废弃字段不再写入
4. 内存缓存 + 延迟写盘策略保证性能

## 检查清单

- [x] TrackSidecar encode 不再写入顶层 playCount
- [x] Track.playCount 改为从 preferenceStats 计算
- [x] 所有写入操作改为使用 PreferenceStatsService
- [x] 旧 schema 迁移逻辑完整
- [x] MusicLibraryScanner 支持新字段
- [x] 构建通过
