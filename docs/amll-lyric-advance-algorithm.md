# AMLL 歌词提前量算法实现梳理

> 生成时间：2026-05-08
> 针对 kmgccc_player 中自定义 AMLL core (`applemusic-like-lyrics-full-custom-core`) 的歌词时间偏移与提前量算法进行系统梳理。

---

## 一、整体架构概览

歌词时间偏移涉及 **四个层次**：

| 层次 | 关键文件 | 职责 |
|------|---------|------|
| Swift 设置与计算 | `AppSettings.swift`, `Track.swift`, `LyricsViewModel.swift`, `LyricsRuntimeOverlayResolver.swift` | 定义设置项、计算有效偏移、组装 config JSON |
| Swift 音频播放 | `AVAudioPlaybackService.swift` | LED lookahead 音频延迟 |
| WebView 桥接 | `Resources/AMLL/index.html` (内联 JS) | 接收 config、应用 `timeOffset`、处理 seek 跳转 |
| TypeScript 核心 | `packages/core/src/lyric-player/base.ts` | 歌词行提前切换、逐词提前动画 |

---

## 二、Swift 端设置项

### 2.1 `AppSettings` 中的歌词时间设置

**位置**：`myPlayer2/Models/AppSettings.swift:386-397`

```swift
@AppStorage("lyricsLeadInMs")       var lyricsLeadInMs: Double = 600
@AppStorage("lyricsNearSwitchGapMs") var lyricsNearSwitchGapMs: Double = 160
@AppStorage("lyricsGlobalAdvanceMs") var lyricsGlobalAdvanceMs: Double = 0
```

| 设置项 | 默认值 | 范围 | 含义 |
|--------|--------|------|------|
| `lyricsLeadInMs` | 600ms | 0~1200 | **歌词行提前切入量**。当两行歌词间隔很近时，下一行提前多少毫秒开始显示高亮动画。 |
| `lyricsNearSwitchGapMs` | 160ms | 0~500 | **临近切换判定阈值**。如果当前行结束与下一行开始的间隔 <= 此值，则认为是 "near switch"，触发提前切入效果。 |
| `lyricsGlobalAdvanceMs` | 0ms | -1000~1000 | **全局歌词提前量**。正值 = 歌词更早显示，负值 = 更晚显示。叠加到所有歌曲的歌词上。 |

### 2.2 `Track` 模型中的单曲偏移

**位置**：`myPlayer2/Models/Track.swift:38-39`

```swift
var lyricsTimeOffsetMs: Double = 0
```

| 设置项 | 默认值 | 范围 | 含义 |
|--------|--------|------|------|
| `lyricsTimeOffsetMs` | 0ms | -15000~15000 | **单曲歌词时间偏移**。用于校正个别歌曲歌词与音频不同步的问题。 |

### 2.3 LED 音频延迟（独立设置，与歌词无关）

**位置**：`myPlayer2/Models/AppSettings.swift:483`

```swift
@AppStorage("lookaheadMs") var lookaheadMs: Double = 200
```

| 设置项 | 默认值 | 范围 | 含义 |
|--------|--------|------|------|
| `lookaheadMs` | 200ms | 0~200 | **LED 音频延迟**。通过 `AVAudioUnitDelay` 延迟音频输出，使 LED 频谱效果比实际听到的声音提前。与歌词显示 **无关**。 |

---

## 三、Swift 端的偏移计算逻辑

**位置**：`myPlayer2/ViewModels/LyricsViewModel.swift:318-323`

```swift
let trackOffsetMs = max(-15000, min(15000, currentTrack?.lyricsTimeOffsetMs ?? 0))
let effectiveGlobalAdvanceMs = max(
    -5000,
    min(5000, settings.lyricsGlobalAdvanceMs + overlay.globalAdvanceDeltaMs)
)
let combinedOffsetMs = max(-20000, min(20000, trackOffsetMs - effectiveGlobalAdvanceMs))
```

### 计算链解析

1. **`trackOffsetMs`** = clamp(单曲偏移, -15000, 15000)
   - 仅取当前歌曲的 `lyricsTimeOffsetMs`

2. **`effectiveGlobalAdvanceMs`** = clamp(全局提前量 + 运行时覆盖, -5000, 5000)
   - `overlay.globalAdvanceDeltaMs` 来自 `LyricsRuntimeOverlayResolver`
   - 外部播放模式 (`playbackSource.isExternal`) 时自动 **+350ms**
   - **位置**：`myPlayer2/Services/Lyrics/LyricsRuntimeOverlayResolver.swift:49-52`

