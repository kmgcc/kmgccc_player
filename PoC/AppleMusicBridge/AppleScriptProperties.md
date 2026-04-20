# AppleMusicBridge 完整可获取信息清单

## 概述

通过 AppleScript 与 Music.app 通信，可以获取以下所有信息。分为**曲目信息**、**播放状态**、**播放设置**三大类。

---

## 一、曲目基本信息 (Track Properties)

### 核心信息（对歌词系统最重要）

| 属性 | 类型 | 说明 | 示例值 |
|------|------|------|--------|
| `name` | String | 曲目标题 | "Love Yourself, Like I Do" |
| `artist` | String | 歌手名 | "Crispy" |
| `album` | String | 专辑名 | "Love Yourself, Like I Do - EP" |
| `album artist` | String | 专辑艺术家 | "Crispy" |
| `duration` | Double | 总时长（秒） | 264.5 |
| `position` | Double | 当前播放位置（秒） | 87.37 |
| `player state` | Enum | 播放状态 | "playing" / "paused" / "stopped" |

### 创作者与分类

| 属性 | 类型 | 说明 |
|------|------|------|
| `composer` | String | 作曲者 |
| `genre` | String | 流派/曲风 |
| `grouping` | String | 分组标签 |

### 曲目标识

| 属性 | 类型 | 说明 |
|------|------|------|
| `id` | Integer | 内部 ID（会话内唯一） |
| `persistent ID` | String | 持久化 ID（跨会话唯一） |

### 音轨编号

| 属性 | 类型 | 说明 |
|------|------|------|
| `track number` | Integer | 在专辑中的序号 |
| `track count` | Integer | 专辑总曲目数 |
| `disc number` | Integer | 光盘编号 |
| `disc count` | Integer | 光盘总数 |

### 年份与时间

| 属性 | 类型 | 说明 |
|------|------|------|
| `year` | Integer | 发行年份 |
| `release date` | Date | 完整发行日期 |
| `date added` | Date | 添加到库的时间 |
| `modification date` | Date | 最后修改时间 |

### 播放统计

| 属性 | 类型 | 说明 |
|------|------|------|
| `played count` | Integer | 播放次数 |
| `played date` | Date | 上次播放时间 |
| `skipped count` | Integer | 跳过次数 |
| `skipped date` | Date | 上次跳过时间 |
| `rating` | Integer | 评分 (0-100) |
| `loved` | Boolean | 是否标记为喜爱 ❤️ |
| `disliked` | Boolean | 是否标记为不喜欢 👎 |

### 音频技术参数

| 属性 | 类型 | 说明 | 示例值 |
|------|------|------|--------|
| `sample rate` | Integer | 采样率 (Hz) | 48000 |
| `bit rate` | Integer | 比特率 (kbps) | 256 |
| `bpm` | Integer | 每分钟节拍数 | 120 |
| `start` | Double | 播放起始点（秒） | 0.0 |
| `finish` | Double | 播放结束点（秒） | 264.5 |

### 来源与格式

| 属性 | 类型 | 说明 | 示例值 |
|------|------|------|--------|
| `kind` | String | 文件类型描述 | "Apple Music AAC音频文件" |
| `media kind` | Enum | 媒体类型 | "song" / "music video" / "podcast" |
| `file type` | String | 文件扩展名 | "m4p" / "m4a" |
| `compilation` | Boolean | 是否属于合集 | false |
| `purchased` | Boolean | 是否已购买 | false |
| `Apple Music` | Boolean | 是否来自 Apple Music | true |
| `cloud status` | Enum | 云端状态 | "subscription" / "matched" / "purchased" |

### 内容类型

| 属性 | 类型 | 说明 |
|------|------|------|
| `podcast` | Boolean | 是否为播客 |
| `video` | Boolean | 是否为视频 |

### 歌词

| 属性 | 类型 | 说明 |
|------|------|------|
| `lyrics` | String | 内嵌歌词（如果用户已添加） |

### 文件位置

| 属性 | 类型 | 说明 |
|------|------|------|
| `location` | Alias | 文件路径（本地文件） |

### 封面图片

| 属性 | 类型 | 说明 |
|------|------|------|
| `artworks` | List | 封面图片列表（可获取数量和格式） |

---

## 二、播放状态 (Player State)

