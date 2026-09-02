# 资料库存储

kmgccc_player 把用户资料库、可重建索引、派生缓存和系统缓存分开管理。每个资料库有稳定身份并固定为托管或原位模式；曲目、历史、统计、索引和 App 可控缓存都由当前资料库拥有。清理操作首先判断数据能否从其他权威来源完整重建；不能重建或带有用户选择的数据，一律不按缓存处理。

## 资料库身份与模式

`library.json` 是资料库的权威入口，保存资料库 UUID、显示名、schema 和固定模式。全局 `LibraryRegistry.json` 只保存资料库 bookmark、最后已知路径、模式投影、当前资料库 ID，以及两种模式各自最近使用的资料库；打开和重连仍以 `library.json` 为准。

- **托管模式（managed）**：导入时把音频复制到 `Tracks/<trackUUID>/audio.<ext>`。删除曲目会永久删除资料库副本，不操作最初的导入源。
- **原位模式（referenced）**：音频留在外部来源，Track sidecar 保存 bookmark、来源 membership、physical identity 和 fingerprint。资料库只保存 App 元数据与派生数据。

同一资料库不能混合两种 locator。模式在创建后不可修改；切换模式实际是切换到该模式最近使用的另一资料库，或进入创建流程。

```text
kmgccc_player Library/
  library.json
  Settings/
    library-settings.json
    library-upgrade.json
  Tracks/<trackUUID>/
    meta.json
    audio.<ext>                 # 仅托管模式
    artwork.jpg
    lyrics.ttml
  Sources/                     # 原位来源与权威事务记录
    <sourceUUID>/source.json
    ignored-items.json
    ncm-conversions.json
  Playlists/
  Artists/
  Albums/
  PlaybackHistory/PlaybackHistory.sqlite*
  Index/
    TrackIndex.sqlite*
    LibrarySearch.sqlite*
  Cache/
    Artwork/
    Lyrics/
    Colors/
    Home/
    ExternalPlayback/
    ImportStaging/
    LibraryScan/manifest.json
    SourceScan/<sourceUUID>.json
```

旧的 `.kmgccc-library-manifest.json` 只作为扫描缓存迁移输入；成功写入 `Cache/LibraryScan/manifest.json` 后不再使用。

## 数据平面

| 数据平面 | 内容 | 权威来源 | 清理方式 |
| --- | --- | --- | --- |
| 用户资料库 | manifest、曲目 sidecar、歌词、封面、播放列表、歌手与专辑资料、source、ignore 和 NCM 关联 | 资料库文件 | 明确的删除或编辑操作 |
| 用户行为数据 | 播放历史、播放次数、喜欢状态和偏好分数 | 事件日志与 sidecar | 单独的历史删除或统计重置 |
| 可重建索引 | 曲目索引、全文搜索索引 | 用户资料库 | 独立的索引清理，随后重建 |
| App 派生缓存 | 封面派生图、颜色分析、在线候选、首页快照、导入暂存 | 用户资料库或网络结果 | 普通缓存清理 |
| 系统缓存 | WebKit、URLSession、Cookie、LocalStorage、IndexedDB | Apple 框架 | 使用框架 API 管理 |

播放历史采用事件日志，但它记录用户行为，不是缓存。普通缓存清理不得删除播放历史、统计或偏好分数。

## Session 与切换边界

`LibraryContext` 在 session 建立时固定资料库 ID、模式、root、bookmark、generation 和全部路径。repository、scanner、索引、history、cache store 及 detached task 都捕获该 context，业务过程中不读取一个会变化的全局 active path。

切换资料库按固定顺序执行：准备候选 session；flush 旧统计；停止旧播放、导入、补全和 FSEvents；关闭索引与 cache owner；释放 root/source scope；再加载并原子发布新 session。旧 generation 的异步结果不得提交到新资料库。

每个 active session 只持有一个 `LibraryChangeMonitor`。托管库监听资料库 root，但只接受 `Tracks`、`Playlists`、`Artists` 和 `Albums` 的权威变化；原位库在同一 stream 中同时监听这些目录和全部 source roots。`Cache`、扫描 manifest、历史/索引 SQLite 及 WAL/SHM 不触发 reload。FSEvent burst 经 debounce 后，托管数据走 `LibraryDiskScanner.scanIncremental()`，source 数据走 diff/reconcile；挂载、卸载和 App 回到前台时执行补扫。

## 资料库文件

曲目数据按窄职责写入。元数据、歌词和封面分别有对应的持久化入口，只修改元数据时不重写歌词与封面 sidecar；只有确实需要同时更新多类资产时才调用覆盖范围更大的写入方法。

这种分层减少不必要的 I/O，也降低部分写入失败时破坏其他用户数据的风险。导入、元数据编辑、歌词编辑和删除最终都汇聚到资料库仓库，由仓库负责更新 sidecar、SwiftData 索引和搜索索引。

## 原位来源与删除

目录来源以 security-scoped root bookmark 持久化。session 持有 root lease，单文件读取只在实际打开期间持有 file lease；bookmark stale refresh 通过 repository 窄写回 sidecar。来源递归扫描跳过隐藏项、package 内部和越界符号链接，并按 physical identity 合并重叠来源或硬链接。

