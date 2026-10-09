# Automation Capability Reference

`kmgccc_player` 的 CLI、MCP stdio 和未来 Built-in Agent 共用同一个 App-owned
Automation contract。适配器只负责 transport、参数解析和结果渲染；LibrarySession、
PlaybackCoordinator、Repository、Source reconciler 和 Job coordinator 仍然是唯一的
业务 owner。

仓库：<https://github.com/kmgcc/kmgccc_player>

## Domain semantics

- Track 是资料库中的逻辑歌曲记录；File 是实际音频文件。
- Library membership、Playlist membership、Source membership 是三种不同关系。
- 从 Playlist 移除 Track，不会从 Library 移除 Track，也不会删除真实文件。
- 删除 Playlist 只删除 Playlist 和 membership，保留 Track、Metadata、History 和文件。
- Track 已在 Library 中，仍然可以加入任意其他 Playlist；添加 membership 不会重复导入。
- Referenced Source 的文件消失时，默认保留 Track、Metadata、History 和 Playlist membership，
  只把 Track 标记为 `missing`/`unavailable`。文件重新出现时，Source refresh 会尽可能恢复。
- 文件改名和移动是 File capability 的物理操作，不等于修改 Playlist 或删除 Library Track；
  只允许落在 App 已授权的 Referenced Source 内。真实文件删除会移入 macOS 废纸篓，随后保留
  Track 并由 Source refresh 标记 missing。

## Current catalog

能力目录由 `automation.capabilities` 和 MCP `tools/list` 返回。当前已接入 App handler 的
领域包括：

