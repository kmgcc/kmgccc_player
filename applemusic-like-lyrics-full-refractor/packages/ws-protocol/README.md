# AMLL WebSocket Protocol

本模块定义了一个用于跨端同步播放媒体信息的数据传输协议，在双方结构情况支持的情况下，可以以任意形式传输并同步包括歌词在内的音频媒体播放状态。

## 协议概述

本协议基于二进制 WebSocket 消息实现音乐播放状态同步，包含播放控制、元数据传输、歌词同步等功能。协议使用小端字节序进行二进制序列化。

## 数据结构定义

### 基础类型

以下数据结构按照从上到下的顺序定义各个属性值。

为便于阅读理解，以下定义了一部分常见数据结构：

-   `NullString`: 一个以 `\0` 结尾的 UTF-8 编码字符串
-   `Vec<T>`: 一个以一个 `u32` 开头作为数据结构 `T` 的数量的线性数据结构，后紧跟指定数量的 `T` 数据结构

### Artist 艺术家信息

```rust
struct Artist {
    id: NullString,   // 艺术家的唯一标识字符串
    name: NullString  // 艺术家名称
}
```

### LyricWord 歌词单词

```rust
struct LyricWord {
    start_time: u64,  // 单词开始时间，单位为毫秒
    end_time: u64,    // 单词结束时间，单位为毫秒
    word: NullString  // 单词内容
}
```

### LyricLine 歌词行

```rust
struct LyricLine {
    start_time: u64,                // 歌词行开始时间，单位为毫秒
    end_time: u64,                  // 歌词行结束时间，单位为毫秒
    words: Vec<LyricWord>,          // 单词列表
    translated_lyric: NullString,   // 翻译歌词，如无提供请留空白字符串
    roman_lyric: NullString,        // 罗马音歌词，如无提供请留空白字符串
    flag: u8,                       // 有关该歌词行的属性标记值，可用标记如下：
                                    // - 0b01 : 是否为背景歌词行，等同于 isBG
                                    // - 0b10 : 是否为对唱歌词行，等同于 isDuet
}
```

## 消息主体 (Body)

所有消息都通过 Body 枚举类型进行封装，使用类型为 `u16` 的 Magic Number 区分消息类型：

每个主体都是先以 Magic Number 开头，然后紧跟需要的其他数据结构体（如果有注明），如无注明那则只需要一个 Magic Number 即可。

以下列出了所有可以使用的主体信息，标题后跟的括号内为该 Magic Number 的值：

### Ping (0) (接收/发送)

任意一方发送的心跳请求包，任意一侧的接收方接收到后可以选择发回一个 Pong 信息以确认通信情况。

无需任何额外数据。

### Pong (1) (接收/发送)

任意一方发送的心跳响应包，通常在接收到了 Ping 信息后被接收方发送。

无需任何额外数据。

### SetMusicInfo (2) (接收)

报告当前歌曲的主要信息，提供以下数据：

```rust
struct SetMusicInfo {
    music_id: NullString,   // 歌曲的唯一标识字符串
    music_name: NullString, // 歌曲名称
    album_id: NullString,   // 歌曲所属的专辑ID，如果没有可以留空
    album_name: NullString, // 歌曲所属的专辑名称，如果没有可以留空
    artists: Vec<Artist>,   // 歌曲的艺术家/制作者列表
    duration: u64,          // 歌曲的时长，单位为毫秒
}
```

### SetMusicAlbumCoverImageURI (3) (接收)

报告当前歌曲的专辑图片数据，以 URI 形式提供，提供以下数据：

```rust
struct SetMusicAlbumCoverImageURI {
    img_url: NullString,   // 歌曲专辑图片对应的资源链接，可以为 HTTP URL 或 Base64 Data URI
}
```

### SetMusicAlbumCoverImageData (4) (接收)

报告当前歌曲的专辑图片数据，以二进制原始数据提供，提供以下数据：

```rust
struct SetMusicAlbumCoverImageData {
    data: Vec<u8>,   // 歌曲专辑图片对应的原始二进制数据
}
```

### OnPlayProgress (5) (接收)

报告当前歌曲的播放进度，提供以下数据：

> 注：该信息不限制报告间隔，因此接收端在进行播放进度展现的时候需要做好数值过渡补偿

```rust
struct OnPlayProgress {
    progress: u64,   // 当前歌曲的播放进度，单位为毫秒
}
```

### OnVolumeChanged (6) (接收)

当发送端音量改变时报告，提供以下数据：

```rust
struct OnVolumeChanged {
    volume: f64,   // 音量大小，值域在 [0-1] 内
}
```

### OnPaused (7) (接收)

当歌曲播放被暂停时报告。

无任何额外数据。

### OnResumed (8) (接收)

当歌曲播放被恢复时报告。

> 注：如果处于歌曲切换的状态下，在发送完歌曲信息后应该发送一次本消息

无任何额外数据。

### OnAudioData (9) (接收)

返回当前正在播放的音频 PCM 数据，以 2 通道 48000hz u16 的采样率交错编码。

可以用于呈现音频可视化和其他与音频有关联的特效，~~理论上你还可以直接拿来播放歌曲用~~。

提供以下数据：

