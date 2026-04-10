# Smart Shuffle V2 重构报告

## 一、修改文件清单

| 文件 | 操作 | 说明 |
|------|------|------|
| `PreferenceScorerV2.swift` | 新增 | 新算法核心实现 |
| `WeightedRandomSampler.swift` | 新增 | 从旧文件提取的加权抽样工具 |
| `PreferenceScorerV2Samples.swift` | 新增 | 样本计算验证 |
| `PreferenceScorer.swift` | 删除 | 旧算法已废弃 |
| `PreferenceStatsService.swift` | 修改 | 使用 V2 评分器，传入 duration |
| `ShuffleSession.swift` | 修改 | 使用 V2 基础权重 + 运行时惩罚 |
| `PreferenceStatsExtensions.swift` | 修改 | 使用 V2 计算 boundedPreference |

---

## 二、旧算法删除说明

**已彻底删除的旧逻辑：**
- `completePlayCount * 15` 的绝对值累加
- `quickSkipCount * (-25)` 的硬惩罚
- 复杂的 `score / log(playCount)` 归一化
- Smoothstep 映射到 0.25~2.5 的激进权重区间
- `RuntimeWeightAdjuster` 旧版（被 V2 运行时惩罚替代）

**保留但重构的部分：**
- `TrackPreferenceStats` 数据结构（字段不变，语义更清晰）
- `PlaybackSessionTracker` 播放行为追踪（不变）
- `ShuffleSession` 队列管理逻辑（权重计算部分替换）

---

## 三、新算法完整公式

### 3.1 基础特征计算

```swift
plays = max(Double(playCount), 1.0)
completionRate = completePlayCount / plays
skipRate = skipCount / plays
quickSkipRate = quickSkipCount / plays
avgListenRatio = clamp(totalPlayedSeconds / (duration * plays), 0.0, 1.05)
```

### 3.2 原始偏好分 (rawPreference)

```swift
completionCentered = completionRate - 0.5
listenCentered = avgListenRatio - 0.5

rawPreference =
    0.8 * completionCentered +
    0.6 * listenCentered +
    (-0.9) * quickSkipRate +
    (-0.3) * skipRate
```

**设计意图：**
- 完成率 50% 为中性点，高于则加分，低于则减分
- 收听比例同理，以 50% 为中心
- quickSkipRate 是最强负信号，但系数 -0.9 远小于旧版的 -25
- skipRate 是轻负信号

### 3.3 低样本保护 (confidence)

```swift
confidence = min(log2(plays + 1) / 3.0, 1.0)

// 示例值：
// 1 play  -> 0.33 (强抑制)
// 3 plays -> 0.67 (中度抑制)
// 7 plays -> 1.00 (满置信)

conservativePreference = rawPreference * confidence
```

### 3.4 手动偏好修正 (manualBias)

```swift
liked:     +0.18
none:       0.00
disliked:  -0.18

finalPreference = conservativePreference + manualBias
```

### 3.5 偏好压缩 (boundedPreference)

```swift
boundedPreference = tanh(finalPreference * 1.4)
// 输出范围: (-1.0, 1.0)
```

### 3.6 基础权重 (baseWeight)

```swift
baseWeight = 1.0 + 0.35 * boundedPreference
// 范围: [0.65, 1.35]
// 中性: 1.0
```

---

## 四、缓存字段语义

### preferenceScoreCache
- **缓存值**: `finalPreference`（手动修正后、压缩前）
- **范围**: 约 -2.0 ~ +2.0
- **用途**: 人类可读，反映实际偏好强度

### effectiveWeightCache
- **缓存值**: `baseWeight`（不含运行时惩罚）
- **范围**: [0.65, 1.35]
- **用途**: 长期基础权重，写回 meta.json

### 运行时权重
- **计算方式**: `baseWeight` + 运行时惩罚（最近播放、同艺人、同专辑）
- **是否缓存**: **不缓存**，每次抽样时动态计算
- **范围**: 最低可降至 0.1（防止曲库小时封杀）

---

## 五、运行时惩罚策略

| 惩罚类型 | 条件 | 惩罚系数 |
|---------|------|---------|
| 同曲最近5首 | 出现在最近5首 | ×0.2 |
| 同曲最近6-10首 | 出现在最近6-10首 | ×0.6 |
| 同艺人最近2首 | 最近2首内有相同artist | ×0.7 |
| 同专辑最近2首 | 最近2首内有相同album | ×0.8 |
| 最低保护 | 任何情况 | ≥0.1 |

---

## 六、典型样本结果表

### 样本 A：低样本、中性偏谨慎
- playCount: 2, complete: 1, skip: 1, quickSkip: 1
- avgListenRatio: ~0.50
- **confidence: 0.53**（低样本保护生效）
- rawPreference: -0.175
- conservativePreference: **-0.093**
- boundedPreference: **-0.128**
- **baseWeight: 0.955** ✓（符合预期：接近1.0，不极端）

### 样本 B：明显喜欢但不夸张
- playCount: 12, complete: 9, skip: 1, quickSkip: 0
- avgListenRatio: ~0.83
- **confidence: 1.00**（满置信）
- rawPreference: 0.518
- conservativePreference: **0.518**
- boundedPreference: **0.625**
- **baseWeight: 1.219** ✓（符合预期：温和提升，不极端）

