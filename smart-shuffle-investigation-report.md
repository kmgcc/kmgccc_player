# Smart Shuffle / 偏好随机播放系统调查报告

> 调查日期：2026-05-10
> 调查分支：main (HEAD 15b61da)
> 调查原则：严格以代码现状为准，不猜测，不修饰

---

## 1. 调查范围与结论摘要

### 核心问题回答

**当前项目里是否真的存在一个完整的偏好随机播放系统？**
是的。当前项目存在一套从数据模型、统计采集、评分算法、有状态队列到持久化的完整偏好随机播放系统。

**它是否已经真正接入主播放链路？**
是的。`AVAudioPlaybackService` 内部持有 `SmartPlaybackController` 实例，所有播放导航（next/previous/auto-advance/seek/play/stop）都经过它。

**当前随机播放是否由有状态队列驱动？**
是的。`ShuffleSession` 维护了 `generatedTrackIDs` 有状态序列，支持前/后导航且"返回上一首后再下一首不会变歌"。

**偏好统计是否真的会写回歌曲 meta / sidecar？**
是的，但存在可靠性隐患。`finalizeCurrentPlaybackSession` 在切歌/播完时调用 `PreferenceStatsService.shared.saveStats(for:)` 触发 `LocalLibraryService.shared.writeMetaOnly`。但 `PreferenceStatsLifecycleHandler`（负责 app 退到后台/退出/定期保存）**从未被初始化**，是一个死代码问题。

**当前实现大体成熟、半成品、还是高度碎片化？**
偏向成熟。核心链路已通：播放事件→session tracker→stats service→scorer→shuffle session→writeback。但存在若干技术债和可靠性缺口（详见第13节）。

### 最重要的 10 条结论

1. **偏好随机播放已完整接入主播放链路**，`AVAudioPlaybackService` 不再有旧的随机逻辑旁路。
2. **V2 评分算法已落地**，使用比例特征+低样本保护+tanh压缩+运行时惩罚，温和区间 0.65~1.35。
3. **有状态 ShuffleSession 已实现**，支持稳定序列、动态扩展、前/后导航、同artist/album惩罚。
4. **PlaybackSessionTracker 已统一所有切歌路径的结算入口**（`finalizeCurrentPlaybackSession`），但 `PlaybackCoordinator.playRandomTracks` 路径会重建整个 session。
5. **`PreferenceStatsLifecycleHandler` 从未被初始化**——app 退到后台、退出、定时保存的通知监听从未注册，这是写盘可靠性最大隐患。
6. **旧 `PlayCountService` 仍是独立单例**，但其 `startPlaybackSession`/`endPlaybackSession`/`updatePlaybackProgress` 方法在代码中**无任何调用点**，已是死代码。
7. **Track.playCount 的 setter 是空操作**（no-op），读取委托给 PreferenceStatsService，顶层 `playCount` 字段不再写入 sidecar，但 sidecar 解码仍读取旧字段做迁移。
8. **sidecar schemaVersion = 6**，`preferenceStats` 字段在 schemaVersion >= 3 时存在，写入时始终包含，旧 `playCount` 顶层字段不再写入。
9. **`PlaybackCoordinator.smartRandomQueue` 会预生成整个播放列表**，与 ShuffleSession 的动态扩展队列存在重复逻辑和潜在冲突。
10. **seek 检测存在双层实现**（AVAudioPlaybackService 和 SmartPlaybackController 各自独立检测），且都使用异步延迟清除标志，可能存在竞争条件。

---

## 2. 相关文件总表

### 核心文件

| 文件路径 | 作用 | 与 smart shuffle 的关系 |
|---------|------|----------------------|
| `myPlayer2/Models/TrackPreferenceStats.swift` | 偏好统计数据结构定义 | 定义了 `TrackPreferenceStats` 结构体，包含所有统计字段、缓存分数、schema版本 |
| `myPlayer2/Services/Audio/PreferenceScorerV2.swift` | V2 偏好评分算法 | 计算偏好分、基础权重、运行时惩罚，是评分核心 |
| `myPlayer2/Services/Audio/ShuffleSession.swift` | 有状态随机队列管理 | 维护生成序列、当前位置、历史记录、动态扩展 |
| `myPlayer2/Services/Audio/PlaybackSessionTracker.swift` | 播放会话追踪器 | 追踪单次播放的时长、进度、完成/跳过判定 |
| `myPlayer2/Services/Audio/SmartPlaybackController.swift` | 智能播放控制器 | 协调 session tracker + shuffle session + stats service，是主播放链路入口 |
| `myPlayer2/Services/Audio/WeightedRandomSampler.swift` | 带权随机抽样 | 轮盘赌法实现，支持单次和批量无放回抽样 |
| `myPlayer2/Services/Library/PreferenceStatsService.swift` | 偏好统计服务 | 内存缓存+脏标记+持久化调度，是统计数据的权威访问入口 |
| `myPlayer2/Services/Library/PreferenceStatsExtensions.swift` | Track 扩展 + 生命周期处理 | Track.preferenceStats 便捷属性、ManualLikeState UI 扩展、**PreferenceStatsLifecycleHandler（未初始化）** |

### 接入文件

| 文件路径 | 作用 | 与 smart shuffle 的关系 |
|---------|------|----------------------|
| `myPlayer2/Services/Audio/AVAudioPlaybackService.swift` | 真实音频播放服务 | 持有 `SmartPlaybackController`，所有播放操作都通过它 |
| `myPlayer2/Services/Playback/PlaybackCoordinator.swift` | 播放协调器 | `smartRandomQueue` 方法预生成带权随机播放列表，`playRandomTracks`/`playTrack` 调用它 |
| `myPlayer2/Services/Audio/AudioPlaybackServiceProtocol.swift` | 播放服务协议 | 定义了 `setShuffleEnabled`、`discardCurrentPlaybackSessionStatsOnce` 等偏好相关接口 |
| `myPlayer2/ViewModels/PlayerViewModel.swift` | 播放视图模型 | 无直接偏好代码，通过 PlaybackService 间接使用 |

### 数据模型

| 文件路径 | 作用 | 与 smart shuffle 的关系 |
|---------|------|----------------------|
| `myPlayer2/Models/Track.swift` | Track SwiftData 模型 | `playCount` 属性已废弃为 no-op 委托，但字段仍存在于 @Model |
| `myPlayer2/Services/Library/LocalLibraryService.swift` | 本地库服务 | `TrackSidecar` 定义了 sidecar schema（含 preferenceStats），`writeMetaOnly` 是写盘入口 |
| `myPlayer2/Services/Library/MusicLibraryScanner.swift` | 音乐库扫描器 | `ScannedTrackMeta` 包含 `preferenceStats` 和废弃的 `playCount` |

### 持久化

| 文件路径 | 作用 | 与 smart shuffle 的关系 |
|---------|------|----------------------|
| `myPlayer2/Services/Library/LocalLibraryService.swift` | 本地库服务 | `writeTrackMeta` 从 `PreferenceStatsService.shared.getStats` 读取数据写入 sidecar |
| `myPlayer2/Repositories/SwiftDataLibraryRepository.swift` | SwiftData 仓库 | 在 `refreshAvailability` 和加载 track 时调用 `PreferenceStatsService.shared.replaceStats/removeStats` |

### UI 或控制入口

| 文件路径 | 作用 | 与 smart shuffle 的关系 |
|---------|------|----------------------|
| `myPlayer2/ViewModels/HomeViewModel.swift` | 首页视图模型 | 使用 `playCount`、`preferenceScoreCache`、`totalPlayedSeconds` 生成首页洞察和排行 |
| `myPlayer2/Views/Home/HomeInsightsSection.swift` | 首页洞察区域 | 显示偏好排行 |
| `myPlayer2/Views/Library/PlaylistPageController.swift` | 播放列表页控制器 | 可能引用 preferenceStats 做排序 |
| `myPlayer2/ViewModels/LibraryViewModel.swift` | 库视图模型 | 支持 playCount/preference 排序 |
| `myPlayer2/Views/Settings/DataManagement/MusicPreferenceResetDialog.swift` | 偏好重置对话框 | 用户 UI 入口，调用 PreferenceResetService |
| `myPlayer2/Views/Settings/DataManagement/DataManagementSettingsView.swift` | 数据管理设置 | 包含偏好重置入口 |