| Domain | Methods | Notes |
| --- | --- | --- |
| System | `system.ping`, `system.info` | 不切换 active Library |
| Library / Lifecycle / Query | `library.list/get`, `library.create/open/switch/rename/relocate/remove`, `library.tracks/stats/report/import`, `library.bundle.export`, `library.selection.list/create/get/delete` | 资料库可由 App-owned 生命周期事务创建、打开、切换、重命名、迁移和移入废纸篓；Track 查询支持结构化过滤、排序、分页和 revision；`library.report` 提供版本化分页 machine JSON；`library.bundle.export` 以 Job 打包 path-free metadata、Playlist membership、可用媒体、封面和歌词；有序 selection snapshot 可持久保存并复用 |
| Playlist | `playlist.list/get/create/rename/delete/addTracks/addSelection/removeTracks/replaceTracks/reorder/diff/import/export` | Track identity 先解析；membership mutation 不删文件；`addSelection` 复用持久快照；`diff` 支持保序 union/intersection/difference 与分页；M3U8 exchange 保留顺序并报告未匹配项 |
| Source | `source.list/get/config.export/config.import/create/rename/bindPlaylist/setExcludedPath/setMonitorPolicy/remove/refresh` | 新 Source 由 App picker 创建 security-scoped bookmark；授权后的 create/import 与 refresh 返回 Job；配置交换只迁移已存在 Source 的显示名、监听策略和排除路径，不携带路径、bookmark、扫描状态或 Playlist 绑定；导入支持 dry-run、revision 和 App 前台确认 |
| Playback | `playback.state/play/playPlaylist/toggle/pause/next/previous/seek/setVolume/setMode` | 统一进入 PlaybackCoordinator；Playlist 播放保留当前排序 |
| Queue | `queue.get/upcoming/replace/enqueue/enqueueNext/remove/reorder/clear` | 返回 opaque queue revision；重排保留重复项语义，清空队列保留当前正在播放的音频 |
| History | `history.list/stats/clear` | `history.list` 支持时间窗、文本／Track／Artist／Album 筛选、limit/offset 分页和 revision 冲突检测；`history.stats` 可按 Track／Artist／Album 汇总播放次数与聆听时长；清空 History 是 App confirmation 的高风险操作 |
| Metadata | `metadata.get/export/import/search/applyCandidate/patch`、`metadata.embedded.get/patch` | App metadata 与文件内标签分开读写；文件标签读取使用当前授权音频文件，MP3 写入支持 ID3v2.3/v2.4、逐首原子替换和 Job；其他格式可读的字段由 AVFoundation 提供但当前不可写；跨库 Track 文档分页、QQMusic + MusicBrainz 候选排序和 revision 冲突保护继续复用 App owner |
| Artwork | `artwork.search/get/apply/applyCandidate` | Track、Artist、Album 可搜索候选并以绑定 Library/目标/revision 的候选 ID 直接预览或应用；候选提供跨 provider `matchQuality`、provider 原始 `confidence`、图片分辨率和匹配字段；Track、Artist、Album、Playlist 都可读写 App-owned artwork。支持 App 选图、路径提示、base64 或 `clear`；Track 批量 10 首及以上需 `confirm` 与 App 前台确认 |
| Lyrics | `lyrics.get/search/candidates/compare/apply/refresh` | 候选可比较和明确应用；`lyrics.apply` 也可直接写入校验过的 `ttmlText`；refresh 返回 App-owned Job，逐字优先 |
| Jobs | `jobs.list/get/wait/cancel/retry`；MCP `tasks/get/update/cancel`；Resource `kmgccc://jobs` | 每个资料库保留有界历史；支持可重建的 Lyrics/Source Job 重试；`jobs.wait` 单次最多等待 25 秒；现代 stdio MCP 可订阅 Jobs 资源变化，也可逐请求声明 Tasks 后接收 Task 状态通知、轮询与取消 |
| Batch | `operations.batch` | 最多 100 项 Metadata/Artwork/Lyrics mutation 依序经现有 App owner 执行；逐项保存完整响应与冲突；dry-run、scope、revision、confirm 和 idempotency 沿用原 handler |
| Diagnostics | `diagnostics.health` | 返回机器可读的 Library/Source/missing/Job/storage/Playlist-reference 健康报告，并统计缺歌词、缺封面和关键 Metadata 字段覆盖率；一致性 issues 与媒体路径 mediaIssues 分页分开 |
| DSP | `dsp.schema/state/validate/patch/wait`, `dsp.presets.*`, `dsp.errors.*`, `dsp.scripts.*`, `dsp.nodes.retry` | App-wide 有序效果链、完整预设与实时切换；脚本草稿/编译/fixture Jobs；audio.read/write，测试另需 library.read；状态资源支持变化订阅 |
| Settings / Audio | `settings.schema/get/patch/validate/reset`, `audio.get/patch` | Settings 覆盖导入补全时序、外观、封面着色、可视化 HDR、Dock 进度及 referenced 删除策略；支持 schema、无副作用校验、revision 和默认值 reset；Audio 读取 gapless scheduling/AAC trim、可用输出设备及系统／App 路由状态，并控制 gapless scheduling/AAC trim 和 App 输出设备选择 |
| Storage | `storage.inspect/validate/orphans/backup/diff/reload/repair` | inspect/validate/orphans/diff 只读；backup 只复制 JSON/sidecar/enrichment 文件；reload 重新载入当前存储；repair 仅补齐 App-owned scaffolding，不改 domain data |
| Files | `files.inspect/reveal/export/rename/move/delete` | reveal 使用已授权路径；export 经 App folder picker 把音频拷贝到用户选择的目录并保留原件；rename/move 遵守 Source 授权和路径 containment，批量需 preview/App confirmation；delete 默认 scope 拒绝且始终前台确认 |
| Policy | `automation.capabilities/scopes/grantScope/revokeScope` | scope 状态由 App 持久化并执行 |

`library.tracks` 仍返回 Track 的 `artworkAvailable` 和 `artworkFileName`，而 `artwork.get`
不返回原始图片字节，只返回可验证的状态摘要。实体级调用使用四选一目标字段：
`trackID`、`artistID`、`albumKey` 或 `playlistID`；批量 Track 仍使用 `trackIDs`。目标不能混用。

`metadata.get`/`metadata.patch` 的字段边界与当前 App 模型一致：Track 包括标题、艺人/credits、
专辑、专辑艺人、描述、流派、语言、厂牌、发行日期、provider IDs、置信度、抓取时间、
MusicBrainz release ID 和歌词偏移；Artist 包括显示名、介绍、标签、地区、外文名、QQMusic MID、
来源、抓取时间和置信度；Album 包括显示名、介绍、年份/发行日期、类型、标签、语言、厂牌、
QQMusic MID、来源、抓取时间和置信度；Playlist 包括名称和描述。实体的 canonical ID、统计量、
创建/更新时间属于只读投影，不能通过 patch 伪造。