3. **`combinedOffsetMs`** = clamp(单曲偏移 - 有效全局提前量, -20000, 20000)
   - **关键公式**：`combined = trackOffset - globalAdvance`
   - 当 `globalAdvance` 为正值（提前显示）时，`combined` 为负值
   - 负值传入 JS 后，歌词时间戳减小 -> 更早显示

### 传入 WebView 的 config 字段

```swift
let config: [String: Any] = [
    "leadInMs":       leadInMs,           // 行提前切入量
    "nearSwitchGapMs": nearSwitchGapMs,    // 临近切换判定
    "timeOffsetMs":    combinedOffsetMs,   // 组合偏移（影响歌词显示时间）
    "seekTimeOffsetMs": trackOffsetMs,     // 仅单曲偏移（影响点击跳转时间）
    // ... 其他样式配置
]
```

---

## 四、WebView 层实现

### 4.1 `timeOffsetMs` 的应用

**位置**：`Resources/AMLL/index.html:3848-3925`

```javascript
let timeOffsetMs = 0;
let seekTimeOffsetMs = 0;

const applyTimeOffset = (line) => {
    const offset = Number.isFinite(timeOffsetMs) ? timeOffsetMs : 0;
    if (!offset) return;
    const adjust = (value) => Math.max(0, value + offset);

    line.startTime = adjust(line.startTime);
    line.endTime   = Math.max(line.startTime, adjust(line.endTime));
    line.words.forEach((word) => {
        word.startTime = adjust(word.startTime);
        word.endTime   = Math.max(word.startTime, adjust(word.endTime));
    });
};
```

**作用**：在 `setLyrics` 时，对解析后的每一行歌词及其单词时间戳统一加上 `offset`。

- offset **负值** -> 时间戳减小 -> 歌词**更早**显示
- offset **正值** -> 时间戳增大 -> 歌词**更晚**显示
- 所有时间戳被 clamp 到 `>= 0`

### 4.2 `seekTimeOffsetMs` 的应用

**位置**：`Resources/AMLL/index.html:4167-4172`

```javascript
seekLineStartTimesMs = lines.map((line) => {
    const start = Number.isFinite(line?.startTime) ? line.startTime : NaN;
    return Number.isFinite(start)
        ? Math.max(0, start + seekTimeOffsetMs)
        : NaN;
});
```

**作用**：预计算每行的跳转目标时间（仅应用单曲偏移，不含全局提前量）。用户点击歌词行时，跳转到 `原始时间 + seekTimeOffsetMs`。

**为什么 seek 只用 `trackOffsetMs` 而不用 `combinedOffsetMs`？**

因为 `globalAdvanceMs` 只影响歌词的**视觉提前**（让歌词看起来更早出现），不改变音频播放。当用户点击歌词跳转时，应该跳转到**音频与歌词原始时间对齐**的位置（即仅考虑单曲偏移）。全局提前量是"看起来提前"，不是"实际偏移"。

### 4.3 `leadInMs` 和 `nearSwitchGapMs` 的应用

**位置**：`Resources/AMLL/index.html:4256-4270, 1174-1182`

```javascript
const syncLeadTimingConfig = () => {
    lyricPlayer.setLyricAdvanceLeadInMs(leadInMs);
    lyricPlayer.setLyricNearSwitchGapMs(nearSwitchGapMs);
};
```

**作用**：当设置变化时，调用 TypeScript 核心的 setter 更新参数，并触发歌词重载（`needsLyricsReload = true` -> 重新调用 `setLyrics` -> `setLyricLines` 重新处理行提前逻辑）。

---

## 五、TypeScript 核心实现

### 5.1 新增的可调参数

**位置**：`applemusic-like-lyrics-full-custom-core/packages/core/src/lyric-player/base.ts:158-163`

```typescript
protected lyricAdvanceLeadInMs = 300;        // 默认 300ms（原始无此参数）
protected lyricNearSwitchGapMs = 85;          // 默认 85ms（原始无此参数）
private readonly fallbackLyricAdvanceLeadInMs = 1000;  // 非 near-switch 时的最大提前量
private readonly maxNearWordLeadInMs = 260;   // near-switch 时单词最大提前量
private readonly maxFarWordLeadInMs = 180;    // 非 near-switch 时单词最大提前量
private readonly earlyWordLeadInCount = 2;    // 每行前几个单词参与提前
```