### 工具或扩展

| 文件路径 | 作用 | 与 smart shuffle 的关系 |
|---------|------|----------------------|
| `myPlayer2/Services/Library/PreferenceResetService.swift` | 偏好重置服务 | 批量重置 preferenceStats，清理旧字段残留 |
| `myPlayer2/Services/Library/PlayCountService.swift` | **已废弃的播放计数服务** | 仍存在但无调用点，内部委托给 PreferenceStatsService |
| `myPlayer2/Services/Audio/PreferenceScorerV2Samples.swift` | V2 算法样例计算 | 调试/验证用，打印典型场景的评分结果 |
| `myPlayer2/Services/Audio/StubAudioPlaybackService.swift` | 播放服务桩 | preview 用，无偏好逻辑 |
| `myPlayer2/Services/Audio/ShuffleQueueManager.swift` | **已废弃的简单随机队列** | 使用均匀随机（非偏好加权），无任何调用点，完全死代码 |

---

## 3. 系统架构总览

### 模块关系

```
用户操作
  │
  ▼
AVAudioPlaybackService (主播放服务)
  │
  ├── SmartPlaybackController (核心控制器)
  │     │
  │     ├── PlaybackSessionTracker (单次播放追踪)
  │     │     │ 追踪: currentTime 进度、accumulatedSeconds、完成/跳过判定
  │     │     └── 输出 PlaybackSessionOutcome
  │     │
  │     ├── ShuffleSession (有状态随机队列)
  │     │     │ 维护: generatedTrackIDs, currentIndex, recentlyPlayedTrackIDs
  │     │     ├── PreferenceScorerV2 (计算基础权重)
  │     │     └── WeightedRandomSampler (带权抽样)
  │     │
  │     └── finalizeCurrentPlaybackSession (统一结算入口)
  │           │
  │           ▼
  │     PreferenceStatsService (内存缓存+脏标记)
  │           │ applyPlaybackOutcome → updateCachedScores(V2)
  │           │ saveStats → writeMetaOnly
  │           ▼
  │     LocalLibraryService.writeTrackMeta → meta.json
  │
  └── (独立路径) PlaybackCoordinator.smartRandomQueue
        │ 预生成整个播放列表，也使用 PreferenceScorerV2 + WeightedRandomSampler
        ▼
      playRandomTracks / playTrack → playTracks → AVAudioPlaybackService.playTracks
```

### 数据流

1. **播放事件产生**：AVAudioPlaybackService 进度定时器（100ms 间隔）→ `smartController.updateProgress`
2. **Session 追踪**：`PlaybackSessionTracker.updateProgress` 累计 playedSeconds，检查 minPlay 阈值
3. **Session 结算**：切歌/播完/停止 → `finalizeCurrentPlaybackSession` → `tracker.finalize()` → `PlaybackSessionOutcome`
4. **统计更新**：`PreferenceStatsService.applyPlaybackOutcome` → 更新内存缓存 + V2 评分重算 + 标脏
5. **写盘**：`PreferenceStatsService.saveStats` → `LocalLibraryService.writeMetaOnly` → `writeTrackMeta` → 从 PreferenceStatsService 读最新 stats 写入 sidecar JSON
6. **队列选择**：`ShuffleSession.next()` → `getAdjustedWeights()` (V2 运行时惩罚) → `WeightedRandomSampler.sample`

### 运行时惩罚流

```
ShuffleSession.getAdjustedWeights()
  │ 对每个候选 trackID:
  │   baseWeight = 从 initializeWeights 缓存的 V2 评分结果
  │   runtimeWeight = PreferenceScorerV2.applyRuntimePenalties(baseWeight, track, recentHistory, tracks)
  │     ├── 最近同曲惩罚 (≤5首: ×0.2, 6-10首: ×0.6)
  │     ├── 同artist近2首惩罚 (×0.7)
  │     ├── 同album近2首惩罚 (×0.8)
  │     └── 最低运行时权重保护 (≥0.1)
  └── 返回 adjustedWeights[UUID: Double]
```

---

## 4. 数据模型与持久化结构

### TrackSidecar (meta.json) 当前字段

sidecar 当前 schemaVersion = **6**。与偏好系统相关的字段：

```json
{
  "schemaVersion": 6,
  "id": "UUID",
  "title": "...",
  "artist": "...",
  "album": "...",
  // ... 其他元数据字段 ...
  "playCount": 5,                    // [废弃] 顶层 playCount，仅读取用于迁移
  "preferenceStats": {               // [权威] schemaVersion >= 3 时存在
    "playCount": 5,
    "completePlayCount": 3,
    "skipCount": 2,
    "quickSkipCount": 1,
    "totalPlayedSeconds": 720.5,
    "lastPlayedAt": "2026-05-10T12:00:00Z",
    "lastCompletedAt": "2026-05-10T12:04:00Z",
    "lastSkippedAt": "2026-05-10T11:58:00Z",
    "manualLikeState": "none",       // "none" | "liked" | "disliked"
    "preferenceScoreCache": 0.15,    // finalPreference 值（非 bounded）
    "effectiveWeightCache": 1.05     // baseWeight 值 (0.65~1.35)
  }
}
```

### TrackPreferenceStats 字段详解

| 字段 | 类型 | 默认值 | 含义 |
|------|------|--------|------|
| `playCount` | Int | 0 | 播放启动且超过2秒的次数（排除 tooShort） |
| `completePlayCount` | Int | 0 | 完播次数（≥85% 或 ≤12s 剩余） |
| `skipCount` | Int | 0 | 用户主动跳过次数 |
| `quickSkipCount` | Int | 0 | 快速跳过次数（<12s 或 <8% 进度） |
| `totalPlayedSeconds` | Double | 0 | 所有会话累计实际播放秒数 |
| `lastPlayedAt` | Date? | nil | 最后一次播放启动时间 |
| `lastCompletedAt` | Date? | nil | 最后一次完播时间 |
| `lastSkippedAt` | Date? | nil | 最后一次跳过时间 |
| `manualLikeState` | ManualLikeState | .none | 手动偏好覆盖 |
| `preferenceScoreCache` | Double | 0 | 缓存的 finalPreference（未经 tanh 压缩的原始值） |
| `effectiveWeightCache` | Double | 1.0 | 缓存的 baseWeight（0.65~1.35） |

### Schema 迁移

- `TrackPreferenceStats.currentSchemaVersion = 3`（内部版本号）
- `TrackSidecar.schemaVersion = 6`（sidecar 整体版本号）
- **读取迁移**：解码 sidecar 时，如果 `preferenceStats` 字段不存在且 `schemaVersion < 3`，则从顶层 `playCount` 迁移：`TrackPreferenceStats.fromLegacy(playCount:)`，假设旧播放次数全部为完播
- **写入策略**：`encode` 方法不再写入顶层 `playCount`（注释明确："We intentionally do NOT write playCount to avoid double-counting"），始终写入 `preferenceStats`
- **清理**：`PreferenceResetService` 的 `cleanupLegacyResiduals` 选项会删除顶层 `playCount`/`completePlayCount`/`skipCount` 等旧键

### 权威字段来源

- **权威来源**：`PreferenceStatsService` 内存缓存 → `preferenceStats` 字段
- **已废弃**：顶层 `playCount`（读取做迁移，写入被跳过）
- **Track.playCount**：getter 委托 `PreferenceStatsService.shared.getStats(for: id).playCount`，setter 是空操作

### 残留/冗余问题