Agent 需要发现实体时，可用 `metadata.get` 的 `entityType`（`artist`、`album` 或 `playlist`）
分页列出对应实体，并用 `query` 按名称、canonical key 或描述筛选；每一页返回 `offset`、`limit`、
`nextOffset` 和集合 revision。单个目标查询仍使用四选一 ID/key，不与 `entityType` 混用。

`metadata.search(trackID)` 同时查询 bundled QQMusic helper 与 MusicBrainz，返回跨 provider 的
`matchQuality`（0–1）、provider 自有 `confidence`、当前 Track revision 和逐 provider 失败提示。
统一匹配分数按标题 45%、艺人 30%、专辑 15%、时长 10% 加权；缺少的字段会从权重总和中剔除。
它是用于比较和排序的字段相似度，不是 provider 成功概率。MusicBrainz 候选 ID 使用
`musicbrainz:<recording UUID>`；应用前会重新确认它仍匹配当前 Track，再读取录音详情。
`metadata.export/import` 提供版本化的 Track metadata JSON 文档交换。导出可按显式 Track IDs
选择，也可用 `limit/offset` 分页，附带来源 Library、集合 revision、逐 Track revision 和可编辑字段；
不包含文件路径、音频、封面、歌词正文、Source 授权或实时运行状态。导入和导出每页最多 100 首，
限制单帧体积；CLI `--params-file` 输入最多 750,000 字节；
跨 Library 必须显式提供完整 `trackIDMap`，不会靠模糊标题自动匹配。先 dry-run 查看逐曲目状态，
实际写入要求 metadataWrite scope、`confirm:true` 和 App 前台确认。默认仅填空字段，覆盖需显式设置；
同库导入使用逐曲目 revision 检查，所有写入仍经 App-owned metadata persistence。
`metadata.applyCandidate` 返回实际 `previewPatch`；默认只补空字段，只有显式设置
`overwriteExistingFields:true` 才覆盖现有值。Dry-run 不写 sidecar；应用会用查询开始时的 Track
revision 检查并发修改，并经 LibraryViewModel persistence owner 落盘。它不写原音频 embedded tags。

`metadata.embedded.get` 实时读取活动音频文件标签；其他容器使用 AVFoundation 可提取字段，响应会
明确标记 `supportedForWrite=false`。`metadata.embedded.patch` 当前只写 MP3 ID3v2.3/v2.4，接受
`title`、`artist`、`album`、`albumArtist`、`composer`、`genre`、`year`、`trackNumber`、
`discNumber`、`comment` 和 `lyrics`；显式 `null` 用于移除对应标签。写入前必须携带每首 Track 的
`expectedRevisions` 并先执行 `dryRun=true`；实际写入还要求 `confirm=true` 与 App 前台确认。
每个文件先写同目录暂存副本并读回校验，再原子替换；批次作为 Job 执行，单曲失败不会改动其原文件。
遇到非 MP3、损坏标签或无法安全保留的 ID3 变体会逐首报告为不支持，不会尝试转码。
MusicBrainz 请求使用可识别的 User-Agent 并由 App 端按每秒至多一个请求节流，遵守
[MusicBrainz API rate limits](https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting)。

`artwork.search` 复用 App 的 NetEase、Sacad 和 QQMusic provider 聚合/排序，支持 Track、Artist、
Album；Playlist 没有联网搜索语义，但支持 `artwork.get/apply`。每个候选返回稳定的
`candidateID`、候选元数据、跨 provider `matchQuality` 与 `imageBase64`，便于 Agent 直接审阅；
分数结合匹配字段、像素尺寸和方形裁切适配度，不替代 provider 原生 `confidence`；审阅后可用
`artwork.applyCandidate` 直接预览或应用，不必回传图片字节。候选在内存中保留 15 分钟，绑定
资料库、目标与封面 revision；过期、切库或并发修改会拒绝写入。为适应本地 IPC frame 上限，
过大的候选会生成受限尺寸的 inline JPEG，并在
`originalByteCount` 保留 provider 原始大小提示。所有 apply 都写入资料库 App-owned artwork
sidecar；它不会改写音频文件内部的 embedded artwork/tag。