scanner 只生成 immutable diff，reconciler 用持久化 intent 提交 sidecar、runtime、playlist 和派生索引。临时离线、权限失败或文件缺失只更新 availability，不自动删除 Track。

原位曲目有两种删除策略：

- `仅从资料库移除` 先写 physical-identity ignore tombstone，再删除 App authority；自动扫描不会复活，手动重新导入会解除 tombstone。
- `将原文件移到废纸篓` 先回收外部文件；失败时保留 App track、播放列表和索引。

移除 source 只删除 membership 和该来源独有的 App track，不删除外部音频；仍属于重叠来源的 Track 保留同一 UUID。移除整个原位资料库也不删除外部音频。

NCM 转换在来源目录使用 reservation 和唯一输出名，绝不覆盖或删除原 NCM。`Sources/ncm-conversions.json` 保存 pending/success/removed 关联；ignore 同时阻止已删除的 NCM 或转换输出被自动重新导入。只有用户手动选择 NCM 才会解除相应屏蔽并重试。

## 派生缓存

App 自管缓存集中在当前资料库的 `Cache` 下，包括：

- 曲目原始封面缓存和常用尺寸派生图；
- 播放列表封面派生图；
- 在线封面候选与元数据缓存；
- 歌词索引下载缓存；
- 主题色与首屏快照；
- 导入会话暂存目录。

新增缓存时应由统一的存储位置服务提供 URL，并在缓存管理器中登记清理语义。业务代码不自行拼接目录，也不把用户数据写进可整体删除的缓存根目录。

## 封面缓存

封面缓存分为原始字节和显示派生图。缓存键使用曲目 identity、文件名、大小、修改时间和算法版本，不绑定设备上的资料库位置；用户移动资料库时，只要封面内容没有变化，缓存仍可复用。

同一来源和尺寸的并发请求会合并。播放队列变化后，系统以低优先级预热当前曲目、后续曲目和上一首的常用尺寸，但预热不阻塞播放或界面更新。

切歌时，播放界面保留旧封面，等新封面准备好后原子替换。目标在磁盘缓存中时，不应进入网络式“加载中”状态；只有确认没有来源或加载失败后才显示占位图。

## 外部播放数据

外部播放的自动结果与用户选择分开保存。自动匹配、自动歌词和自动下载的封面按资料库存入 `Cache/ExternalPlayback`，可以随当前资料库缓存清理；手动匹配与手动歌词保留在全局偏好中，切库后仍然有效。手动封面、来源优先级与禁用项同样属于用户数据，普通缓存清理必须保留。

若产品需要“重置外部播放手动数据”，应提供独立的破坏性操作和明确确认，不能把它混入普通缓存清理。

## 播放历史与统计

播放统计由历史事件和曲目聚合字段共同支持。一次有效播放写入历史事件，再更新曲目的播放次数、最近播放时间和偏好统计。删除单条历史事件时，要重新计算受影响曲目的聚合值，不能只删表中一行而留下不一致的统计。

事件身份应稳定且可去重。来自系统通知、进度轮询或来源切换的重复信号不能生成多条等价记录；界面高亮也应绑定稳定事件 ID，而不是依赖会变化的数组位置。

重置播放统计属于明确的数据操作，需要同时清除历史事件与曲目聚合字段。切换资料库时，历史数据库和统计 owner 也要随资料库上下文切换，不能继续引用旧资料库。

## 搜索与曲目索引

SwiftData 曲目索引和 SQLite 搜索索引都可以从资料库 sidecar 重建，因此可以由独立设置项清除。普通缓存清理不删除它们，以免用户只想释放封面缓存时触发大型索引重建。

搜索索引保存规范化元数据、歌词纯文本与文件指纹。歌词文件没有变化时，增量更新复用已提取的纯文本；删除曲目时同步删除索引行。具体算法见 [曲库搜索](search.md)。

## 导入暂存

每次导入使用独立会话目录。启动和手动缓存清理可以删除空会话与过期会话，但必须先确认当前没有活动导入；非空目录只有超过设定时效才可清理。

导入暂存的失败清理不应阻断 App 启动。反过来，导入过程中也不能因为定时清理而删除正在写入的文件，因此活动导入快照是删除前的必要条件。

## 系统管理缓存

WebKit 和 URLSession 数据由 Apple 框架管理。应用不硬编码删除系统网络或 WebView 存储目录，也不在资料库缓存清理中删除 Cookie、LocalStorage 或 IndexedDB。

日志、崩溃报告、更新包，以及 macOS 强制管理的 WebKit/URLSession 容器也不迁入资料库。它们是资料库自包含规则的明确系统例外。

若以后提供网络数据清理，应调用框架 API，并在界面上与资料库缓存分开命名，让用户能够判断操作范围。

## 清理操作的设计

一个清理入口应同时回答两件事：会删除什么，以及明确不会删除什么。实现前可以用下面的判断顺序：

```text
数据能否完整重建？
  ├─ 否 → 用户数据，不进入普通缓存清理
  └─ 是 → 是否包含用户手动选择？
           ├─ 是 → 单独的重置操作
           └─ 否 → 可以登记为派生缓存
```

这条边界比具体目录名更重要。目录会迁移，数据语义不能随之改变。
