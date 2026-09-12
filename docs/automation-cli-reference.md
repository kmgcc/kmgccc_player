# Automation CLI Reference

可执行文件位于 `Dependencies/PlayerAutomation`，正式 CLI 名称为 `player-automation`。

```sh
cd Dependencies/PlayerAutomation
swift run player-automation automation capabilities --json
swift run player-automation library tracks \
  --filter-json '{"all":[{"sourceID":"SOURCE"},{"hasLyrics":true}]}' \
  --sort-json '[{"field":"addedAt","direction":"desc"}]' --json
```

## Command groups

常用别名包括：

```text
system ping|info
automation capabilities|scopes|call <method>
library list|tracks
playlist list|get|create|rename|delete|add|remove|replace|reorder
source list|create|bind|exclude|include|watch|unwatch|remove|refresh
metadata get|patch
lyrics get|search|candidates|compare|apply|refresh
playback state|play|pause|next|previous|seek|volume|mode
queue get|replace|enqueue|enqueue-next|clear
history list|clear
jobs list|get|cancel|retry
diagnostics health
settings get|patch
storage inspect|validate|orphans|backup|diff|reload|repair
```

文件操作目前通过通用 capability 调用，避免把物理文件 mutation 隐藏在 Playlist 命令中：

```sh
player-automation automation call files.inspect \
  --params-json '{"trackIDs":["TRACK-ID"]}' --json
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

`automation call <method> --params-json '<object>'` 是稳定的 escape hatch，会沿用同一
个 App handler、scope、revision、Job 和错误 contract，可用于尚未有专用 shell alias 的
新 capability。例如：

```sh
player-automation automation call library.tracks \
  --params-json '{"filter":{"not":{"playlistID":"P"}},"limit":50}' --json
player-automation automation call metadata.patch \
  --params-json '{"trackIDs":["T"],"patch":{"genreTags":["jazz"]}}' --json
```

`source exclude/include <source-id> <relative-path>` 修改 Source 的目录排除规则，只影响
未来扫描，不删除已经存在的 Track。`settings patch` 当前只接受
`{"referencedTrackDeletePolicy":"onlyLibrary"|"recycleSource"}`；`storage repair` 只补齐
App-owned scaffolding。`storage backup` 创建 metadata-only backup，`storage diff <backup-path>`
比较当前 JSON/sidecar，`storage orphans` 报告 Playlist 孤儿引用，`storage reload` 在受控
底层变更后重新载入资料库。

`source refresh <id>` 在授权 Source 上立即返回 `sourceScan` Job；`source create [path]`
在用户完成 App picker 且授权可用后立即返回 `importFiles` Job。若授权失败，不会创建半成品
Source 或 Job，返回 `permissionDenied`；用户取消 picker 则返回 `interactionRequired`。CLI
不会为了等待扫描而无限阻塞，应使用结果中的 Job ID 调用 `jobs get`，完成后再查询 Source、
Track 和 Playlist。

Lyrics 的候选工作流可以拆成可组合的调用：`lyrics search`/`lyrics candidates` 返回候选，
`lyrics compare` 比较候选与当前结果，`lyrics apply` 应用明确选中的候选。`lyrics refresh`
则把选择交给 App-owned Job：对每首歌先尝试逐字歌词，没有可用逐字结果再尝试逐行歌词，
默认不覆盖质量相同或更好的当前结果；只有显式使用 `--force` 才允许强制覆盖。失败项会
记录到 Job 的 `failedItemIDs`，可用 `jobs retry <job-id>` 只重试失败项。

## Output contract

- `--json` 时 stdout 只输出一个 `AutomationResponse` JSON envelope；不要从 stdout 读取诊断。
- 人类模式输出可读 key/value；stderr 输出连接、启动和失败诊断。
- `--limit` 范围为 1–500，`--offset` 从 0 开始；Track query 返回 `nextOffset` 和 `revision`。
- `history list` 支持 `--from`（inclusive）和 `--to`（exclusive）的 ISO-8601 时间范围；
  两者都省略时返回最近记录。
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