## Query / Selection

`library.tracks` 的顶层参数可组合使用：

```json
{
  "filter": {
    "all": [
      {"sourceID": "SOURCE-A"},
      {"hasLyrics": true},
      {"codec": "alac"},
      {"addedAfter": "2026-01-01T00:00:00Z"}
    ],
    "not": {"playlistID": "PLAYLIST-X"}
  },
  "sort": [
    {"field": "addedAt", "direction": "desc"},
    {"field": "title", "direction": "asc"}
  ],
  "limit": 100,
  "offset": 0
}
```

支持的叶子 predicate 包括 `id`、`ids`、`text`、`titleContains`、`artistContains`、
`albumContains`、`genreContains`、`sourceID`、`playlistID`、`availability`、`missing`、
`hasLyrics`、`lyricsStatus`、`hasArtwork`、`addedAfter`、`addedBefore`、`releaseAfter`、
`releaseBefore`、`durationMin`、`durationMax`、`metadataConfidenceMin`、`codec`、`format`、
`sampleRateHz` 和 `bitDepth`。播放偏好字段还支持 `likeState`（`none/liked/disliked`）、
`playCountMin/Max`、`completePlayCountMin`、`skipCountMin`、`lastPlayedAfter/Before`、
`totalPlayedSecondsMin` 和 `preferenceScoreMin`。播放偏好筛选、对应排序以及
`includePreferenceStats:true` 需要 `history.read`；当前没有独立的数值星级字段。
`all` 是 AND，`any` 是 OR，`not` 是 NOT。

`library.tracks` 与 `library.report` 可以通过 `includePreferenceStats:true` 读取每首歌的播放／
完成／跳过次数、总聆听时间、最近播放时间、手动 like 状态和偏好分数。此时结果 revision
也纳入这些值，保证跨页读取期间的播放偏好变化会触发 `conflict`。CLI 可用
`library tracks --params-json '{"includePreferenceStats":true}'` 或在 `library report` 使用同一字段。

响应包含 `total`、`offset`、`limit`、`nextOffset`、`revision` 和每首歌的
source/playlist membership。下一页可带上上一页的 `revision` 作为 `expectedRevision`；如果
Library 或 Playlist membership 在分页期间改变，会返回 `conflict`，调用方应重新查询。

`library.report` 将资料库统计、一页 Playlist 摘要和一页完整 Track metadata 投影合并为版本化
JSON。Track 与 Playlist 使用独立 `offset/limit` 和 `playlistOffset/playlistLimit` 分页，单页各最多
100 项，并共用同一集合 revision。只有显式传 `includeFilePaths:true` 且已授予 `files.read` 时才
附加本地路径。报告不嵌入图片、歌词正文或音频数据；要保存报告文件，调用方可将各页 JSON 输出写入
自己的目标位置。

`library.selection.create` 可保存有序 `trackIDs` 快照，也可保存 `library.tracks.filter` 支持的
结构化 predicate。创建时可传 `expectedRevision` 检查来源查询是否仍新鲜。静态快照保留原 ID 顺序；
predicate 快照在 `get`、`list` 和 `playlist.addSelection` 时按当前元数据、技术信息、播放偏好和
Playlist membership 重新求值；包含播放偏好条件的调用需要 `history.read`。快照不保存媒体或路径，
最多保留 100 个、每个最多解析 10,000 首，30 天后过期。
`playlist.addSelection` 返回本次实际使用的 selection revision，并支持 Playlist revision 与 dry-run；
它不会导入、复制或删除文件。

## Risk and scope

低风险读取、Playlist membership、普通 Source refresh、播放控制和少量 App metadata/artwork
patch 可在 scope 已授权后直接执行；10 首及以上的 metadata/artwork batch 必须显式
`confirm=true` 并通过 App 前台弹窗。每个 catalog descriptor 都声明 `scopes`、`risk`、
`supportsDryRun` 和 `requiresConfirmation`。

