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
| Library / Lifecycle / Query | `library.list`, `library.create/open/switch/rename/relocate/remove`, `library.tracks` | 资料库可由 App-owned 生命周期事务创建、打开、切换、重命名、迁移和移入废纸篓；查询支持结构化过滤、组合 predicate、排序、offset 分页，并返回 opaque snapshot revision |
| Playlist | `playlist.list/get/create/rename/delete/addTracks/removeTracks/replaceTracks/reorder` | Track identity 先解析；membership mutation 不删文件 |
| Source | `source.list/create/bindPlaylist/setExcludedPath/setMonitorPolicy/remove/refresh` | 新 Source 由 App picker 创建 security-scoped bookmark；授权后的 create/import 与 refresh 返回 Job；排除目录不会删除既有 Track，monitor policy 可设 on/off |
| Playback | `playback.state/play/pause/next/previous/seek/setVolume/setMode` | 统一进入 PlaybackCoordinator |
| Queue | `queue.get/replace/enqueue/enqueueNext/clear` | 返回 opaque queue revision |
| History | `history.list/clear` | 清空 History 是 App confirmation 的高风险操作 |
| Metadata | `metadata.get/patch` | 读写当前 Track 的 App-owned 字段：标题、艺人/credits、专辑、专辑艺人、描述、流派、语言、厂牌、发行日期、QQ/MusicBrainz/provider 字段、置信度、抓取时间和歌词偏移；不写原始文件 embedded tags；10 首及以上需 `confirm` 与 App 前台确认 |
| Artwork | `artwork.search/get/apply` | 复用 App 的多 provider 搜索并返回带 `imageBase64` 的候选供 Agent 审阅；可用 App 选图、路径提示、base64 或 `clear` 写入 App-owned artwork；10 首及以上需 `confirm` 与 App 前台确认 |
| Lyrics | `lyrics.get/search/candidates/compare/apply/refresh` | 候选可比较和明确应用；`lyrics.apply` 也可直接写入校验过的 `ttmlText`；refresh 返回 App-owned Job，逐字优先 |
| Jobs | `jobs.list/get/cancel/retry` | 每个资料库保留有界历史；支持可重建的 Lyrics/Source Job 重试 |
| Diagnostics | `diagnostics.health` | Library/Source/missing/Job/storage/Playlist-reference evidence |
| Settings | `settings.get/patch` | 当前只开放持久的 referenced Track deletion policy，并带 revision |
| Storage | `storage.inspect/validate/orphans/backup/diff/reload/repair` | inspect/validate/orphans/diff 只读；backup 只复制 JSON/sidecar/enrichment 文件；reload 重新载入当前存储；repair 仅补齐 App-owned scaffolding，不改 domain data |
| Files | `files.inspect/rename/move/delete` | inspect 只读；rename/move 遵守 Source 授权和路径 containment，批量需 preview/App confirmation；delete 默认 scope 拒绝且始终前台确认 |
| Policy | `automation.capabilities/scopes/grantScope/revokeScope` | scope 状态由 App 持久化并执行 |

`library.tracks` 仍返回 `artworkAvailable` 和 `artworkFileName`，而 `artwork.get` 不返回原始
图片字节，只返回可验证的状态摘要。`artwork.search` 复用 App 的 NetEase、Sacad 和 QQMusic
provider 聚合/排序，并在每个候选中返回候选元数据与 `imageBase64`，便于 Agent 直接审阅；
审阅后可把候选 `imageBase64` 传给 `artwork.apply`。为适应本地 IPC frame 上限，过大的候选
会生成受限尺寸的 inline JPEG，并在 `originalByteCount` 保留 provider 原始大小提示；
`artwork.apply` 写入资料库的 App-owned artwork sidecar；它不会改写音频文件内部的
embedded artwork/tag。

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
`sampleRateHz` 和 `bitDepth`。`all` 是 AND，`any` 是 OR，`not` 是 NOT。

