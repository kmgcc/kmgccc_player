# Automation CLI Reference

可执行文件位于 `Dependencies/PlayerAutomation`，正式 CLI 名称为 `player-automation`。

```sh
cd Dependencies/PlayerAutomation
swift run player-automation automation capabilities --json
swift run player-automation library tracks \
  --filter-json '{"all":[{"sourceID":"SOURCE"},{"hasLyrics":true}]}' \
  --sort-json '[{"field":"addedAt","direction":"desc"}]' --json
swift run player-automation library tracks \
  --params-json '{"filter":{"likeState":"liked","playCountMin":3},"includePreferenceStats":true}' --json
player-automation library stats --json
player-automation library report --limit 100 --offset 0 --json
player-automation library selection-create TRACK-A TRACK-B \
  --expected-revision LIBRARY-REVISION --params-json '{"name":"待整理"}' --json
player-automation library selection-create \
  --params-json '{"name":"无歌词曲目","filter":{"hasLyrics":false}}' --json
player-automation library selection-get SELECTION-ID --json
player-automation playlist add-selection PLAYLIST-ID SELECTION-ID --dry-run --json
player-automation playlist add-selection PLAYLIST-ID SELECTION-ID \
  --params-json '{"expectedSelectionRevision":"SELECTION-REVISION"}' --json
player-automation playlist diff union PLAYLIST-A PLAYLIST-B --limit 100 --json
player-automation queue upcoming --limit 20 --json
player-automation history stats --dimension artist --from 2026-01-01T00:00:00Z --json
player-automation history list --track-id 00000000-0000-0000-0000-000000000001 \
  --limit 50 --offset 50 --expected-revision v1-123 --json
```

## Command groups

常用别名包括：

```text
system ping|info
automation capabilities|scopes|call <method>
library list|get|tracks|stats|report|bundle-export|selection-list|selection-create|selection-get|selection-delete|import|create|open|switch|rename|relocate|remove
playlist list|get|create|rename|delete|add|add-selection|remove|replace|reorder|diff|import|export
source list|get|config-export|config-import|rename|create|bind|exclude|include|watch|unwatch|remove|refresh
files reveal|export
metadata get|export|import|search|apply-candidate|patch
artwork search|get|apply|apply-candidate
lyrics get|search|candidates|compare|apply|refresh
playback state|play|play-playlist|toggle|pause|next|previous|seek|volume|mode
queue get|upcoming|replace|enqueue|enqueue-next|remove|reorder|clear
history list|stats|clear
jobs list|get|wait|cancel|retry
diagnostics health
settings schema|get|patch|validate|reset
audio get|patch
audio loudness get|analyze --params-json <object>
storage inspect|validate|orphans|backup|diff|reload|repair
```

文件操作与 Playlist 分开。`files reveal` 只定位活动 Library 中已授权的音频；
`files export` 通过 App 文件夹选择器复制音频，保留资料库原件，并避免覆盖同名文件：

```sh
player-automation files reveal TRACK-ID --json
player-automation files export TRACK-ID OTHER-TRACK-ID --json
player-automation automation call files.rename \
  --params-json '{"operations":[{"trackID":"TRACK-ID","name":"new-name"}]}' --json
player-automation automation call files.move \
  --params-json '{"dryRun":true,"operations":[{"trackID":"TRACK-ID","sourceID":"SOURCE-ID","relativePath":"folder/new-name.mp3"}]}' --json
player-automation automation call files.delete \
  --params-json '{"dryRun":true,"trackIDs":["TRACK-ID"]}' --json
```

`files.rename`/`files.move` 的批量请求必须先 preview，再以 `--confirm`/等价参数请求
App 前台确认；`files.delete` 始终是高风险操作，真实 apply 所需的 `files.delete` scope
默认拒绝，但 `dryRun` 可先查看影响摘要。
真实删除进入 macOS 废纸篓，Track 与 Playlist membership 保留。

`files.reveal/export` 需要 `files.read`。referenced 文件必须属于当前获准 Source；export
的目标目录由 App picker 授权，批次部分失败会分别返回每首歌结果。export 只复制音频文件，
不会导出 sidecar，也不会改动原件。