默认 scope 会授予当前正常读取和普通写入能力；`library.delete`、`files.delete` 与
`storage.write` 默认拒绝。`library.manage` 默认授予，用于满足正常的资料库创建、打开、
切换、重命名和迁移工作流；移入废纸篓仍需要单独授予 `library.delete`。scope grant 必须由
App 前台确认。以下动作不能用 Agent 自己的一句“确定”替代 App policy：

- 创建、打开、切换或迁移资料库（会改变 active Library 或磁盘位置）；
- 将资料库移入废纸篓；
- 删除真实音频文件；
- 大量 Library/Playlist 删除；
- 清空 History；
- destructive Source mirror；
- 大规模移动/重命名；
- 覆盖大量高质量用户 Metadata/Lyrics/Artwork；
- 直接 Storage write。

## Revisions and retries

Library query、Playlist、Queue、Metadata patch 和 Artwork apply 支持 opaque
`expectedRevision`（Track 批量还可按 Track ID 提供 `expectedRevisions`）。`metadata.get` 与
`artwork.get` 返回的实体 revision 可直接用于对应实体的下一次写入；查询后若 UI 先修改，
返回 conflict 或 mutation result 中的 conflicted IDs，调用方必须重新查询。重复 membership
加入是集合语义；需要跨进程重试的 mutation 可在 request context 里提供 `idempotencyKey`。
相同 key 配不同参数会被拒绝；MCP 若未显式提供 key，会使用同一个 JSON-RPC request id 生成
重试 key。

## Lyrics

Lyrics 候选查询和批量维护共用现有 provider/ranking owner。`lyrics.search` 与
`lyrics.candidates` 返回候选及其 provider、模式和分数；`lyrics.compare` 报告候选质量与
当前结果的差异；`lyrics.apply` 可以应用请求的候选，也可以在 `candidate` 与 `ttmlText`
中二选一，直接写入 Agent 精修后的 TTML。两条路径都会在写入前检查可选的 Track revision；
直接 TTML 会先经过 App 的 TTML 根节点/body 校验，并绕过 provider 候选的“必须更高质量”门槛。
`lyrics.refresh` 用 Job 处理批量选择：先尝试逐字歌词，没有可用逐字结果再尝试逐行歌词，
默认只应用更高质量结果；`--force` 只应在用户明确要求覆盖时使用。

当每首歌曲需要不同的 Metadata、封面或歌词内容时，可将已有 `metadata.patch`、
`metadata.applyCandidate`、`artwork.apply`、`artwork.applyCandidate`、`lyrics.apply` 或
`lyrics.clean` 请求放入 `operations.batch`。每项使用原方法的 `params`，所以 `expectedRevision`、
候选绑定、确认和参数校验继续由对应 handler 执行。批次返回 App-owned Job；`jobs.wait` 等待
至多 25 秒并返回最新 Job 快照、`completed`、`timedOut`、`deadlineReached` 和 `waitedMs`，等待取消
或超时不会取消 Job。查询 `jobs.get` 可读取持久化的逐项响应，具体结果在
`job.result.items[i].response.result`；冲突和失败项不要整批重放。
外层 `dryRun:true` 强制所有子项预览；10 项写入或 10 个不同写入目标以上需要一次前台确认。

慢速 `metadata.search`、`artwork.search`、`lyrics.search`、`storage.validate` 和
`diagnostics.health` 默认仍可同步调用；`background:true` 将它们提交为 Library-scoped Job。
后台搜索的 `job.result` 是原 Automation response envelope，候选数组位于 `job.result.result`。

`diagnostics.health` 与 `storage.validate` 的 `issues` 和 `mediaIssues` 分开分页，各自使用
对应的 count/hasMore 字段。媒体项检查每个已知路径的存在性/可读性；任一已记录位置可读即算可用，
失败说明当前路径可能离线或无权访问，并不证明永久删除。该检查不解码音频；媒体状态也不会并入
sidecar、manifest、索引或 SQLite 一致性失败。

## Jobs