1. `TrackSidecar.playCount: Int?` 字段仍在 CodingKeys 中，解码时读取，编码时跳过
2. `MusicLibraryScanner.ScannedTrackMeta.playCount: Int?` 仍存在，标注 DEPRECATED
3. `Track` @Model 的 `playCount: Int` 属性 getter 委托、setter 空——SwiftData 层仍有此字段
4. `PreferenceResetService.cleanupTopLevelKeys` 包含 `playCount` 等旧键名，用于清理

---

## 5. 偏好统计口径：一首歌在什么情况下会被记什么

### playCount

**规则**：累计播放时长 ≥ 2 秒即记为一次 play。
**实现位置**：`PlaybackSessionTracker` 的 `computeOutcome()`：如果 `totalPlayedSeconds < minPlayDuration (2.0)` 返回 `.tooShort`（不计 play），否则按具体 outcome 记录。
**记录位置**：`PreferenceStatsService.applyPlaybackOutcome` 中，对 `.completed`/`.skipped`/`.interrupted` 三种 outcome 都执行 `stats.playCount += 1`。

### completePlayCount

**规则**：满足以下任一条件记为完播：
1. 自然播完（tracker 被调用了 `markCompleted()`）
2. 进度 ≥ 85%（`completePlayPercentage = 0.85`）
3. 剩余时间 ≤ 12 秒（`completePlayRemainingSeconds = 12.0`）

**实现位置**：`PlaybackSessionTracker.computeOutcome()` 和 `PreferenceStatsService.applyPlaybackOutcome` 都有判定逻辑（存在重复）。

### skipCount

**规则**：当 session 结束原因为 `userInitiatedSkip` 且 `!isSeeking` 时，tracker 被标记为 `endedByUserAction`，finalize 后 outcome 为 `.skipped`，此时 `skipCount += 1`。
**重要**：如果正在 seeking，则标记为 `markEndedBySystem()`，outcome 变为 `.interrupted`，**不计 skip**。

### quickSkipCount

**规则**：在已记为 skip 的基础上，如果满足以下任一条件则额外记 quick skip：
1. 播放时长 < 12 秒（`quickSkipDuration = 12.0`）
2. 最大进度 < 8%（`quickSkipPercentage = 0.08`）

**判定位置**：`PreferenceStatsService.applyPlaybackOutcome` 中直接判定，以及 `PlaybackSessionTracker.isQuickSkip()` 方法（但后者仅在日志中使用，不在 applyToStats 中使用——**存在重复实现**）。

### totalPlayedSeconds

**规则**：每次 `updateProgress(currentTime:)` 被调用时，累加 `currentTime - lastProgressTime`（仅正值），即实际播放经过的时间。seek 期间的时间跳变会被计入（因为 progressDelta 使用 `max(0, ...)` 截断负值，但大正跳变会被计入）。
**注意**：`PlaybackSessionTracker.updateProgress` 没有上限截断。如果用户 seek 到更后面位置，progressDelta 会很大，会被计入 playedSeconds。

### lastPlayedAt / lastCompletedAt / lastSkippedAt

- `lastPlayedAt`：在 `.completed`、`.skipped`、`.interrupted` 三种 outcome 下都更新（使用 `Date()` 即结算时刻，而非 session 开始时刻）。**注意**：`PlaybackSessionTracker.applyToStats` 使用 `startTime`（session 开始时刻），而 `PreferenceStatsService.applyPlaybackOutcome` 使用 `Date()`（结算时刻）——**两个实现不一致**。
- `lastCompletedAt`：仅在 `.completed` outcome 下更新
- `lastSkippedAt`：仅在 `.skipped` outcome 下更新

### 手动 like/dislike

- `toggleManualLikeState()`：none → liked → disliked → none 循环切换
- 直接影响 `manualLikeState` 字段，通过 V2 评分器的 `manualBias` 影响基础权重
- liked: +0.18, disliked: -0.18

### preferenceScoreCache / effectiveWeightCache

- 在 `PreferenceStatsService.updateStats` 中，每次统计变更后自动调用 `PreferenceScorerV2.updateCachedScores` 重算
- `preferenceScoreCache` = `finalPreference`（未经 tanh 压缩的值）
- `effectiveWeightCache` = `baseWeight`（0.65~1.35 范围，不含运行时惩罚）

### 各种播放场景的处理

| 场景 | 处理方式 |
|------|---------|
| 播放 < 2秒后切歌 | `tooShort`：不计任何统计 |
| 播放 > 2秒后手动 next | `skipped`：playCount+1, skipCount+1, 可能 quickSkipCount+1 |
| 自然播完 | `completed`：playCount+1, completePlayCount+1 |
| 播放到 >85% 后手动 next | `completed`（因为进度够高）：同自然播完 |
| 播放到 >85% 后被中断 | `interrupted` 但记为 complete：playCount+1, completePlayCount+1 |
| Seeking 期间切歌 | `markEndedBySystem()` → `interrupted`（不计 skip） |
| App 退出 | `finalizeCurrentSession(userInitiated: false)` → `systemInterrupt` |
| Pause/Resume | 不触发 finalize，进度继续累计 |
| 上一首 (previous) | 触发 `finalizeCurrentSession(userInitiated: true)`，记 skip |
| 点击列表选歌 (jumpToTrack) | 触发 `finalizeCurrentSession(userInitiated: true)`，记 skip（**除非在 seek 中**），同时**重置 ShuffleSession** |
| 从队列选歌 (jumpToTrackInQueue) | 触发 finalize，但使用 `session.jumpTo(trackID:)` 保持序列稳定 |
| Repeat One | 不触发 autoAdvance，直接 replay 同一首歌（**不 finalize 也不记统计**——是个 bug） |

---

## 6. PlaybackSession / Tracker 真实实现

### PlaybackSessionTracker 保存的状态

| 状态 | 类型 | 说明 |
|------|------|------|
| `track` | Track | 关联的歌曲 |
| `trackDuration` | Double | 歌曲总时长 |
| `startTime` | Date | session 开始时间 |
| `lastProgressTime` | Double | 上次进度更新时的 currentTime |
| `maxProgressReached` | Double | 历史最高进度点 |
| `hasReachedMinPlayThreshold` | Bool | 是否已超过2秒 |
| `totalPlayedSeconds` | Double | 累计实际播放秒数 |
| `isCompleted` | Bool | 是否标记为自然完成 |
| `endedByUserAction` | Bool | 是否由用户操作结束 |
| `isActive` | Bool | session 是否仍在活跃 |
| `shouldDiscardStatsOnFinalize` | Bool | 一次性标记，finalize 时丢弃统计 |

### 生命周期

1. **创建**：`SmartPlaybackController.startTrackSession(track:)` → `PlaybackSessionTracker(track: track)`
2. **更新**：`smartController.updateProgress(currentTime:duration:)` → `tracker.updateProgress(currentTime:)`，累计 playedSeconds，检查 minPlay 阈值
3. **标记完成**：`tracker.markCompleted()` 或 `markEndedByUserAction()` 或 `markEndedBySystem()`
4. **结算**：`finalizeCurrentPlaybackSession(reason:)` → `tracker.finalize()` → `computeOutcome()` → 返回 `PlaybackSessionOutcome`

### accumulatedPlayedSeconds 如何累计

```swift
func updateProgress(currentTime: Double) {
    let progressDelta = max(0, currentTime - lastProgressTime)
    if progressDelta > 0 {
        totalPlayedSeconds += progressDelta
    }
    lastProgressTime = currentTime
    maxProgressReached = max(maxProgressReached, currentTime)
}
```

**问题**：
- 如果用户 seek 到后面（currentTime 大幅增加），progressDelta 会是一个大的正值，被计入 playedSeconds
- 虽然有 seek 检测（`isSeeking` 标志），但 seek 标志的清除是异步延迟的（0.3~0.5秒），在延迟窗口内仍可能有误计
- **更严重的是**：`SmartPlaybackController.updateProgress` 有自己的 seek 检测（`timeDiff > 5.0`），但 **不影响 `tracker.updateProgress` 的累计逻辑**——tracker 自身不做 seek 过滤

