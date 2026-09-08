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

## Current catalog

能力目录由 `automation.capabilities` 和 MCP `tools/list` 返回。当前已接入 App handler 的
领域包括：

| Domain | Methods | Notes |
| --- | --- | --- |
| System | `system.ping`, `system.info` | 不切换 active Library |
| Library / Query | `library.list`, `library.tracks` | 结构化过滤、组合 predicate、排序、offset 分页 |
| Playlist | `playlist.list/get/create/rename/delete/addTracks/removeTracks/replaceTracks/reorder` | Track identity 先解析；membership mutation 不删文件 |
| Source | `source.list/create/bindPlaylist/setExcludedPath/setMonitorPolicy/remove/refresh` | 新 Source 由 App picker 创建 security-scoped bookmark；授权后的 create/import 与 refresh 返回 Job；排除目录不会删除既有 Track，monitor policy 可设 on/off |
| Playback | `playback.state/play/pause/next/previous/seek/setVolume/setMode` | 统一进入 PlaybackCoordinator |
| Queue | `queue.get/replace/enqueue/enqueueNext/clear` | 返回 opaque queue revision |
| History | `history.list/clear` | 清空 History 是 App confirmation 的高风险操作 |
| Metadata | `metadata.get/patch` | 只写 App metadata，不写原始文件 embedded tags |
| Lyrics | `lyrics.get/refresh` | refresh 返回 App-owned Job；只在质量更高时替换 |
| Jobs | `jobs.list/get/cancel` | 当前为 launch-scoped Job snapshot |
| Diagnostics | `diagnostics.health` | Library/Source/missing/Job evidence |
| Settings | `settings.get/patch` | 当前只开放持久的 referenced Track deletion policy，并带 revision |
| Storage | `storage.inspect/validate/repair` | inspect/validate 只读；repair 仅补齐 App-owned scaffolding，不改 domain data |
| Policy | `automation.capabilities/scopes/grantScope/revokeScope` | scope 状态由 App 持久化并执行 |

Artwork 的当前可见状态通过 `library.tracks` 的 `artworkAvailable` 返回；候选搜索和批量
替换仍应沿用现有 UI/provider owner，尚未伪造成独立公开 mutation。

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

响应包含 `total`、`offset`、`limit`、`nextOffset` 和每首歌的 source/playlist membership，
可直接把 ID 集合传给 Playlist、Metadata 或 Lyrics capability。

## Risk and scope

低风险读取、Playlist membership、普通 Source refresh、播放控制和普通 App metadata patch
可在 scope 已授权后直接执行。每个 catalog descriptor 都声明 `scopes`、`risk`、
`supportsDryRun` 和 `requiresConfirmation`。

默认 scope 会授予当前正常读取和普通写入能力；`files.delete` 与 `storage.write` 默认拒绝。
scope grant 必须由 App 前台确认。以下动作不能用 Agent 自己的一句“确定”替代 App policy：

- 删除真实音频文件；
- 大量 Library/Playlist 删除；
- 清空 History；
- destructive Source mirror；
- 大规模移动/重命名；
- 覆盖大量高质量用户 Metadata/Lyrics/Artwork；
- 直接 Storage write。

## Revisions and retries

Playlist、Queue、Metadata patch 支持 opaque revision/`expectedRevision`。查询后若 UI 先
修改，返回 `conflict`，调用方必须重新查询、重新计算 selection 再重试。重复 membership
加入是集合语义；需要跨进程重试的 mutation 可在 request context 里提供
`idempotencyKey`。相同 key 配不同参数会被拒绝。

## Jobs

长操作不应被当成无限等待的同步调用。`lyrics.refresh`、授权后的 `source.create` 和
`source.refresh` 都明确返回 Job；`jobs.*` 同时观察 App-owned 的导入/Source 任务快照
（如果该任务由当前 App 流程启动）。Job descriptor 包含 ID、kind、state、phase、
completed/total、checkpoint、timestamps 和 failure entries。通过 `jobs.get` 轮询，
`jobs.cancel` 请求取消；当前 Job snapshot 在 App 重启后不承诺保留，但已经写入的
Library domain data 仍由各自 durable owner 管理。Source 授权 UI 本身仍属于前台交互，
只有用户完成授权后才会返回 `completed:false` 的 import Job。

## Not yet exposed

当前代码没有足够稳定、独立的 owner 时，不开放伪 capability。文件级删除/移动、embedded
tag 写入、Artwork candidate apply、远程 HTTP transport、MCP Tasks 映射、复杂 Settings
patch 和任意 JSON write 仍需沿用后续阶段的专门设计。Storage 的正式 API 目前只允许
inspect/validate，以及不触碰 domain data 的 scaffolding repair。高级 Agent 可按
[Agent Behavior Guide](agent-behavior-guide.md) 使用诊断、备份和源码审查进行受控 fallback。