| 属性 | 类型 | 说明 | 示例值 |
|------|------|------|--------|
| `player state` | Enum | 当前状态 | "playing" / "paused" / "stopped" / "fast forwarding" / "rewinding" |
| `player position` | Double | 当前播放位置 | 87.5 |
| `sound volume` | Integer | 音量 (0-100) | 100 |

---

## 三、播放设置 (Player Settings)

| 属性 | 类型 | 说明 | 示例值 |
|------|------|------|--------|
| `shuffle enabled` | Boolean | 随机播放开关 | true / false |
| `song repeat` | Enum | 重复模式 | "off" / "one" / "all" |
| `mute` | Boolean | 静音状态 | true / false |

---

## 四、当前播放列表 (Current Playlist)

| 属性 | 类型 | 说明 |
|------|------|------|
| `current playlist` | Object | 当前播放列表对象 |
| `name` | String | 播放列表名称 |
| `duration` | Double | 播放列表总时长（秒） |
| `index` | Integer | 当前曲目在播放列表中的位置 |

---

## 五、设备与输出 (Audio Output)

| 属性 | 类型 | 说明 |
|------|------|------|
| `AirPlay enabled` | Boolean | 是否使用 AirPlay |
| `current EQ preset` | Object | 当前均衡器预设 |
| `current visual` | Object | 当前可视化效果 |

---

## 六、选择状态

| 属性 | 类型 | 说明 |
|------|------|------|
| `selection` | List | 用户在 Music.app 中选中的曲目 |

---

## 对歌词系统最有用的信息

### 必备信息（已有）
```
title + artist + position + duration + player_state
```

### 增强信息（可用于显示）
```
album + album_artist + year + track_number
duration (用于进度条)
lyrics (如果用户已添加)
loved / disliked (可用于 UI 状态)
```

### 识别信息（用于歌词匹配）
```
persistent_id (作为唯一标识)
title + artist + album (作为搜索关键词)
duration (用于匹配精确度验证)
```

---

## 完整示例输出

基于当前测试曲目：

```
=== 基本信息 ===
Title: Love Yourself, Like I Do
Artist: Crispy
Album: Love Yourself, Like I Do - EP
Album Artist: Crispy
Composer: Skippy
Genre: Mandopop

=== 标识 ===
Persistent ID: 1C46E7959672978F

=== 时长 ===
Duration: 264.5 秒 (4:24)
Position: 87.5 秒
State: playing

=== 音轨 ===
Track: 1 of 4
Disc: 1 of 1
Year: 2025
Release Date: 2025年10月15日

=== 音频 ===
Sample Rate: 48000 Hz
Bit Rate: 256 kbps

=== 来源 ===
Kind: Apple Music AAC音频文件
Cloud Status: subscription
Apple Music: true

=== 统计 ===
Played Count: 27
Skipped Count: 6
Rating: 0/100
Loved: false
Disliked: false

=== 播放列表 ===
Playlist: 2025
Track: 1 of 161

=== 设置 ===
Volume: 100%
Shuffle: false
Repeat: off
```

---

## 注意事项

1. **Streaming 曲目**: `location` 为 nil（如 Apple Music 流媒体）
2. **歌词获取**: `lyrics` 只在用户手动添加过歌词时才有内容
3. **Artwork 数据**: AppleScript 无法直接导出图片数据，需要通过其他方式获取
4. **日期格式**: 返回的是 macOS 本地化日期字符串
5. **权限**: 首次访问需要用户授权自动化权限

---

## 更新后的服务接口建议

基于以上信息，建议的 `AppleMusicNowPlaying` 结构：

```swift
struct AppleMusicNowPlaying: Sendable {
    // 核心信息
    let title: String?
    let artist: String?
    let album: String?
    let duration: Double
    let position: Double
    let state: AppleMusicPlayerState

    // 扩展信息
    let albumArtist: String?
    let composer: String?
    let genre: String?
    let year: Int
    let trackNumber: Int
    let trackCount: Int
    let discNumber: Int
    let discCount: Int

    // 标识
    let persistentID: String?

    // 音频信息
    let sampleRate: Int
    let bitRate: Int
    let bpm: Int

    // 来源
    let isAppleMusic: Bool
    let cloudStatus: String?

    // 用户数据
    let isLoved: Bool
    let isDisliked: Bool
    let rating: Int
    let playedCount: Int

    // 播放列表
    let playlistName: String?
    let playlistIndex: Int
    let playlistCount: Int

    // 错误
    let error: String?
}
```