`library report` 输出版本化分页 JSON，包含资料库统计、Track metadata 和 Playlist 摘要；Track 与
Playlist 可独立分页（`--limit/--offset` 及 `--params-json` 中的 `playlistLimit/playlistOffset`），
并通过 `--expected-revision` 传回首屏 revision。需要绝对文件路径时，显式设置
`--params-json '{"includeFilePaths":true}'`，且 App policy 必须授予 `files.read`。
需要逐首播放计数、手动 like 状态、最近播放时间及偏好分数时，设置
`--params-json '{"includePreferenceStats":true}'` 并授予 `history.read`；播放偏好 predicate 和排序
也需要此 scope。带播放偏好数据的分页 revision 会在计数变化时更新。

`library bundle-export` 会打包完整 Track metadata、Playlist membership、可读取的音频、封面和歌词，
写入 App 文件夹选择器授权的目标目录。导出的 manifest 只含包内相对路径、尺寸和 SHA-256，
不会复制 Source bookmark 或原始路径。先 dry-run 查看曲目数、体积和缺失文件，再确认并等待 Job：

```sh
player-automation library bundle-export --dry-run --json
player-automation library bundle-export --confirm --json
player-automation jobs list --json
player-automation jobs get JOB-ID --json
```

中断任务不会留下已完成包；部分不可读曲目会在 manifest 与 Job 结果中逐项报告。

`library selection-create` 可传 Track ID 位置参数保存静态顺序，也可省略位置参数并在
`--params-json` 中提供 `filter` 保存动态 predicate。predicate 使用 `library.tracks.filter` 的语法，
在 selection 被读取或加入歌单时重新求值；如需固定目标集合，传入 `trackIDs`。

`automation call <method> --params-json '<object>'` 是稳定的 escape hatch，会沿用同一
个 App handler、scope、revision、Job 和错误 contract，可用于尚未有专用 shell alias 的
新 capability。例如：

```sh
player-automation automation call library.tracks \
  --params-json '{"filter":{"not":{"playlistID":"P"}},"limit":50}' --json
player-automation automation call metadata.patch \
  --params-json '{"trackIDs":["T"],"patch":{"genreTags":["jazz"]}}' --json
player-automation automation call operations.batch \
  --params-json '{"operations":[{"method":"lyrics.apply","params":{"trackID":"T","ttmlText":"<tt>…</tt>"}}]}' --json
player-automation jobs wait JOB-ID --params-json '{"timeoutMs":20000}' --json
player-automation automation call lyrics.search \
  --params-json '{"trackID":"T","background":true}' --json
player-automation jobs get JOB-ID --json
player-automation artwork get TRACK-ID --json
player-automation artwork search TRACK-ID --params-json '{"limit":5}' --json
player-automation artwork apply-candidate art-v1-CANDIDATE-DIGEST --dry-run --json
player-automation artwork apply-candidate art-v1-CANDIDATE-DIGEST --json
player-automation artwork apply TRACK-ID \
  --params-json '{"imagePath":"/tmp/cover.jpg"}' --json
player-automation artwork apply TRACK-ID \
  --params-json '{"clear":true}' --json
```

`jobs.wait` 最多等待 25 秒；返回的 `completed:true` 表示 Job 已进入任意终态，包含
`partialFailure`、`failed` 和 `cancelled`，要看 `job.state` 判断成功。Batch 的逐项结果路径是
`job.result.items[i].response.result`；`background:true` 搜索的原 Automation response 保存在
`job.result`，候选数据位于 `job.result.result`。等待超时不会取消 Job。

Metadata 和 Artwork 也可以直接以 Artist、Album 或 Playlist 为目标，不需要把它们伪装成
Track。四种目标选择器一次只能使用一个：

```sh
player-automation metadata get --artist-id ARTIST-ID --json
player-automation metadata patch --artist-id ARTIST-ID \
  --params-json '{"description":"新的艺人介绍","genreTags":["jazz"]}' --json
player-automation metadata get --album-key 'artist::album' --json
player-automation metadata patch --album-key 'artist::album' \
  --params-json '{"releaseYear":2026,"labelOrCompany":"Example"}' --json
player-automation metadata patch --playlist-id PLAYLIST-ID \
  --params-json '{"name":"夜间精选","description":"Agent 整理"}' --json
player-automation artwork search --artist-id ARTIST-ID --params-json '{"limit":5}' --json
player-automation artwork apply --album-key 'artist::album' \
  --params-json '{"imageBase64":"<reviewed-image-data>"}' --json
player-automation artwork get --playlist-id PLAYLIST-ID --json
player-automation artwork apply --playlist-id PLAYLIST-ID \
  --params-json '{"clear":true}' --json
```

发现实体时可以先分页列出元数据：

```sh
player-automation metadata get --entity-type artist --query '坂本' --limit 50 --json
player-automation metadata get --entity-type album --offset 50 --limit 50 --json
player-automation metadata get --entity-type playlist --json
```