### Seek 标志处理

存在**双层 seek 检测**：
1. `AVAudioPlaybackService.seek(to:)` 设置 `isSeeking = true` 和 `smartController.beginSeek()`
2. `SmartPlaybackController.updateProgress` 检测 `abs(currentTime - lastProgressTime) > 5.0` 也会设 `isSeeking = true`
3. `AVAudioPlaybackService` 在 seek 后 0.3 秒清除标志
4. `SmartPlaybackController` 在检测到 seeking 后 0.5 秒清除标志

**不同步**：两者的延迟时间不同（0.3s vs 0.5s），清除时机不一致。

### userInitiated / automatic 的区分

- **userInitiated**：`nextTrack()`、`previousTrack()`、`jumpToTrack()` 调用时设 `lastChangeWasUserAction = true`
- **automatic**：`autoAdvance()` 调用时设 `lastChangeWasUserAction = false`
- 在 `finalizeCurrentSession` 中，`completedNaturally` 走 `markCompleted()`，`userInitiated` 走 `markEndedByUserAction()`（除非正在 seeking），`systemInterrupt` 走 `markEndedBySystem()`

### finalize 的统一入口

**名义上的统一入口**：`SmartPlaybackController.finalizeCurrentPlaybackSession(reason:source:)`

**实际调用点**：
1. `nextTrack()` → `finalizeCurrentSession(userInitiated: true)`
2. `previousTrack()` → `finalizeCurrentSession(userInitiated: true)`
3. `autoAdvance()` → `finalizeCurrentSession(userInitiated: false, completedNaturally: true)`
4. `jumpToTrack()` → `finalizeCurrentSession(userInitiated: true)`
5. `jumpToTrackInQueue()` → `finalizeCurrentSession(userInitiated: true)`
6. `stop()` → `finalizeCurrentSession(userInitiated: false)`
7. `handleAppWillTerminate` → `finalizeCurrentSession(userInitiated: false)`
8. `startTrackSession` 中的安全网：如果已有 tracker 未 finalize，会自动 finalize

**未走统一入口的路径**：
- `AVAudioPlaybackService.stopPlayback(clearQueue: true)` → `smartController.stop()` → 会 finalize
- **Repeat One 场景**：`finalizePlaybackCompletion` 中 `repeatMode == .one` 时直接 `playInternal(track: track)`，**不经过 smartController，也不 finalize 上一首歌的 session**——这意味着 repeat one 播放时，第一遍之后的重播都不会被统计

---

## 7. 偏好分数算法与权重映射

### V2 算法完整公式

#### 步骤 1：提取特征 (PreferenceFeatures)

```
plays = max(Double(playCount), 1.0)
completionRate = Double(completePlayCount) / plays
skipRate = Double(skipCount) / plays
quickSkipRate = Double(quickSkipCount) / plays
avgListenRatio = clamp(totalPlayedSeconds / (duration * plays), 0, 1.05)
confidence = min(log2(plays + 1) / 3.0, 1.0)
```

confidence 查找表：
- 1 play: log2(2)/3 = 0.33
- 3 plays: log2(4)/3 = 0.67
- 7 plays: log2(8)/3 = 1.0 (满置信)

#### 步骤 2：计算原始偏好分

```
completionCentered = completionRate - 0.5
listenCentered = avgListenRatio - 0.5

rawPreference = 0.8 × completionCentered
              + 0.6 × listenCentered
              + (-0.9) × quickSkipRate
              + (-0.3) × skipRate
```

**含义**：
- 完成率偏离50%的部分，权重0.8（正向奖励）
- 收听比例偏离50%的部分，权重0.6（正向奖励）
- 快速跳过率，权重-0.9（强负向惩罚）
- 普通跳过率，权重-0.3（弱负向惩罚）

#### 步骤 3：低样本保护

```
conservativePreference = rawPreference × confidence
```

1次播放的 confidence = 0.33，所以偏好分会被压到33%；7次以上满置信。

#### 步骤 4：手动偏好修正

```
manualBias = +0.18 (liked)
           | -0.18 (disliked)
           |  0.00 (none)

finalPreference = conservativePreference + manualBias
```

#### 步骤 5：偏好压缩（饱和函数）

```
boundedPreference = tanh(finalPreference × 1.4)
```

结果范围 [-1.0, 1.0]。

#### 步骤 6：映射到基础权重

```
baseWeight = 1.0 + 0.35 × boundedPreference
```

结果范围 [0.65, 1.35]。

#### 运行时惩罚（临时调整，不持久化）

```
if 同曲在最近5首内: weight × 0.2
if 同曲在6-10首内: weight × 0.6
if 同artist在最近2首内: weight × 0.7
if 同album在最近2首内: weight × 0.8
最低运行时权重: 0.1
```

### preferenceScoreCache / effectiveWeightCache 更新时机

- 每次 `PreferenceStatsService.updateStats` 调用时，自动调用 `PreferenceScorerV2.updateCachedScores`
- 每次 `applyPlaybackOutcome` 后自动重算
- 手动 like/dislike 后自动重算
- **运行时惩罚不写入缓存**，仅在 ShuffleSession 抽样时实时计算

### 典型值示例

| 场景 | plays | complete | skip | quickSkip | listened(s) | duration(s) | manualLike | baseWeight |
|------|-------|----------|------|-----------|-------------|-------------|------------|------------|
| 新歌（0次） | 0→1 | 0 | 0 | 0 | 0 | 240 | none | 1.000 |
| 1次快速跳过 | 1 | 0 | 1 | 1 | 5 | 240 | none | ~0.765 |
| 2次1完1快跳 | 2 | 1 | 1 | 1 | 120 | 240 | none | ~0.898 |
| 12次9完1跳 | 12 | 9 | 1 | 0 | 2400 | 240 | none | ~1.252 |
| 10次1完6跳4快跳 | 10 | 1 | 6 | 4 | 600 | 240 | none | ~0.735 |
| 手动 liked | 5 | 4 | 0 | 0 | 1100 | 240 | liked | ~1.260 |
| 手动 disliked | 8 | 5 | 2 | 1 | 1400 | 240 | disliked | ~1.006 |

### 魔法数字清单

| 常量 | 值 | 用途 |
|------|----|------|
| `minBaseWeight` | 0.65 | 基础权重下限 |
| `maxBaseWeight` | 1.35 | 基础权重上限 |
| `weightRange` | 0.35 | 偏离中性的最大幅度 |
| `confidenceDenominator` | 3.0 | 低样本保护分母 |
| `completionRateCoeff` | 0.8 | 完成率系数 |
| `listenRatioCoeff` | 0.6 | 收听比例系数 |
| `quickSkipRateCoeff` | -0.9 | 快速跳过率系数 |
| `skipRateCoeff` | -0.3 | 跳过率系数 |
| `manualLikedBias` | 0.18 | 手动喜欢修正 |
| `manualDislikedBias` | -0.18 | 手动不喜欢修正 |
| `compressionFactor` | 1.4 | tanh 压缩因子 |
| `sameTrackRecent5` | 0.2 | 同曲5首内惩罚 |
| `sameTrackRecent10` | 0.6 | 同曲6-10首惩罚 |
| `sameArtistRecent2` | 0.7 | 同artist近2首惩罚 |
| `sameAlbumRecent2` | 0.8 | 同album近2首惩罚 |
| `minimumRuntimeWeight` | 0.1 | 运行时权重下限 |
| `minPlayDuration` | 2.0s | 最短播放时间阈值 |
| `completePlayPercentage` | 0.85 | 完播进度阈值 |
| `completePlayRemainingSeconds` | 12.0s | 完播剩余时间阈值 |
| `quickSkipDuration` | 12.0s | 快速跳过时长阈值 |
| `quickSkipPercentage` | 0.08 | 快速跳过进度阈值 |
| `minRemainingThreshold` | 5 | 队列最低剩余触发扩展 |
| `extensionBatchSize` | 10 | 每次扩展批量数 |
| `maxHistorySize` | 50 | 最大历史记录数 |