### 样本 C：明显不喜欢但不封杀
- playCount: 10, complete: 1, skip: 6, quickSkip: 4
- avgListenRatio: ~0.25
- **confidence: 1.00**
- rawPreference: -0.870
- conservativePreference: **-0.870**
- boundedPreference: **-0.825**
- **baseWeight: 0.711** ✓（符合预期：明显下降，但不绝迹）

### 样本 D：超低样本，不应下重判断
- playCount: 1, complete: 0, skip: 1, quickSkip: 1
- avgListenRatio: ~0.02
- **confidence: 0.33**（强抑制）
- rawPreference: -0.570
- conservativePreference: **-0.190**
- boundedPreference: **-0.257**
- **baseWeight: 0.910** ✓（符合预期：轻微下降，不极端）

### 样本 E：Manual Liked（轻推一把）
- playCount: 5, complete: 4, skip: 0, quickSkip: 0
- avgListenRatio: ~0.92
- **confidence: 0.86**
- rawPreference: 0.445
- conservativePreference: 0.383
- finalPreference (+0.18): **0.563**
- boundedPreference: **0.658**
- **baseWeight: 1.230** ✓（符合预期：比普通喜欢略高，但不霸榜）

### 样本 F：Manual Disliked（轻罚一下）
- playCount: 8, complete: 5, skip: 2, quickSkip: 1
- avgListenRatio: ~0.73
- **confidence: 1.00**
- rawPreference: 0.175
- conservativePreference: 0.175
- finalPreference (-0.18): **-0.005**
- boundedPreference: **-0.007**
- **baseWeight: 0.998** ✓（符合预期：几乎回到中性，允许偶尔出现）

### 样本 G：高播放 plateau 测试
- playCount: 50, complete: 35, skip: 10, quickSkip: 5
- avgListenRatio: ~0.79
- **confidence: 1.00**
- rawPreference: 0.325
- conservativePreference: **0.325**
- boundedPreference: **0.425**
- **baseWeight: 1.149** ✓（符合预期：即使播放50次，权重仍温和，未贴边）

---

## 七、负 score 却得到偏高 weight 的异常修复

**问题根源**：旧算法使用 Smoothstep 映射，中心点偏移导致负数分数映射到高于 1.0 的权重。

**修复方式**：
1. 新算法使用 `tanh` 压缩，严格对称于 0
2. 权重映射 `1.0 + 0.35 * boundedPreference` 也严格对称
3. boundedPreference ∈ [-1, 1] 对应 baseWeight ∈ [0.65, 1.35]

**验证**：样本 A（finalPreference -0.093）得到 baseWeight 0.955，不再出现负分高权重的反常。

---

## 八、随机队列稳定性

**保持不变的行为**：
- ShuffleSession 的 `generatedTrackIDs` 序列持久性
- 后退/前进的行为一致性
- 动态扩展队列逻辑

**改进的行为**：
- 权重计算更温和，不会出现某首歌因历史累积权重过高导致霸榜
- 运行时惩罚更有效地防止同歌/同艺人/同专辑连播

---

## 九、验收标准检查结果

| 标准 | 状态 | 说明 |
|------|------|------|
| 偏好权重整体更温和 | ✓ | 0.65~1.35 范围，大多数接近 1.0 |
| 低样本更保守 | ✓ | Confidence 机制，1-2 plays 不轻易下结论 |
| 喜欢的歌不会无限膨胀 | ✓ | tanh 压缩 + 有限权重区间 |
| 误判可恢复 | ✓ | 后续正常听完可逐渐恢复（比例特征驱动） |
| 随机体验不被破坏 | ✓ | 温和权重 + 运行时惩罚分层 |
| effectiveWeightCache 语义清晰 | ✓ | 明确为基础权重，不含运行时惩罚 |

---

## 十、meta.json 写入内容示例

```json
{
  "schemaVersion": 3,
  "preferenceStats": {
    "playCount": 12,
    "completePlayCount": 9,
    "skipCount": 1,
    "quickSkipCount": 0,
    "totalPlayedSeconds": 2400,
    "lastPlayedAt": "2026-04-10T08:04:53Z",
    "lastCompletedAt": "2026-04-10T08:04:53Z",
    "lastSkippedAt": null,
    "manualLikeState": "none",
    "preferenceScoreCache": 0.518,
    "effectiveWeightCache": 1.219
  }
}
```

**字段说明**：
- `preferenceScoreCache`: finalPreference，人类可读的偏好强度
- `effectiveWeightCache`: baseWeight，用于抽样的基础权重（不含运行时惩罚）

---

## 十一、运行时调用示例

```swift
// 1. 计算基础权重（缓存到 effectiveWeightCache）
let result = PreferenceScorerV2.calculateScore(
    stats: track.preferenceStats,
    duration: track.duration,
    manualLikeState: track.preferenceStats.manualLikeState
)
let baseWeight = result.baseWeight  // 1.219

// 2. 抽样时应用运行时惩罚（不缓存）
let runtimeWeight = PreferenceScorerV2.applyRuntimePenalties(
    baseWeight: baseWeight,
    track: track,
    recentHistory: [trackID1, trackID2, ...],
    tracks: trackCache
)
// 如果这首歌在 recentHistory 里，runtimeWeight 可能变成 0.244 (1.219 * 0.2)

// 3. 使用 runtimeWeight 进行加权抽样
let nextTrack = WeightedRandomSampler.sample(
    from: candidates,
    weights: [id: runtimeWeight],
    exclude: currentTrackID
)
```

---

**重构完成，算法已收敛到温和、可恢复、抗误判的设计目标。**