`metadata.get` 返回目标的完整 App-owned 投影：Artist/Album 还包含 canonical key、统计量、
创建/更新时间和 artwork 状态；Track 另含导入时捕获的 `embeddedMetadataSnapshot` 文件标签快照，
不是实时文件读取，外部修改后可能过期；Playlist 返回名称、描述、membership 统计和 artwork 状态。
`metadata.patch` 对 Artist/Album 修改 sidecar 元数据，对 Playlist 修改名称/描述；canonical
ID、统计量和时间戳是只读字段。`artwork.search` 只对 Track、Artist、Album 有联网 provider
语义，Playlist 使用 `artwork.get/apply` 管理已有或 Agent 提供的封面。

`metadata embedded-get` 会从实际音频文件读取标签；MP3 返回 ID3 字段，其他格式尽可能使用
AVFoundation 读取，并标记当前不支持写入。写入当前限 MP3 ID3v2.3/v2.4：先用 `metadata.get`
取得每首 Track revision，再 dry-run；确认后 App 会要求前台确认并返回 Job。逐首写到暂存副本、
读回校验后原子替换，unsupported 文件保持原样。

```sh
player-automation metadata embedded-get TRACK-ID --json
player-automation metadata embedded-patch TRACK-ID --params-file tags.json --dry-run --json
player-automation metadata embedded-patch TRACK-ID --params-file tags.json --yes --json
player-automation jobs get JOB-ID --json
```

`tags.json` 格式为 `{"fields":{"title":"新标题","artist":"艺人"},"expectedRevisions":{"TRACK-ID":"TRACK-REVISION"}}`；
将字段设为 `null` 可删除该 ID3 字段。批次最多 100 首；每首必须提供 revision。其他容器、带有无法
安全保留特性的 ID3 标签和损坏文件会在预览/Job 中逐首标为不支持，不会转码或尝试写入。

需要先发现实体时，可用 `metadata get --entity-type artist|album|playlist`，配合通用的
`--query`、`--limit` 和 `--offset` 分页；响应中的 `nextOffset` 非空时继续查询。单目标 selector
与 `--entity-type` 不能同时使用。

`artwork.apply` 的 `imagePath` 只是 App 选图面板的初始位置提示；App 会重新打开
前台图片选择器并取得 security-scoped access。也可以传 `imageBase64`，或用 `clear`
移除 App-owned artwork。对 10 首及以上 Track，先使用 `--dry-run`，真实调用必须带
`--yes`（映射为 `confirm=true`），然后等待 App 前台确认弹窗。`metadata.patch` 也对
10 首及以上的 App-owned metadata batch 使用同一确认门槛。

`artwork.search` 按 Track/Artist/Album 的目标元数据调用 App 内的多 provider 搜索，返回排序后的
候选、稳定 `candidateID`、分辨率、置信度和 `imageBase64`。审阅后可通过
`artwork.apply-candidate` 直接预览或应用，无需回传图片字节。候选在内存中保留 15 分钟，绑定
当前资料库、目标和封面 revision；切库、过期或封面并发变化时会拒绝写入，应重新搜索。歌词的
`lyrics apply TRACK-ID --params-json` 支持两种互斥输入：provider `candidate`，或直接传
`{"ttmlText":"<tt>...</tt>"}` 写回 Agent 精修后的 TTML。后者仍会执行 App 的 TTML
校验和 revision 检查。

资料库生命周期也有专用 CLI alias；路径只作为 App picker 的导航提示，不能替代前台授权：

```sh
player-automation library list --json
player-automation library create referenced "测试资料库" /Volumes/SSD/Music/test2 \
  --dry-run --json
player-automation library open /Volumes/SSD/Music/test2 --yes --json
player-automation library switch <library-id> --dry-run --json
player-automation library rename <library-id> "新名称" --json
player-automation library relocate <library-id> /Volumes/SSD/Music/archive \
  --dry-run --json
player-automation library remove <library-id> --dry-run --json
```

`library.create` 会创建并激活新资料库；`library.open` 会注册并激活已有资料库；
`library.switch` 只切换已登记且仍可访问的资料库，断开时应先调用 `library.open`；
`library.rename` 只修改显示名；`library.relocate` 通过 App-owned recovery transaction
移动完整资料库；`library.remove` 只在单独的 `library.delete` scope 与前台确认通过后
移入 macOS 废纸篓。所有会改变 active Library 或磁盘位置的操作都应先 preview，再用
`--yes`/`confirm=true` 请求 App 前台确认。