---

## 8. 随机队列 / ShuffleSession 实现

### ShuffleSession 包含的字段

| 字段 | 类型 | 说明 |
|------|------|------|
| `sourceSnapshotTrackIDs` | [UUID] | 源候选曲目池 |
| `generatedTrackIDs` | [UUID] | 已生成的随机序列 |
| `currentIndex` | Int | 当前位置（-1 = 未开始） |
| `recentlyPlayedTrackIDs` | [UUID] | 最近播放历史（最新在后） |
| `trackCache` | [UUID: Track] | 曲目元数据缓存 |
| `baseWeights` | [UUID: Double] | 基础权重缓存（V2 评分结果） |
| `isActive` | Bool | session 是否活跃 |
| `trackLoader` | ((UUID) -> Track?)? | 外部注入的加载回调 |

### generatedTrackIDs

是的，存在。是核心序列。

### currentIndex

是的，存在。从 -1 开始，指向当前播放位置。

### sourceSnapshotTrackIDs

是的，记录了源曲目池的快照。

### recentlyPlayedTrackIDs (history)

是的，最多 50 条，用于运行时惩罚计算。

### 队列在什么时候生成

1. `start(from:tracks:)` 时：清空序列，将起始歌加入序列头，然后调用 `extendQueueIfNeeded()` 生成初始批量
2. 每次 `next()` 后调用 `extendQueueIfNeeded()`
3. 每次 `rebuild()` 后调用 `extendQueueIfNeeded()`

### 队列如何扩展

当 `generatedTrackIDs.count - (currentIndex + 1) < 5` 时，调用 `extendQueue(by: 10)`：
1. 收集已调度但未播放的 trackID（从 currentIndex-5 到末尾），排除这些以避免近期重复
2. 如果过滤后无候选，回退到全量 sourceSnapshotTrackIDs
3. 获取运行时调整后的权重 `getAdjustedWeights()`
4. 调用 `WeightedRandomSampler.sampleMultiple` 无放回抽样 10 首

### 上一首 / 下一首逻辑

- **next()**：currentIndex + 1，如果已有预生成的下一首直接使用（**这就是为什么"返回上一首后再下一首不会变歌"**），否则实时生成新的一首
- **previous()**：currentIndex - 1，返回已有序列中的上一首。**不修改历史记录**，保持"前进能回到原位"的行为

### jumpToTrack 的行为

- `jumpToTrack()`（从列表直接选歌）：**重置整个 ShuffleSession**，调用 `session.start(from: track.id, tracks: sourceTracks)`，完全重新生成序列
- `jumpToTrackInQueue()`（从当前队列选歌）：使用 `session.jumpTo(trackID:)`，保持序列不变，只移动 currentIndex 和更新历史

### 用户点击列表项时

取决于入口：
- 通过 PlaybackCoordinator 的 `playRandomTracks`/`playTrack` → 重建整个 session
- 通过 `playTrackFromQueue` → 保持 session 稳定

### 随机队列与偏好权重的结合

1. `start()` 时调用 `initializeWeights(tracks:)`，为每首歌用 V2 scorer 计算 baseWeight
2. 每次需要抽样时调用 `getAdjustedWeights()`，对每个 baseWeight 应用运行时惩罚
3. 将调整后的权重传给 `WeightedRandomSampler`

### 偏好权重更新时机

- **初始化时**：`initializeWeights` 使用当前 stats 计算一次
- **不会在播放过程中实时更新**：即使 stats 在播放过程中被 finalize 更新了，baseWeights 不会被刷新，直到下一次 `rebuild` 或 `start`

---

## 9. 带权抽样实现细节

### 候选集来源

- `sourceSnapshotTrackIDs`：在 `start(from:tracks:)` 时从外部传入
- `extendQueue` 时会过滤掉 "已调度但未播放" 的近期曲目（从 currentIndex-5 到末尾的 trackIDs）

### 过滤条件

1. 排除 `exclude` 参数（通常是当前正在播放的 trackID）
2. 在 `extendQueue` 时额外排除已调度的近期曲目
3. 如果过滤后无候选，回退到全量候选集

### 权重组合

1. `baseWeights[trackID]`：V2 评分器计算的 baseWeight (0.65~1.35)
2. 运行时惩罚后的 `adjustedWeights[trackID]`：baseWeight × 同曲/同artist/同album 惩罚系数，下限 0.1
3. 无权重的 trackID 使用默认值 1.0

### 最近播放项的处理

- **不是完全排除**，而是降权
- 同曲在最近5首内：权重 × 0.2（大幅降权但仍可选中）
- 同曲在6-10首内：权重 × 0.6

### 曲库很小时的处理

- `WeightedRandomSampler`：如果总权重为 0，回退到均匀随机
- `extendQueue`：如果过滤后无候选，回退到全量 sourceSnapshotTrackIDs
- 运行时惩罚下限 0.1，防止曲库小时彻底封杀

### 抽样方法

**轮盘赌法（Cumulative Weight / Random Threshold）**：

```swift
// 单次抽样
let totalWeight = candidates.reduce(0) { $0 + (weights[$1] ?? 1.0) }
var randomValue = Double.random(in: 0..<totalWeight)
for trackID in candidates {
    randomValue -= weights[trackID] ?? 1.0
    if randomValue <= 0 { return trackID }
}
return candidates.last  // 浮点兜底
```

**批量无放回抽样**：每次选中一首后从候选集中移除，重新计算总权重，再抽下一首。

### Fallback

- 总权重为 0 → 均匀随机
- 无候选 → 返回 nil
- 浮点精度兜底 → 返回最后一个候选

### 潜在问题

- **极端偏置**：如果某首歌的权重远高于其他（如 1.35 vs 0.65），在大量候选中会被不成比例地选中
- **小曲库**：3首歌时，即使降权，仍可能在短时间内重复
- **baseWeights 不实时更新**：在长时间播放会话中，偏好统计在切歌时更新，但 shuffle session 的 baseWeights 不会刷新

---

## 10. 主播放链路接入点

### 主导播放模式选择的控制器

**AVAudioPlaybackService** 内部的 `SmartPlaybackController` 实例。`SmartPlaybackController` 是实际执行 next/previous/auto-advance 逻辑的控制器。

### 原有随机播放逻辑是否被完全替换

**是的。** `AVAudioPlaybackService` 不再有独立的随机逻辑，所有随机操作都委托给 `SmartPlaybackController`。

但 `PlaybackCoordinator` 仍有 `smartRandomQueue` 静态方法，它会**预生成整个播放列表**再交给 `AVAudioPlaybackService.playTracks`。这个路径绕过了 ShuffleSession 的动态扩展机制——它生成的是固定列表，后续的 next/previous 仍走 SmartPlaybackController，但初始的 playTracks 调用已经预洗了整组曲目。

### 各导航方法的路径

| 用户操作 | 调用链 |
|---------|-------|
| Next 按钮 | `AVAudioPlaybackService.next()` → `syncShuffleStateIfNeeded()` → `smartController.nextTrack()` → `shuffleSession.next()` → finalize 旧 session → start 新 session |
| Previous 按钮 | `AVAudioPlaybackService.previous()` → 如果 >3秒则 seek(0)（不切歌），否则 `smartController.previousTrack()` → `shuffleSession.previous()` |
| 自然播完 | `handlePlaybackCompletion` → `smartController.autoAdvance()` → `shuffleSession.next()` + `markCompleted()` |
| 点击列表选歌 | `PlaybackCoordinator.playTrack()` → `smartRandomQueue()` 生成列表 → `playTracks()` → `smartController.startPlayback()` **重置 session** |
| 从队列选歌 | `AVAudioPlaybackService.playTrackFromQueue()` → `smartController.jumpToTrackInQueue()` → `shuffleSession.jumpTo()` **保持 session** |
| 开/关 Shuffle | `AVAudioPlaybackService.setShuffleEnabled()` → `smartController.setShuffle()` → 创建/销毁 ShuffleSession |