**Setter 方法**（`base.ts:462-476`）：

```typescript
setLyricAdvanceLeadInMs(value = 300) {
    this.lyricAdvanceLeadInMs = Math.max(0, Math.min(1600, value));
}
setLyricNearSwitchGapMs(value = 85) {
    this.lyricNearSwitchGapMs = Math.max(0, Math.min(800, value));
}
```

### 5.2 歌词行提前逻辑

**位置**：`base.ts:717-798`

核心循环（从后往前处理每一行）：

```typescript
for (let i = this.processedLines.length - 1; i >= 0; i--) {
    const line = this.processedLines[i];
    if (line.isBG) continue;

    // 1. 计算与前一行的原始间隔
    const rawGap = rawLineStartTime - prevRawEndTime;
    const hasOriginalOverlap = rawGap < 0;
    const isNearSwitch = !hasOriginalOverlap && rawGap <= this.lyricNearSwitchGapMs;

    // 2. 选择 lead-in 量
    const lineLeadInMs = isNearSwitch
        ? this.lyricAdvanceLeadInMs      // near switch: 使用可调值
        : this.fallbackLyricAdvanceLeadInMs; // 非 near switch: 固定 1000ms

    // 3. 计算新的开始时间
    const leadInStartTime = Math.max(0, line.startTime - lineLeadInMs);
    const newStartTime = hasOriginalOverlap || isNearSwitch
        ? leadInStartTime               // 有重叠或 near switch: 直接提前
        : Math.max(prevEndTime, leadInStartTime); // 否则: 不能早于前一行结束

    // 4. 如果是 near switch，裁剪前一行的结束时间
    if (isNearSwitch && !hasOriginalOverlap && prevIdx >= 0) {
        const prevLine = this.processedLines[prevIdx];
        const clippedPrevEndTime = Math.max(
            prevLine.startTime,
            Math.min(prevLine.endTime, newStartTime)
        );
        this.applyTrailingWordCatchUp(prevLine, ..., clippedPrevEndTime);
    }

    // 5. 应用行开始时间
    line.startTime = newStartTime;

    // 6. 对前几个单词应用提前动画
    this.applyEarlyWordLeadIn(
        line,
        this.resolveWordLeadInMs(isNearSwitch, appliedLeadInMs)
    );
}
```

### 场景对照表

| 场景 | rawGap 条件 | leadIn 量 | 是否受 prevEndTime 限制 | 前一行是否被裁剪 |
|------|------------|-----------|----------------------|----------------|
| 原歌词有重叠 | `< 0` | fallback (1000ms) | 否（直接提前） | 否 |
| Near switch | `<= nearSwitchGapMs` | `lyricAdvanceLeadInMs` | 否（直接提前） | 是（裁剪到 newStartTime） |
| 正常间隔 | `> nearSwitchGapMs` | fallback (1000ms) | 是（max(prevEndTime, ...)） | 否 |

### 关键理解

- `lyricAdvanceLeadInMs` **只在 near switch 时生效**。它的作用是：当两行歌词挨得很近时，让切换更"干脆"——下一行在上一行还没完全结束时就开始高亮，产生 Apple Music 风格的连贯切入感。
- 非 near switch 时，使用固定的 1000ms 提前量，但由于 `Math.max(prevEndTime, ...)` 的限制，实际提前量通常就是两行之间的间隔（即不会真正提前，只是确保不重叠）。
- 也就是说，`lyricsLeadInMs` 和 `lyricsNearSwitchGapMs` 共同控制的是**紧凑歌词的切换动画风格**，而不是简单的"所有歌词都提前显示"。

### 5.3 逐词提前动画

**位置**：`base.ts:574-648`

`applyEarlyWordLeadIn` 方法调整每行前 `earlyWordLeadInCount`（2）个有意义的单词：

```typescript
private applyEarlyWordLeadIn(line: LyricLine, leadInMs: number) {
    // 1. 找出前 2 个有意义的单词
    const meaningfulIndexes = [];
    for (let i = 0; i < line.words.length; i++) {
        if (word.word.trim().length > 0 && ...) {
            meaningfulIndexes.push(i);
            if (meaningfulIndexes.length >= 2) break;
        }
    }

    // 2. 计算可用提前量
    const availableLeadIn = Math.max(0, segmentStart - line.startTime);
    const effectiveLeadIn = Math.min(leadInMs, availableLeadIn);

    // 3. 按比例前移每个单词的时间
    for (let i = 0; i <= lastIndex; i++) {
        const startProgress = (word.startTime - segmentStart) / segmentDuration;
        const endProgress   = (word.endTime   - segmentStart) / segmentDuration;
        word.startTime = Math.max(line.startTime, word.startTime - effectiveLeadIn * (1 - startProgress));
        word.endTime   = Math.max(nextStartTime,  word.endTime   - effectiveLeadIn * (1 - endProgress));
    }
}
```