`source exclude/include <source-id> <relative-path>` 修改 Source 的目录排除规则，只影响
未来扫描，不删除已经存在的 Track。`settings patch` 支持 `referencedTrackDeletePolicy`、
`deferImportEnrichment`、`globalArtworkTintEnabled`、`audioVisualizationHDREnabled`、
`dockProgressVisible` 和 `appearanceMode`；`settings schema` 返回适用范围与默认值，
`settings validate` 无副作用，`settings reset` 恢复支持项默认值。启用 `recycleSource` 仍需
调用方 acknowledgement 和 App 前台确认。`storage repair` 只补齐
App-owned scaffolding。`storage backup` 创建 metadata-only backup，`storage diff <backup-path>`
比较当前 JSON/sidecar，`storage orphans` 报告 Playlist 孤儿引用，`storage reload` 在受控
底层变更后重新载入资料库。

`source get <id>` 读取来源策略、排除项、歌单绑定与扫描状态；`source rename <id> <name>`
只更改显示名。`source refresh <id>` 在授权 Source 上立即返回 `sourceScan` Job；`source create [path]`
在用户完成 App picker 且授权可用后立即返回 `importFiles` Job。若授权失败，不会创建半成品
Source 或 Job，返回 `permissionDenied`；用户取消 picker 则返回 `interactionRequired`。CLI
不会为了等待扫描而无限阻塞，应使用结果中的 Job ID 调用 `jobs get`，完成后再查询 Source、
Track 和 Playlist。

`source config-export` 输出版本化的可移植策略文档；`source config-import` 只更新活动库中已存在的
Source，可导入显示名、自动监听策略和排除路径，不创建来源，也不迁移本机路径、security-scoped
bookmark、扫描状态或歌单绑定。跨库导入需用 `sourceIDMap` 把导出 ID 映射到目标库已有 Source。
先用 `--dry-run` 查看变更；真实应用要求 `--confirm`、当前 revision 和 App 前台确认。

```sh
player-automation source config-export --json
player-automation source config-import --params-json '{"document":{"schemaVersion":1,"originLibraryID":"...","sources":[]}}' --dry-run --json
```

导出响应中的 `document` 可直接传回 `source.config.import`；dry-run 响应提供随后调用所需的
`revision`。配置在 preview 后变化时，`--expected-revision` 会阻止过期写入。

Lyrics 的候选工作流可以拆成可组合的调用：`lyrics search`/`lyrics candidates` 返回候选，
`lyrics compare` 比较候选与当前结果，`lyrics apply` 应用明确选中的候选或直接写入 `ttmlText`。`lyrics refresh`
则把选择交给 App-owned Job：对每首歌先尝试逐字歌词，没有可用逐字结果再尝试逐行歌词，
默认不覆盖质量相同或更好的当前结果；只有显式使用 `--force` 才允许强制覆盖。失败项会
记录到 Job 的 `failedItemIDs`，可用 `jobs retry <job-id>` 只重试失败项。

Metadata 候选工作流聚合 bundled QQMusic helper 与 MusicBrainz：

```sh
player-automation metadata search TRACK-ID --json
player-automation metadata apply-candidate TRACK-ID CANDIDATE-ID \
  --expected-revision <revision> --dry-run --json
player-automation metadata apply-candidate TRACK-ID CANDIDATE-ID \
  --params-json '{"overwriteExistingFields":true}' --json
```

候选按 provider-neutral 的标题、艺人、专辑和时长匹配分数排序，响应分别保留 provider
`confidence` 与 `matchQuality`，并列出不可用 provider 的错误。MusicBrainz 候选 ID 以
`musicbrainz:` 开头。候选结果包含 Track revision。默认只补空字段；覆盖现有值需要显式设置
`overwriteExistingFields:true`。`--dry-run` 返回实际待写字段，不写 sidecar；应用时 App 会再次
确认候选、检查并发 revision，并通过 Metadata persistence owner 保存。该工作流不改原音频 embedded tags。

`metadata export/import` 交换版本化的 Track metadata JSON，不包含媒体、封面、歌词正文或本机授权。
每次最多导出或导入 100 首；用 `--limit/--offset` 分页，并保留同一导出响应中的 document：

```sh
player-automation metadata export --limit 100 --offset 0 --json > page.json
# 从 AutomationResponse 提取 result 后，在请求文件中包装为 {"document": ...}
jq '{document: .result}' page.json > import-request.json
player-automation metadata import --params-file import-request.json --dry-run --json
player-automation metadata import --params-file import-request.json --confirm --json
```