### 仍存在旧随机逻辑残留

`PlaybackCoordinator.smartRandomQueue` 和 `randomQueue` 方法仍有自己的加权抽样逻辑，使用 `WeightedRandomSampler.sample` 直接抽样。这与 ShuffleSession 的动态扩展是**两套独立逻辑**：
- `smartRandomQueue`：预生成完整列表（一次性格式化整个播放队列）
- `ShuffleSession`：动态扩展队列（按需生成下一批）

### 顺序/随机/playOneAndStop 的切换

- **顺序播放**：`isShuffleEnabled = false`，`shuffleSession = nil`，使用 `currentSourceIndex` 线性导航
- **随机播放**：`isShuffleEnabled = true`，创建 `ShuffleSession`
- **Repeat One**：`finalizePlaybackCompletion` 中直接 replay，**绕过 SmartPlaybackController**（不 finalize 也不记统计——这是 bug）
- **Stop After Track**：`finalizePlaybackCompletion` 中设 `isPlaying = false`，不触发 auto-advance

---

## 11. 写盘与 sidecar 更新链路

### 哪些时机会触发写盘

| 时机 | 触发方式 | 确定性 |
|------|---------|--------|
| 切歌/播完时 finalize | `PreferenceStatsService.shared.saveStats(for:)` | 确定 |
| 手动 like/dislike | `LocalLibraryService.shared.writeMetaOnly(for:, reason: "manualLike")` | 确定 |
| 偏好重置 | `PreferenceResetService` 直接写 meta.json | 确定 |
| app 退出 | `SmartPlaybackController.handleAppWillTerminate` → `saveAllPending()` | **不确定**（见下） |
| app 退到后台 | `PreferenceStatsLifecycleHandler` → `saveAllPending()` | **从未触发**（handler 未初始化） |
| 定时5分钟 | `PreferenceStatsLifecycleHandler` 的 Timer | **从未触发**（handler 未初始化） |
| 通知 `preferenceStatsShouldSave` | `SmartPlaybackController.handleSaveRequest` | 仅在 sourceTracks 中找到对应 track 时有效 |

### 由谁调用写盘

**主路径**：`SmartPlaybackController.finalizeCurrentPlaybackSession` → `PreferenceStatsService.shared.saveStats(for: track)` → `LocalLibraryService.shared.writeMetaOnly(for: track, reason: "playbackStats")`

**手动 like**：`Track.toggleManualLikeState()` → `LocalLibraryService.shared.writeMetaOnly(for: self, reason: "manualLike")`

**批量保存**：`PreferenceStatsService.shared.saveAllPending(trackProvider:)` → 遍历 dirtyTrackIDs → 对每个调用 `writeMetaOnly`

### 最终调用哪个 service 写回

`LocalLibraryService.shared.writeTrackMeta(for:references:)`：
1. 从 `PreferenceStatsService.shared.getStats(for: track.id)` 获取最新 stats
2. 构建 `TrackSidecar` 实例，包含 `preferenceStats` 字段
3. JSON encode → 原子写入 meta.json

### 是否立即落盘还是仅更新缓存

**切歌时是立即同步落盘**：`saveStats` → `writeMetaOnly` → `writeTrackMeta` → `data.write(to:, options: .atomic)`

### 是否有 debounce / batching / actor / async queue

**没有 debounce**。每次切歌都立即写盘。
**有 dirty set**。`dirtyTrackIDs` 跟踪需要保存的 track，`saveAllPending` 批量处理。
**没有 async queue**。写盘是同步操作。

### 是否可能出现改了内存但没写盘

**可能**。以下场景会导致内存更新但未写盘：
1. **`PreferenceStatsLifecycleHandler` 未初始化**：app 退到后台或定期保存的机制完全失效
2. **app 强制退出**：`handleAppWillTerminate` 是同步调用，但 `saveAllPending` 内部有 async 路径，强退时可能未完成
3. **`saveAllPending` 的 fallback 通知路径**：如果没有 `trackProvider`，发 `preferenceStatsShouldSave` 通知，由 `SmartPlaybackController.handleSaveRequest` 处理——但此时只能在 `sourceTracks` 中找到当前播放队列的歌，**不在当前队列中的歌的更新会丢失**
4. **Repeat One 场景**：不 finalize，内存中的 stats 变更不会触发写盘

### 是否在 app 退出时能稳定更新

**部分**。`SmartPlaybackController.handleAppWillTerminate` 会 finalize 当前 session 并调用 `saveAllPending`。但：
- `saveAllPending` 的 `trackProvider` 路径需要遍历 sourceTracks 查找 track 对象
- 如果 app 退出时 sourceTracks 已被清空或不完整，部分 track 可能无法写入
- `PreferenceStatsLifecycleHandler` 从未初始化，所以不会额外保存

### 日志与错误处理

- `writeMetaOnly` 失败时会 `Log.error`
- `finalizeCurrentPlaybackSession` 中有写盘验证（检查文件修改时间）
- `PreferenceResetService` 中有失败收集和 `Log.error`

---

## 12. 当前实现与原始预期的对比

### 已实现

| 功能 | 状态 | 说明 |
|------|------|------|
| 动态扩展稳定随机队列 | ✅ 已实现 | ShuffleSession 维护稳定序列，支持前后导航 |
| 偏好学习 (V2 算法) | ✅ 已实现 | 比例特征+低样本保护+tanh压缩+温和区间 |
| Quick skip 统计 | ✅ 已实现 | <12s 或 <8% 判定 |
| Sidecar 持久化 | ✅ 已实现 | 写盘链路打通，preferenceStats 写入 meta.json |
| 完播 / 跳过 / 中断区分 | ✅ 已实现 | 三种 outcome 有不同统计逻辑 |
| 运行时惩罚 | ✅ 已实现 | 同曲/同artist/同album 近邻惩罚 |
| 手动 like/dislike | ✅ 已实现 | none→liked→disliked→none 循环 |
| 偏好重置 | ✅ 已实现 | 批量重置+旧字段清理 |
| 统一结算入口 | ✅ 大体实现 | finalizeCurrentPlaybackSession 覆盖主要路径 |
| Seek 检测 | ⚠️ 部分实现 | 双层检测，不完全同步 |

### 未完成 / 偏差 / 妥协

| 功能 | 状态 | 说明 |
|------|------|------|
| 生命周期自动保存 | ❌ 失效 | `PreferenceStatsLifecycleHandler` 从未初始化 |
| Repeat One 统计 | ❌ 未接入 | repeat one 直接 replay，不 finalize 也不记统计 |
| baseWeights 实时更新 | ❌ 未实现 | 长时间播放中 stats 更新后 baseWeights 不刷新 |
| PlaybackSessionTracker.applyToStats 与 PreferenceStatsService.applyPlaybackOutcome 重复 | ⚠️ 双重实现 | 两个地方都有统计更新逻辑，且 lastPlayedAt 取值不一致 |
| PlayCountService 完全清理 | ❌ 残留 | 文件仍存在，无调用点但未删除 |
| Track.playCount setter | ⚠️ 空操作 | SwiftData 字段残留，setter 是 no-op |
| 播放进度 seek 对 playedSeconds 的影响 | ⚠️ 不准确 | tracker 不区分 seek 和正常播放的时间累计 |
| jumpToTrack 重置整个 session | ⚠️ 设计偏差 | 可能不是预期行为，用户从列表选歌会丢失当前随机序列 |

---

## 13. 风险、问题与遗留点

### 高优先级

1. **`PreferenceStatsLifecycleHandler` 从未初始化**（`PreferenceStatsExtensions.swift:168`）
   - **风险**：app 退到后台不保存，定时保存不生效，app 非正常退出时可能丢失统计
   - **原因**：`static let shared` 单例定义了，但没有任何代码访问它来触发 lazy 初始化
   - **影响**：所有非切歌时刻的统计变更（如果有的话）可能丢失