**作用**：让行内前几个单词也跟随行提前而提前开始高亮。前面的单词提前更多，后面的单词提前更少，产生平滑的"波浪式"切入效果。

`resolveWordLeadInMs` 限制单词级提前量：
- Near switch：最多 `min(appliedLeadInMs, lyricAdvanceLeadInMs, 260ms)`
- 非 near switch：最多 `min(appliedLeadInMs, 180ms, lyricAdvanceLeadInMs * 0.6)`

---

## 六、与原始 AMLL（refractor）的差异

原始 AMLL (`applemusic-like-lyrics-full-refractor`) 中：

| 功能 | 原始实现 | 自定义 core 修改 |
|------|---------|---------------|
| 歌词行提前 | 固定 `line.startTime - 1000`，受 `max(prevEndTime, ...)` 限制 | 区分 near switch / 非 near switch，引入可调参数 |
| 可调 leadIn | **无** | 新增 `lyricAdvanceLeadInMs`（默认300，UI可调） |
| 可调 nearSwitchGap | **无** | 新增 `lyricNearSwitchGapMs`（默认85，UI可调） |
| 逐词提前动画 | **无** | 新增 `applyEarlyWordLeadIn`，前2个单词波浪式提前 |
| 前一行裁剪 | **无** | 新增 `applyTrailingWordCatchUp`，near switch 时裁剪前一行 |
| 时间偏移 (timeOffsetMs) | **无** | 在 `index.html` 中新增 `applyTimeOffset` |
| Seek 偏移 (seekTimeOffsetMs) | **无** | 在 `index.html` 中新增 `seekLineStartTimesMs` |
| LED lookahead | **无**（app 层面功能） | `AVAudioPlaybackService` 中新增 `AVAudioUnitDelay` |

---

## 七、LED Lookahead 的独立作用

**位置**：`AVAudioPlaybackService.swift:228-240, 543`

```swift
private var lookaheadSeconds: Double {
    let ms = max(0, min(200, AppSettings.shared.lookaheadMs))
    return ms / 1000.0
}

// 配置延迟节点
delayNode.delayTime = seconds
delayNode.feedback = 0
delayNode.wetDryMix = seconds > 0 ? 100 : 0

// 报告给 UI 的时间
let audibleTime = newTime - lookaheadSeconds
currentTime = max(0, min(audibleTime, duration))
```

### 原理

- 音频链路：`AVAudioPlayerNode` -> `mainMixer` -> `delayNode` -> `outputNode`（扬声器）
- `newTime` 是 playerNode 已经处理到的时间（不受 delay 影响）
- `audibleTime = newTime - lookahead` 是实际能从扬声器听到的时间
- 歌词同步于 `audibleTime`（与实际听到的声音同步）
- LED 可视化从 `mainMixer` 获取数据（未延迟），所以 LED 比实际听到的声音提前 `lookaheadSeconds`
- **结果**：LED 效果"预判"了声音，歌词与实际声音同步

---

## 八、各设置项的相互关系

```
Swift 端计算
------------
Track.lyricsTimeOffsetMs
       |
       v
trackOffsetMs = clamp(offset, -15000, 15000)
       |
       |    AppSettings.lyricsGlobalAdvanceMs
       |         + overlay.globalAdvanceDeltaMs (+350 if external)
       |                     |
       |                     v
       |    effectiveGlobalAdvanceMs = clamp(..., -5000, 5000)
       |                     |
       +----------+----------+
                  v
combinedOffsetMs = clamp(trackOffsetMs - effectiveGlobalAdvanceMs,
                         -20000, 20000)
       |
       +----------+----------+
                  |           |
                  v           v
           timeOffsetMs   seekTimeOffsetMs
           (= combined)   (= trackOffsetMs)
                  |
                  v
WebView / JS 层
---------------
timeOffsetMs --> applyTimeOffset(line)
                 修改 line.startTime/endTime 和 word 时间戳
                 负值 = 更早显示, 正值 = 更晚显示

seekTimeOffsetMs --> seekLineStartTimesMs[i] = max(0, originalStart + seekTimeOffsetMs)
                     用户点击歌词行时的跳转目标

leadInMs --> lyricPlayer.setLyricAdvanceLeadInMs()
nearSwitchGapMs --> lyricPlayer.setLyricNearSwitchGapMs()
       |
       v
TypeScript 核心 (setLyricLines)
-------------------------------
行提前逻辑：
  - 判断 isNearSwitch (rawGap <= nearSwitchGapMs)
  - near switch: 用 leadInMs 提前, 裁剪前一行
  - 非 near switch: 用 fallback 1000ms, 受 prevEndTime 限制

逐词提前 (applyEarlyWordLeadIn):
  - 前 2 个单词波浪式前移
  - near switch 时最多 260ms, 非 near switch 时最多 180ms
```