跨资料库导入前，在请求文件中补齐 `trackIDMap`，把每个来源 Track ID 映射到目标库现有 Track ID。
默认只填空字段；要覆盖现值需加 `overwriteExistingFields:true`。`--params-file` 限制为 750,000 字节，
超出时继续拆分页，以免超出本地 IPC 帧大小。

`playlist export <id>` 返回 M3U8 文本，默认使用 `player-track://<UUID>`，不泄露文件路径；
通过 `automation call playlist.export` 指定 `includePaths:true` 可生成路径型 M3U，但需要 `files.read`。
`playlist import <id> --params-json '{"m3uText":"..."}'` 可预览或追加／替换现有 Playlist，只映射
活动资料库中已存在的 Track；`unmatchedEntries` 会列出未匹配项，不会导入音频。

## Output contract

- `--json` 时 stdout 只输出一个 `AutomationResponse` JSON envelope；不要从 stdout 读取诊断。
- 人类模式输出可读 key/value；stderr 输出连接、启动和失败诊断。
- `--limit` 范围为 1–500，`--offset` 从 0 开始；Track query 和 `history list` 返回 `total`、`nextOffset` 和 `revision`，续页可传 `--expected-revision` 防止结果漂移。
- `history list` 支持 `--from`（inclusive）、`--to`（exclusive）、`--query` 和 `--track-id`；MCP 与 CLI `--params-json` 还支持 `artistContains` 与 `albumContains`。时间边界使用 ISO-8601；省略筛选时按最近播放时间倒序读取。
- `history stats` 可选 `--dimension all|track|artist|album`，并返回时间范围内的播放次数、
  聆听秒数和分实体聚合。
- `audio get` 返回 gapless 设置、当前系统与 App 输出状态及可用设备清单；`audio patch --params-json` 可通过 `outputDeviceID` 持久选择 App 输出设备，传 `null` 跟随系统默认，不修改 macOS 系统路由。
- `--dry-run` 只生成 preview；普通 mutation 默认直接执行。
- `--yes`/`--confirm` 只表示调用方确认，真正的高风险操作仍由 App 前台 policy 确认。
- `--expected-revision` 防止 Library query 跨页漂移或 Playlist/Queue stale write；
  `--idempotency-key` 用于安全重试。
- `--no-launch` 禁止 LaunchServices 启动 App；`--socket` 可指定测试 socket。

稳定 exit code：`0` 成功，`2` usage/contract，`3` endpoint/App 不可用，`4` 内部错误，
`5` authorization，`6` revision conflict，`7` App interaction cancelled/required。

## Source creation

`source create [path]` 可以提供一个提示路径，但它不能代替用户选择文件/文件夹。用
`--source-mode directory|file` 选择 Source 类型；未知路径会触发 App-owned picker，只有
成功创建 security-scoped bookmark 后 Source 才会存在。

## JSON and scripting

脚本应检查 stdout JSON 中的 `error.code` 和进程 exit code，不应解析人类模式字符串。批量
歌词刷新返回 Job，脚本应：

```text
lyrics refresh -> jobs.get(Job ID) -> jobs.retry/jobs.cancel（必要时） -> 验证 library.tracks/lyrics.get
```

## 导入音频与歌单归入

```sh
player-automation library import /path/to/song.mp3 /path/to/song.ncm /path/to/folder \
  --playlist-id <playlist-id> --dry-run --json
player-automation library import /path/to/folder --playlist-id <playlist-id> --json
player-automation library import /path/to/folder \
  --params-json '{"enrichmentPolicy":"migration"}' --json
player-automation jobs get <job-id> --json
player-automation jobs retry <job-id> --params-json '{"filePaths":["/path/to/song.mp3"]}' --json
```