```rust
struct OnAudioData {
    data: Vec<u8>,   // 音频数据
}
```

### SetLyric (10) (接收)

设置当前歌曲的歌词数据，以歌词行数据结构提供，接收端可以自行决定是否使用。

提供以下数据：

```rust
struct SetLyric {
    data: Vec<LyricLine>,   // 歌词数据
}
```

### SetLyricFromTTML (11) (接收)

设置当前歌曲的歌词数据，以纯 TTML 歌词数据字符串提供，接收端可以自行决定是否使用。

提供以下数据：

```rust
struct SetLyricFromTTML {
    data: NullString,   // 歌词数据
}
```

### Pause (12) (发送)

请求发送端暂停音乐播放。

无需提供额外数据。

### Resume (13) (发送)

请求发送端恢复播放音乐播放。

无需提供额外数据。

### ForwardSong (14) (发送)

请求发送端跳转到下一首歌曲。

无需提供额外数据。

### BackwardSong (15) (发送)

请求发送端跳转到上一首歌曲。

无需提供额外数据。

### SetVolume (16) (发送)

请求发送端设置播放音量。

需要提供以下数据：

```rust
struct SetVolume {
    volume: f64,   // 音量大小，值域在 [0-1] 内
}
```

### SeekPlayProgress (17) (发送)

请求发送端设置当前播放进度。

需要提供以下数据：

```rust
struct SeekPlayProgress {
    progress: u64,   // 播放进度时间位置，单位为毫秒
}
```

## 序列化/反序列化

### Rust 方法

```rust
// 二进制 -> 结构体
pub fn parse_body(body: &[u8]) -> anyhow::Result<Body>

// 结构体 -> 二进制
pub fn to_body(body: &Body) -> anyhow::Result<Vec<u8>>
```

### WebAssembly 绑定

对于 WASM 绑定库，所有的字段和名称都将从下划线命名方式转换成小驼峰命名方式，例如 `img_url` 变为 `imgUrl`。

```typescript
// JavaScript 接口
export function parseBody(body: Uint8Array): {
    type: keyof Body,
    value: Body<any>,
}>
export function toBody(body: Body<any>): Uint8Array
```

且返回的 `Body` 结构将映射成以 `type` 为枚举类别名称，`value` 为附加数据的结构。

以 `Ping` `SetMusicInfo` `SetMusicAlbumCoverImageURI` 主体为例，映射为 TypeScript 数据类型后结构如下（接口名称不限）：

```typescript
interface Artist {
    id: string;
    name: string;
}

// 以 Ping 主体为例
interface PingBody {
    type: "ping"; // 和文档中标题注明的英文枚举名除了首字母小写外完全一致
    // value: undefined; // 无需额外数据
}

// 以 SetMusicInfo 主体为例
interface SetMusicInfoBody {
    type: "setMusicInfo"; // 和文档中标题注明的英文枚举名除了首字母小写外完全一致
    value: {
        musicId: string; // 歌曲的唯一标识字符串
        musicName: string; // 歌曲名称
        albumId: string; // 歌曲所属的专辑ID，如果没有可以留空
        albumName: string; // 歌曲所属的专辑名称，如果没有可以留空
        artists: Artist[]; // 歌曲的艺术家/制作者列表
        duration: number; // 歌曲的时长，单位为毫秒
    };
}

// 以 SetMusicAlbumCoverImageURI 主体为例
interface SetMusicAlbumCoverImageURIBody {
    type: "setMusicAlbumCoverImageURI"; // 和文档中标题注明的英文枚举名除了首字母小写外完全一致
    value: {
        imgUrl: string; // 歌曲专辑图片对应的资源链接，可以为 HTTP URL 或 Base64 Data URI
    };
}
```

## 使用示例 (TypeScript)

### 设置音乐信息

```typescript
import { toBody } from "@applemusic-like-lyrics/ws-protocol";

const encoded = toBody({
    type: "setMusicInfo",
    value: {
        musicId: "1",
        musicName: "2",
        albumId: "3",
        albumName: "4",
        artists: [
            {
                id: "5",
                name: "6",
            },
        ],
        duration: 7,
    },
});

console.log(encoded); // Uint8Array
```

### 处理播放进度更新

<!-- prettier-ignore-start -->
```typescript
import { parseBody } from "@applemusic-like-lyrics/ws-protocol";

const body = new Uint8Array(
    [
        0x02, 0x00, // SetMusicInfo
        0x31, 0x00, // musicId: "1"
        0x32, 0x00, // musidName: "2"
        0x33, 0x00, // albumId: "3"
        0x34, 0x00, // albumName: "4"
        0x01, 0x00, 0x00, 0x00, // artists: size 1
        0x35, 0x00, // artist.id: "5"
        0x36, 0x00, // artist.name: "6"
        0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 // duration: 7
    ]
);

const parsed = parseBody(body);

console.log(parsed);

/* 预期输出：
{
    type: "setMusicInfo",
    value: {
        musicId: "1",
        musicName: "2",
        albumId: "3",
        albumName: "4",
        artists: [
            {
                id: "5",
                name: "6"
            }
        ],
        duration: 7
    }
}
*/
```
<!-- prettier-ignore-end -->