---

## 九、关键结论

1. **`lyricsLeadInMs`（默认600）+ `lyricsNearSwitchGapMs`（默认160）控制的是 Apple Music 风格的"紧凑歌词切换动画"**。它们不是简单的"提前显示所有歌词"，而是让间隔很近的歌词行之间产生连贯的提前切入效果。如果一首歌的歌词行之间间隔都很大，这两个参数几乎不会影响显示效果。

2. **`lyricsGlobalAdvanceMs`（默认0）+ `Track.lyricsTimeOffsetMs`（默认0）才是真正调整歌词与音频同步关系的参数**。它们通过 `timeOffsetMs` 统一修改所有歌词时间戳。`globalAdvanceMs` 影响所有歌曲的视觉显示，`trackOffsetMs` 校正单首歌曲的同步偏差。

3. **`seekTimeOffsetMs` 仅包含单曲偏移，不含全局提前量**。因为全局提前量只是"视觉提前"，不改变音频播放。点击歌词跳转时只需对齐音频和歌词的原始时间关系。

4. **原始 AMLL 没有以上任何可调参数**。`leadIn/nearSwitchGap` 在原始代码中是硬编码的固定行为（固定提前1000ms，无 near switch 概念）。`timeOffsetMs` 和 `seekTimeOffsetMs` 是 app 层面在 `index.html` 中完全自定义添加的功能。

5. **`lookaheadMs`（默认200）与歌词显示完全独立**。它延迟音频输出，使 LED 频谱效果提前于听到的声音，歌词仍与实际听到的声音同步。

### 2026-05-16 新版 AMLL 接入补充

- 新版接入后，`leadInMs` / `nearSwitchGapMs` 的行提前仍在 App `index.html` 的 timing preprocessing 中完成：near switch 时下一行 start 被提前，上一行 `endTime` 被 clip 到提前切行点。
- exit highlight catch-up 属于这个提前切行点之后的视觉补偿：上一行已退出 active，但未完成的 word mask animation 会在退出窗口内继续补完到行尾。
- fullscreen / cover blur overlay 的高亮 opacity fade 不应由 catch-up 进度决定；它应在行退出同一帧由非 active 状态开始淡出。2026-05-16 修正只调整 overlay fade 曲线，不改变 advance 算法、clip 行为、word lead-in 或 fork core catch-up 语义。

---

## 十、相关文件速查

| 文件 | 行号 | 内容 |
|------|------|------|
| `myPlayer2/Models/AppSettings.swift` | 386-397, 483 | 歌词时间设置定义 |
| `myPlayer2/Models/Track.swift` | 38-39 | 单曲偏移定义 |
| `myPlayer2/ViewModels/LyricsViewModel.swift` | 318-349 | 偏移计算与 config 组装 |
| `myPlayer2/Services/Lyrics/LyricsRuntimeOverlayResolver.swift` | 22-56 | 运行时覆盖（外部播放 +350ms） |
| `myPlayer2/Services/Audio/AVAudioPlaybackService.swift` | 228-240, 436, 543-560 | LED lookahead 音频延迟 |
| `myPlayer2/Views/Settings/Shared/LyricsTimingConfigSection.swift` | 全文件 | UI 设置面板 |
| `myPlayer2/Resources/AMLL/index.html` | 3848-3925, 4167-4172, 4256-4270 | WebView 桥接：偏移应用 |
| `applemusic-like-lyrics-full-custom-core/packages/core/src/lyric-player/base.ts` | 158-163, 462-476, 556-798 | 核心：行提前与逐词提前 |