`enrichmentPolicy` 默认 `standard`；迁移时设为 `migration`，导入会读取嵌入标签与歌词并跳过在线补全。
用 `jobs.wait` 有界等待，随后从 `jobs.get` 读取 `result.fileTrackMappings`。跨库迁移先用来源资料库的
`metadata.export` 逐页导出（每页最多 100 首），将 bundle manifest 的 `tracks[].audioPath` 按 bundle 根目录
解析后与 `fileTrackMappings.filePath` 匹配，构造来源 Track ID → 目标 Track ID 的完整映射；再将每页
Metadata 传给现有 `metadata.import` 的 `trackIDMap`。逐首不同的歌词、封面或 Metadata 用
`operations.batch`；共享值仍用现有 `metadata.patch(trackIDs, ...)`、`artwork.apply(trackIDs, ...)` 和
`lyrics.refresh(trackIDs)`。普通 `source.refresh` 只协调 Source 位置与可用状态，不覆盖已保存 Metadata。
MCP 同名工具为 `library.import`，参数是 `filePaths`、可选 `targetPlaylistID`、`dryRun` 和
`enrichmentPolicy`。
若导入 Job 在 App 重启后中断，`jobs.retry` 保留原目标 Playlist，但要求重新传入 `filePaths`，
让 App 重新取得文件访问授权；retry spec 不保存路径或书签，逐文件失败结果可能包含诊断路径。
若 modern MCP 客户端逐请求声明 Tasks 扩展，长 Job Tools 会返回 Task；轮询使用
`tasks/get`/`tasks/cancel`。否则工具返回原 App Job，使用 `jobs.get`。CLI 始终使用 Jobs API。
结果和权限语义见 [Audio import](automation-capability-reference.md#audio-import)。

## DSP

```sh
player-automation dsp schema
player-automation dsp state
player-automation dsp patch --params-json '{"operations":[{"op":"setMaster","value":true}]}'
player-automation dsp presets list
player-automation dsp presets save --params-json '{"name":"我的均衡器"}'
player-automation dsp presets select --params-json '{"presetID":"<UUID>"}'
player-automation dsp wait --params-json '{"requestID":"<UUID>","timeoutMs":5000}'
player-automation dsp errors get
player-automation dsp patch --params-json '{"operations":[{"op":"setQuality","nodeID":"<UUID>","value":"oversampling4x"},{"op":"setChannelPolicy","nodeID":"<UUID>","value":"frontPair"}]}'
player-automation dsp scripts get --params-json '{"nodeID":"<UUID>"}'
player-automation dsp scripts update --params-json '{"nodeID":"<UUID>","source":"param gainDB(-24,12)=0; prepare { let gain=dbToGain(gainDB); } process { output=input*gain; }","values":{}}'
player-automation dsp scripts compile --params-json '{"nodeID":"<UUID>"}'
player-automation dsp scripts test --params-json '{"nodeID":"<UUID>","fixtures":[{"kind":"impulse","durationSeconds":0.1,"amplitude":0.5}]}'
player-automation dsp nodes retry --params-json '{"nodeID":"<UUID>"}'
```

`dsp validate` 和 `dsp patch --dry-run` 可预览完整配置或有序编辑。
`--expected-revision` 使用 `dsp state` 的 `desiredRevision`，预设修改的
`expectedPresetRevision` 放入 `--params-json`。所有子命令也可用
`call dsp.<method> --params-json ...`。完整参数、预设 JSON 与可听状态说明见
[DSP 与完整预设](automation-mcp.md#dsp-与完整预设)。

脚本 update 默认保存独立草稿，`apply=true` 才编译并申请应用。草稿 CAS 使用 `expectedDraftRevision`，配置 CAS 使用 `--expected-revision`；读回返回的 draft revision 后再 apply。compile 不改变声音，test 返回可取消 Job，沿用 `jobs get|wait|cancel|retry`。自定义 PCM 测试不持久化样本，返回 `retrySupported:false`。语法、格式与 fixture 参数见 [脚本语言 v1](audio-dsp-script-language.md)。源码、静态检查与授权 Debug 编译已完成，测试运行和真实 Agent 验收待完成。

### 全局音频处理与响度扫描

`audio get` 包含 `fade`、`loudness`、`deviceReferences`、`processingRuntime` 和当前固定增益 `normalization`。`audio patch` 的 fade/loudness 子对象支持局部参数更新，与设备/无缝设置共同验证；`--dry-run` 不写设置。它们独立于 DSP 预设。

```sh
player-automation audio patch --params-json '{"fade":{"enabled":true,"playFadeMs":100,"pauseFadeMs":120},"loudness":{"enabled":true,"mode":"auto","targetLUFS":-18}}'
player-automation audio loudness get --params-json '{"trackIDs":["TRACK_UUID"]}'
player-automation audio loudness analyze --params-json '{"trackIDs":["TRACK_UUID"]}'
```

扫描返回既有 Job，使用 `jobs get|wait|cancel|retry` 观察与控制。后台结果供后续播放，当前曲目固定增益不随扫描更新。等响节点所有参数经 `dsp patch` 配置，设备参考由 `audio patch` 的 `deviceReferences` 保存。