2. **Repeat One 不记统计**（`AVAudioPlaybackService.swift:596-598`）
   - **风险**：用户重复播放同一首歌多次，只有第一次被记为 play
   - **原因**：`repeatMode == .one` 时直接调用 `playInternal(track:)` 重播，不经过 `smartController.autoAdvance()`，不 finalize 上一轮 session
   - **影响**：统计严重偏差——最常 repeat one 的歌反而统计偏低

3. **`PlaybackSessionTracker.applyToStats` 与 `PreferenceStatsService.applyPlaybackOutcome` 双重实现**
   - **风险**：两处逻辑不一致：
     - `lastPlayedAt` 取值不同：tracker 用 `startTime`（session 开始时刻），service 用 `Date()`（结算时刻）
     - `.completed` 时 `totalPlayedSeconds` 取值不同：tracker 加实际累计值，service 加 `trackDuration`（假设整首播完）
   - **原因**：`applyToStats` 是早期实现，`applyPlaybackOutcome` 是后来的主路径实现，但未清理前者
   - **实际影响**：当前主路径只使用 `applyPlaybackOutcome`，`applyToStats` 没有被调用

4. **Seek 对 playedSeconds 的影响未过滤**（`PlaybackSessionTracker.swift:93-96`）
   - **风险**：用户 seek 到歌的后半段，seek 期间的时间跳变被计入 `totalPlayedSeconds`，使 avgListenRatio 虚高
   - **原因**：`updateProgress` 中 `progressDelta = max(0, currentTime - lastProgressTime)`，大正跳变也会被计入
   - **影响**：评分算法的 `avgListenRatio` 输入可能失真

### 中优先级

5. **双层 seek 检测不同步**（`AVAudioPlaybackService.swift:447` vs `SmartPlaybackController.swift:338`）
   - **风险**：两者使用不同的延迟时间（0.3s vs 0.5s），可能在短暂窗口内对同一次操作有不同判断
   - **影响**：极端情况下，seek 后 0.3s~0.5s 窗口内切歌可能被误判为 skip

6. **baseWeights 不实时更新**（`ShuffleSession.swift:289-300`）
   - **风险**：长时间播放会话中，偏好统计在每次切歌时更新，但 ShuffleSession 的 baseWeights 只在 start/rebuild 时初始化
   - **影响**：随播放进行，队列中各歌的权重可能越来越偏离真实偏好

7. **jumpToTrack 重置整个 ShuffleSession**（`SmartPlaybackController.swift:278-293`）
   - **风险**：用户从列表选歌会丢失整个随机序列历史，重新洗牌
   - **设计意图**：可能是有意为之（从列表选歌视为新的播放意图）
   - **对比**：`jumpToTrackInQueue` 保持序列稳定

8. **PlaybackCoordinator.smartRandomQueue 预生成整个列表**（`PlaybackCoordinator.swift:334-385`）
   - **风险**：与 ShuffleSession 的动态扩展机制重复，且在大型曲库中可能性能不佳
   - **原因**：`playRandomTracks` 和 `playTrack` 走这个路径，先预洗整个列表再交给 SmartPlaybackController

9. **`saveAllPending` 的 trackProvider fallback**（`PreferenceStatsService.swift:213-220`）
   - **风险**：没有 trackProvider 时发通知，但 `SmartPlaybackController.handleSaveRequest` 只能在 `sourceTracks` 中查找——不在当前播放队列中的歌无法写入
   - **影响**：如果某首歌的 stats 更新了但不在当前队列中，其更新可能丢失

10. **Track.playCount 的 SwiftData 字段残留**（`Track.swift:107-115`）
    - **风险**：getter 委托 PreferenceStatsService，setter 是空操作——如果旧代码尝试通过 setter 设置值，会静默丢失
    - **当前影响**：无调用点使用 setter

### 低优先级

11. **PlayCountService 是完全的死代码**（`PlayCountService.swift`）
    - **风险**：无调用点，但文件仍存在，可能造成混淆
    - **影响**：无实际影响，但增加代码噪音

12. **ShuffleQueueManager 是完全的死代码**（`ShuffleQueueManager.swift`）
    - **风险**：使用均匀随机的简单队列，与 ShuffleSession（加权随机）功能重叠，无任何调用点
    - **影响**：增加代码噪音，可能造成维护混淆

12. **preferenceScoreCache 存储的是 finalPreference 而非 boundedPreference**
    - **设计意图**：代码注释说"缓存可解释的最终偏好值（非 bounded），bounded 后的值压缩太厉害不好读"
    - **风险**：UI 或其他消费方如果期望看到 [-1, 1] 范围的值，可能会困惑
    - **当前影响**：`HomeViewModel` 和 `LibraryViewModel` 使用 `preferenceScoreCache` 做排序，数值范围不确定

13. **`PreferenceScorerV2Samples` 中 hardcode 的样例数据**（`PreferenceScorerV2Samples.swift`）
    - **风险**：仅调试用，不应在 production 代码中存在
    - **当前影响**：需要手动调用 `printAllSamples()` 才会执行

---

## 14. 建议的后续动作

### 必修修复

1. **初始化 `PreferenceStatsLifecycleHandler`**
   - 在 `AppSessionHost` 或 `myPlayer2App` 中添加 `_ = PreferenceStatsLifecycleHandler.shared` 来触发初始化
   - 原因：不修复意味着 app 退到后台和定时保存完全失效

2. **修复 Repeat One 不记统计的问题**
   - 在 `finalizePlaybackCompletion` 的 repeat one 分支中，先 finalize 当前 session，再 replay
   - 原因：repeat one 是常见的使用模式，不记统计会导致偏好数据严重偏差

3. **统一 `applyToStats` 和 `applyPlaybackOutcome` 的逻辑**
   - 删除 `PlaybackSessionTracker.applyToStats` 方法（当前无调用点），统一使用 `PreferenceStatsService.applyPlaybackOutcome`
   - 原因：双重实现容易导致维护时遗漏同步更新

### 建议优化

4. **修复 seek 对 playedSeconds 的误计**
   - 在 `PlaybackSessionTracker.updateProgress` 中，如果检测到大跳变（>5s），不应将其计入 `totalPlayedSeconds`
   - 原因：seek 导致的虚高 playedSeconds 会扭曲评分算法

5. **统一 seek 检测逻辑**
   - 将 `AVAudioPlaybackService` 和 `SmartPlaybackController` 的 seek 检测合并为单一机制
   - 原因：双层检测不同步可能造成误判

6. **在 finalize 后刷新 ShuffleSession 的 baseWeights**
   - 在 `finalizeCurrentPlaybackSession` 结束后，对受影响的 track 调用 `shuffleSession.updateWeight(for:, weight:)`
   - 原因：长时间播放中权重会逐渐失真

7. **清理 PlayCountService 和 Track.playCount setter**
   - 删除 `PlayCountService.swift` 或至少标注为不可用
   - 清理 `Track.playCount` 的 SwiftData 字段（需要数据迁移）
   - 原因：死代码和空操作 setter 增加维护负担

### 可选增强

8. **考虑移除 `PlaybackCoordinator.smartRandomQueue` 的预生成逻辑**
   - 统一使用 ShuffleSession 的动态扩展机制
   - 原因：两套随机逻辑并存增加复杂度

9. **为 `jumpToTrack` 提供不重置 session 的选项**
   - 参考 `jumpToTrackInQueue` 的实现，在普通列表选歌时也保持 session 稳定
   - 原因：当前行为可能不是用户预期

10. **为 `preferenceScoreCache` 添加范围文档**
    - 明确记录该字段存储的是 `finalPreference`（未经 tanh 压缩），而非 `boundedPreference`
    - 原因：消费方可能误判数值范围

---

## 15. 附录：关键调用链 / 伪代码 / 关键片段摘要

### 关键方法签名