响应包含 `total`、`offset`、`limit`、`nextOffset`、`revision` 和每首歌的
source/playlist membership。下一页可带上上一页的 `revision` 作为 `expectedRevision`；如果
Library 或 Playlist membership 在分页期间改变，会返回 `conflict`，调用方应重新查询。

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
`expectedRevision`（按 Track ID 提供 `expectedRevisions`）。查询后若 UI 先修改，返回
`conflict`，调用方必须重新查询、重新计算 selection 再重试。重复 membership 加入是集合
语义；需要跨进程重试的 mutation 可在 request context 里提供 `idempotencyKey`。相同 key
配不同参数会被拒绝；MCP 若未显式提供 key，会使用同一个 JSON-RPC request id 生成重试 key。

## Lyrics

Lyrics 候选查询和批量维护共用现有 provider/ranking owner。`lyrics.search` 与
`lyrics.candidates` 返回候选及其 provider、模式和分数；`lyrics.compare` 报告候选质量与
当前结果的差异；`lyrics.apply` 可以应用请求的候选，也可以在 `candidate` 与 `ttmlText`
中二选一，直接写入 Agent 精修后的 TTML。两条路径都会在写入前检查可选的 Track revision；
直接 TTML 会先经过 App 的 TTML 根节点/body 校验，并绕过 provider 候选的“必须更高质量”门槛。
`lyrics.refresh` 用 Job 处理批量选择：先尝试逐字歌词，没有可用逐字结果再尝试逐行歌词，
默认只应用更高质量结果；`--force` 只应在用户明确要求覆盖时使用。

## Jobs

长操作不应被当成无限等待的同步调用。`lyrics.refresh`、授权后的 `source.create` 和
`source.refresh` 都明确返回 Job；`jobs.*` 观察 App-owned 的导入/Source/歌词任务。Job
descriptor 包含 ID、kind、state、phase、completed/total、checkpoint、timestamps、failure
entries、`failedItemIDs` 和 `retryable`。

每个资料库的有界 Job 历史写在其 `Settings/automation-jobs.json`。App 重启时，未到达终态
的旧 Job 会恢复为带 recovery failure 的 `failed` 记录；已经到达终态的记录可以继续由
`jobs.list/get` 观察。`jobs.cancel` 是协作式取消，已提交的 domain data 不会回滚；对带有
安全 retry spec 的失败、部分失败或取消 Job，`jobs.retry` 会创建新的 Job，歌词批处理优先
使用原 Job 的 `failedItemIDs`，避免重复处理整批。Source refresh 也可以安全重建。
Source 授权 UI 本身仍属于前台交互，只有用户完成授权后才会返回 `completed:false` 的
import Job。

## Not yet exposed

当前代码没有足够稳定、独立的 owner 时，不开放伪 capability。文件级 reveal/copy/export、
embedded tag 写入、远程 HTTP transport、MCP Tasks 映射、复杂 Settings patch 和任意 JSON
write 仍需沿用后续阶段的专门设计。Storage backup 是 metadata-only：它不复制
音频、缓存、索引或 live SQLite；`storage.diff` 只接受本 App 为当前资料库创建的 backup 路径。
高级 Agent 可按 [Agent Behavior Guide](agent-behavior-guide.md) 使用诊断、backup/diff、源码审查
和 validate/reload 进行受控 fallback。

## Storage fallback surface

`storage.orphans` 会列出 Playlist sidecar 中指向不存在 Track sidecar 的 membership，且不会
自动删除历史关系。`storage.backup` 将当前资料库的 JSON、歌词/封面等 App-owned sidecar 复制到
本机 App Support 的资料库专属备份目录，并返回绝对路径及 SHA-256 manifest；真实音频文件和
运行时 SQLite 不在备份范围内。`storage.diff` 比较当前可观测文件与该 manifest，`storage.reload`
在受控底层修改后重新载入 App-owned Library。底层 JSON write 仍不是普通 Tool，必须由高级用户
依据当前版本源码自行执行，并在修改前备份、修改后 validate/reload。