长操作不应被当成无限等待的同步调用。`lyrics.refresh`、授权后的 `source.create` 和
`source.refresh` 都明确返回 Job；`jobs.*` 观察 App-owned 的导入/Source/歌词任务。可选的
`background:true` 也会把 provider search、`storage.validate` 或 `diagnostics.health` 提交为 Job，
同步调用仍是默认行为。Job descriptor 包含 ID、kind、state、phase、completed/total、checkpoint、
timestamps、failure entries、`failedItemIDs` 和 `retryable`。

`jobs.wait(jobID, timeoutMs?)` 默认等待 20 秒，最多等待 25 秒，返回 `job` 最新快照、
`completed`、`timedOut`、`deadlineReached` 与 `waitedMs`。`completed:true` 表示 Job 已进入终态，
包括 `partialFailure`、`failed` 和 `cancelled`；是否成功以 `job.state` 为准。等待超时、被取消或资料库切换
只结束等待，不会取消仍在运行的 Job。`jobs.get` 可继续读取终态及持久化结果。

每个资料库的有界 Job 历史写在其 `Settings/automation-jobs.json`。App 重启时，未到达终态
的旧 Job 会恢复为带 recovery failure 的 `failed` 记录；已经到达终态的记录可以继续由
`jobs.list/get` 观察。`jobs.cancel` 是协作式取消，已提交的 domain data 不会回滚；对带有
安全 retry spec 的失败、部分失败或取消 Job，`jobs.retry` 会创建新的 Job。歌词批处理优先
使用原 Job 的 `failedItemIDs`；Source refresh 使用原 Source ID。导入重试保留目标 Playlist ID，
但 retry spec 不保存输入路径或 security-scoped bookmark。跨重启后，调用方必须用
`jobs.retry` 重新提供 `filePaths`，由 App 重新取得必要的系统授权；导入身份去重避免重复建 Track。
Job 的逐文件失败结果仍可能包含失败文件路径，供调用方诊断。
Source 授权 UI 本身仍属于前台交互，只有用户完成授权后才会返回 `completed:false` 的
import Job。

MCP 2026-07-28 clients 可在每个 `tools/call` 的 `_meta.io.modelcontextprotocol/clientCapabilities`
声明 `io.modelcontextprotocol/tasks`。具备 `supportsTasks` 的 Job Tool 随后返回可用
`tasks/get` 读取的 Task；`tasks/update` 对当前没有 input request 的任务作空确认，
`tasks/cancel` 映射到 App 的协作式 `jobs.cancel`。Task ID 绑定 Library ID 和 Job ID；原 Library
未 active 时需先切回。未声明扩展的请求保留原 `CallToolResult`/Job 响应。CLI 一直通过
`jobs.get/wait/cancel/retry` 管理 Job。

## Remaining plan boundaries

当前仍需专门 owner 或产品决策的范围包括：MP3 以外的 embedded tag 写入、未纳入 schema 的复杂全局
Settings，以及远程 HTTP/XPC transport。远程 transport 按真实需求评估，不属于当前 stdio 阶段承诺。
这里保留的是明确的计划边界，不能据此推断当前能力不可用。Artist/Album 可逐实体处理；Playlist
联网 artwork search 暂无 provider。
Storage backup 是 metadata-only：它不复制
音频、缓存、索引或 live SQLite；`storage.diff` 只接受本 App 为当前资料库创建的 backup 路径。
高级 Agent 可按 [Agent Behavior Guide](agent-behavior-guide.md) 使用诊断、backup/diff 和
validate/reload 进行受控 fallback；普通操作不需要本地源码 checkout。

## Storage fallback surface

`storage.orphans` 会列出 Playlist sidecar 中指向不存在 Track sidecar 的 membership，且不会
自动删除历史关系。`storage.backup` 将当前资料库的 JSON、歌词/封面等 App-owned sidecar 复制到
本机 App Support 的资料库专属备份目录，并返回绝对路径及 SHA-256 manifest；真实音频文件和
运行时 SQLite 不在备份范围内。每个资料库只保留最近一次 backup；再次执行后，旧 backup
目录会被回收，因此需要在同一次调用结果中保存新的 `backupPath`。`storage.diff` 比较当前可观测文件与该 manifest，`storage.reload`
在受控底层修改后重新载入 App-owned Library。底层 JSON write 仍不是普通 Tool；只有正式接口无法解决
具体故障时才查阅官方源码中必要的当前版本细节，修改前备份，修改后 validate/reload，并立即清理临时 checkout。