```swift
// PreferenceScorerV2
static func calculateScore(stats: TrackPreferenceStats, duration: Double, manualLikeState: ManualLikeState) -> PreferenceScoreResult
static func updateCachedScores(stats: inout TrackPreferenceStats, duration: Double) -> PreferenceScoreResult
static func applyRuntimePenalties(baseWeight: Double, track: Track, recentHistory: [UUID], tracks: [UUID: Track]) -> Double

// ShuffleSession
func start(from trackID: UUID?, tracks: [Track])
func next() -> UUID?
func previous() -> UUID?
func jumpTo(trackID: UUID)
func rebuild(with newTrackIDs: [UUID], tracks: [Track])
func updateWeight(for trackID: UUID, weight: Double)

// SmartPlaybackController
func startPlayback(tracks: [Track], startingAt index: Int, shuffle: Bool)
func nextTrack()
func previousTrack()
func autoAdvance() -> Track?
func jumpToTrack(_ track: Track)
func jumpToTrackInQueue(_ track: Track)
func updateProgress(currentTime: Double, duration: Double)
func beginSeek() / func endSeek()
func discardCurrentSessionStatsOnFinalizeOnce()

// PlaybackSessionTracker
func updateProgress(currentTime: Double)
func markCompleted()
func markEndedByUserAction()
func markEndedBySystem()
func finalize() -> PlaybackSessionOutcome
func isQuickSkip() -> Bool
func discardStatsOnFinalizeOnce()

// PreferenceStatsService
func getStats(for trackID: UUID) -> TrackPreferenceStats
func updateStats(for trackID: UUID, duration: Double, update: (inout TrackPreferenceStats) -> Void) -> Bool
func applyPlaybackOutcome(trackID: UUID, outcome: PlaybackSessionOutcome, trackDuration: Double) -> Bool
func saveStats(for track: Track)
func saveAllPending(trackProvider: ((UUID) -> Track?)?)
func loadStats(from sidecar: TrackSidecar)
func setManualLikeState(trackID: UUID, state: ManualLikeState)
func toggleManualLikeState(trackID: UUID) -> ManualLikeState

// WeightedRandomSampler
static func sample(from candidates: [UUID], weights: [UUID: Double], exclude: UUID?) -> UUID?
static func sampleMultiple(from candidates: [UUID], weights: [UUID: Double], count: Int, exclude: UUID?) -> [UUID]

// LocalLibraryService
func writeMetaOnly(for track: Track, reason: String) -> Bool
```

### 关键调用链

**1. 正常播放切歌 (Next)**：
```
用户按 Next
  → AVAudioPlaybackService.next()
  → syncShuffleStateIfNeeded()
  → smartController.nextTrack()
    → lastChangeWasUserAction = true
    → finalizeCurrentSession(userInitiated: true)
      → finalizeCurrentPlaybackSession(reason: .userInitiatedSkip)
        → tracker.markEndedByUserAction() (如果不在seek中)
        → tracker.finalize() → PlaybackSessionOutcome
        → PreferenceStatsService.applyPlaybackOutcome(trackID, outcome, duration)
          → updateStats { stats变更 } → V2.updateCachedScores → statsCache更新 → dirtyTrackIDs插入
        → PreferenceStatsService.saveStats(for: track)
          → LocalLibraryService.writeMetaOnly → writeTrackMeta → atomic write
    → shuffleSession.next() → WeightedRandomSampler 或已有序列
    → startTrackSession(newTrack) → new PlaybackSessionTracker
    → onPlayTrack(newTrack) → AVAudioPlaybackService.playInternal
```

**2. 自然播完自动切歌**：
```
AVAudioPlayerNode completion callback
  → handlePlaybackCompletion(token:)
  → finalizePlaybackCompletion(token:)
    → if stopAfterTrack: stop (不切歌)
    → if repeatMode == .one: playInternal(同一首歌) ⚠️ 不记统计
    → smartController.autoAdvance()
      → lastChangeWasUserAction = false
      → finalizeCurrentSession(userInitiated: false, completedNaturally: true)
        → tracker.markCompleted()
        → 同上 finalize 流程
      → shuffleSession.next()
      → startTrackSession + onPlayTrack
```

**3. 手动 like**：
```
Track.toggleManualLikeState()
  → PreferenceStatsService.setManualLikeState(trackID, state)
    → updateStats { stats.manualLikeState = state }
      → V2.updateCachedScores → 重算权重缓存
  → LocalLibraryService.writeMetaOnly(for: self, reason: "manualLike")
```

### 关键伪代码

**V2 评分完整流程**：
```
输入: TrackPreferenceStats, duration, manualLikeState

plays = max(playCount, 1)
completionRate = completePlayCount / plays
skipRate = skipCount / plays
quickSkipRate = quickSkipCount / plays
avgListenRatio = clamp(totalPlayedSeconds / (duration * plays), 0, 1.05)
confidence = min(log2(plays + 1) / 3.0, 1.0)

rawPreference = 0.8*(completionRate-0.5) + 0.6*(avgListenRatio-0.5) - 0.9*quickSkipRate - 0.3*skipRate
conservativePreference = rawPreference * confidence
finalPreference = conservativePreference + manualBias(liked:+0.18, disliked:-0.18)
boundedPreference = tanh(finalPreference * 1.4)        // [-1, 1]
baseWeight = 1.0 + 0.35 * boundedPreference           // [0.65, 1.35]
```

**Session outcome 判定**：
```
if playedSeconds < 2.0:
    → tooShort (不计任何统计)

if markCompleted:
    → completed

if progress >= 85% or remaining <= 12s:
    → completed (即使被标记为skip)

if endedByUserAction and not seeking:
    → skipped(progress, playedSeconds)
    if playedSeconds < 12 or progress < 8%: quickSkip = true

else:
    → interrupted(progress, playedSeconds)
    if progress >= 85% or remaining <= 12s: also completePlay
```

### 关键阈值常量汇总

| 常量 | 值 | 所属类 |
|------|----|----|
| minPlayDuration | 2.0s | PlaybackSessionTracker |
| completePlayPercentage | 85% | PlaybackSessionTracker |
| completePlayRemainingSeconds | 12.0s | PlaybackSessionTracker |
| quickSkipDuration | 12.0s | PlaybackSessionTracker |
| quickSkipPercentage | 8% | PlaybackSessionTracker |
| minBaseWeight | 0.65 | PreferenceAlgorithmV2 |
| maxBaseWeight | 1.35 | PreferenceAlgorithmV2 |
| compressionFactor | 1.4 | PreferenceAlgorithmV2 |
| manualLikedBias | +0.18 | PreferenceAlgorithmV2 |
| manualDislikedBias | -0.18 | PreferenceAlgorithmV2 |
| sameTrackRecent5 | ×0.2 | RuntimePenalty |
| sameTrackRecent10 | ×0.6 | RuntimePenalty |
| sameArtistRecent2 | ×0.7 | RuntimePenalty |
| sameAlbumRecent2 | ×0.8 | RuntimePenalty |
| minimumRuntimeWeight | 0.1 | RuntimePenalty |
| minRemainingThreshold | 5 | ShuffleSession |
| extensionBatchSize | 10 | ShuffleSession |
| maxHistorySize | 50 | ShuffleSession |
| previous restart threshold | 3s | AVAudioPlaybackService |
| seek clear delay | 0.3s / 0.5s | AVAudioPlaybackService / SmartPlaybackController |
| progress timer interval | 100ms | AVAudioPlaybackService |
| periodic save interval | 300s (5min) | PreferenceStatsLifecycleHandler (未初始化) |

### 关键状态枚举

```swift
enum ManualLikeState: String, Codable {
    case none, liked, disliked
}

enum PlaybackSessionOutcome: Equatable {
    case completed
    case skipped(progress: Double, playedSeconds: Double)
    case interrupted(progress: Double, playedSeconds: Double)
    case tooShort
}

enum SessionEndReason {
    case completedNaturally
    case userInitiatedSkip
    case systemInterrupt
    case appTermination
}
```

---

*报告结束。所有内容基于 2026-05-10 main 分支 (15b61da) 代码现状。*