## Audio import

`library.import` 接受非空 `filePaths` 数组（绝对路径或 `~/` 路径；文件、文件夹可混合）、
可选 `targetPlaylistID`、`dryRun` 和 `enrichmentPolicy`。托管与原位资料库共用手动导入 owner，
包含 NCM 转换、重复识别、歌单归入和嵌入标签／封面／歌词读取。`standard`（默认）还会按 App 当前设置
在线补全；`migration` 只读取嵌入内容并跳过在线补全，适合跨资料库导入后再恢复已有 Metadata。

返回 `libraryID`、`mode`、`filePaths` 和 `job`。调用 `jobs.get` 至终态后检查 `result`：
`trackIDs`、`importedTrackCount`、`reusedTrackCount`、`playlistMembershipAdditions`、
`alreadyInPlaylistCount`、`pendingNCMCount`（本批发现的 NCM 数）、逐文件 `failures`、
`enrichmentCompleted` 和 `enrichmentWarnings`。还会返回 `fileTrackMappings`，逐项给出实际输入音频
绝对 `filePath` 与最终 `trackID`，包含重复复用、NCM 转换和目录展开。导出来源 Metadata 后，
用 `metadata.export` 从来源资料库按每页最多 100 首导出版本化 Metadata，再把 bundle manifest
`tracks[].audioPath`（相对路径需按 bundle 根目录解析）与映射 `filePath` 连接，
再构造来源 Track ID 到目标 Track ID 的完整 `metadata.import(trackIDMap)`。逐页恢复 Metadata 后，
用 `operations.batch` 应用逐首不同的歌词或封面。普通 `source.refresh` 只协调 Source 位置与可用状态，
不会覆盖已保存 Metadata。导入结果可在补全进行中查询，终态 Job
及结果保存在资料库内；provider 无匹配会留下补全提示，不撤销已经导入的音频。
即时补全模式的匹配情况继续由曲目实际 metadata/artwork/lyrics 状态核验。

普通导入要求 `library.read/write`；指定歌单追加 `playlist.write`，原位模式追加
`source.write`。dry-run 只要求 `library.read`，不扫描、不解密、不补全，也不打开授权面板。
App 已能访问的文件直接导入；缺少访问权限时使用 App 的文件选择器，选择应与请求路径对应。
导入 Job 可以取消；已提交曲目保留，尚未结束的本批新增曲目后台补全会取消。失败、部分失败或
取消的导入 Job 可重试，retry spec 保留目标 Playlist ID；调用方重新提供 `filePaths`，App 再次
检查并取得所需授权，已入库文件按既有 identity 规则复用。retry spec 不保存路径或书签，逐文件失败
结果仍可能包含诊断路径。新的独立导入请求应使用新的 idempotency key。

- P3–P4 音频：`audio.get/patch` 包含全局淡化、固定响度与设备参考；`audio.loudness.get/analyze` 读取测量或创建既有资料库扫描 Job。`equalLoudness` 作为正式 DSP v1 节点参与完整预设与链排序，补偿只随 App 主音量和设备参考变化。

- P5 音频：`stereoWidth`、`virtualBass`、`tube` 的参数、质量、声道策略及顺序均进入完整预设与 `dsp.patch`；`setQuality`、`setChannelPolicy` 支持原子编辑。`dsp.state.processing` 返回算法延迟、App 时间映射延迟与峰值保证状态。源码与授权 Debug 编译已完成，数值/性能及主 App 验收待完成，详见 [P5 实施记录](audio-dsp-p5-implementation.md)。

- P6 音频：`script` v1 提供有界 VM、参数反射、独立持久草稿、双 revision 与故障隔离。`dsp.scripts.get/update/compile/test`、`dsp.nodes.retry` 与既有预设/排序形成完整控制接口；测试使用可取消 Jobs/现代 Tasks。资源为 `kmgccc://dsp-language` 与 `kmgccc://audio/dsp/scripts/{nodeID}`。源码、静态检查与授权 Debug 编译已完成，测试运行和实际运行验收待完成，详见 [P6 实施记录](audio-dsp-p6-implementation.md)。
