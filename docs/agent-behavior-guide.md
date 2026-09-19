# Agent Behavior Guide

这份文档是给 Claude、Codex、脚本和其他外部 Agent 的稳定行为约束。Skill、CLI help 和
MCP Resources 应引用它；它不是安全边界，真正的 scope 和确认 policy 永远由 App 执行。

## Before changing anything

1. 用 `automation.capabilities`/MCP `tools/list` 确认当前版本实际开放的能力。
2. 用 `library.tracks`、`playlist.get`、`source.list` 或 `diagnostics.health` 查询真实状态。
3. 保存返回的 Track/Playlist/Queue revision；可组合 selection 后一次批量提交。
4. 对 medium/high risk mutation 先 `dryRun`，检查影响摘要、skipped、missing、conflict 和 Job。
5. 只在正式接口不能表达需求时才进入 Storage fallback。

## Library lifecycle workflow

资料库不是只读上下文。Agent 可以在用户明确要求下通过 App-owned lifecycle 工具协助管理：

```text
library.list
    -> library.create/open/switch dryRun
    -> 用户确认 + library.create/open/switch confirm=true
    -> library.list / system.info 验证 activeLibraryID
```

- `library.create` 创建并激活 managed 或 referenced 资料库；`parentPath` 只是 picker 提示。
- `library.open` 选择并注册已有资料库；路径授权由 App 前台 picker 完成。
- `library.switch` 只切换已登记、仍可解析的资料库；收到 `interactionRequired` 时，
  按错误详情调用 `library.open` 重新连接，不要盲目重试 switch。
- `library.rename` 只改显示名；`library.relocate` 先 preview，再经 App recovery transaction
  搬迁完整资料库；两者之后都要重新 `library.list` 验证。
- `library.remove` 先 dry-run，真实操作还需要用户授予 `library.delete` scope 和 App
  前台确认；它的语义是移入 macOS 废纸篓，不是不可恢复的直接删除。

切库会改变 Agent 后续看到的 active Library。调用前应报告目标名称/ID，调用后重新查询
`system.info`、`library.list`，不要把旧库的 Track、Playlist 或 Job ID 当成新库状态。

## Source workflow

当用户说“把这个目录加进播放器并持续监听”时，Agent 应请求 `source.create`。未知路径不
等于 macOS 文件权限；App 会在前台打开 `NSOpenPanel`，用户选择并允许后，App 保存
security-scoped bookmark，再继续创建 Source。拒绝时不得重试成半成品 Source，应报告
结构化 permission denial。

Source 文件消失的默认结果是保守的：Track 仍在 Library，Playlist/Metadata/History 保留，
Track 变成 missing。只有用户明确要求 strict mirror 或移除 Library 时，才请求对应高风险
策略，并先 preview。

要排除目录中的一个子目录，使用 `source.setExcludedPath` 或 CLI 的
`source exclude <source-id> <relative-path>`；这是扫描策略，不是删除操作，已有 Track
仍然保留。恢复扫描时使用 `source include`。用 `source.setMonitorPolicy`（CLI 的
`source watch`/`source unwatch`）区分自动监听和手动刷新；`off` 不会删除现有状态，仍可
显式调用 `source.refresh`。

## Playlist workflow

“把目录 A 全部加入新 Playlist”应是：

```text
source.list / source.refresh
    -> library.tracks(filter: {sourceID: A})
    -> playlist.create
    -> playlist.addTracks(trackIDs: selection)
    -> playlist.get / library.tracks 验证
```

已存在 Library 的歌曲仍必须加入 Playlist；不要因为没有“新导入”就跳过 membership。不要
用删除 Track 来实现“从 Playlist 移除”，也不要用删除 Playlist 来实现“删除文件”。

复杂需求优先用 `all`/`any`/`not`、membership、日期、技术音频和 metadata/lyrics 状态
组合，而不是请求开发者为每个自然语言句子新增一个专用 Tool。

歌词维护应先组合 selection，再使用 `lyrics.search`/`lyrics.candidates`、`lyrics.compare`
和 `lyrics.apply` 处理明确候选；大批量维护使用 `lyrics.refresh` Job。它会逐字优先、无可用
逐字结果再考虑逐行结果，默认不覆盖同等或更高质量的当前歌词。Job 完成后检查
`failedItemIDs`，对可重试的失败使用 `jobs.retry`，不要因超时而盲目重复整批。

## File operations

文件操作只应针对 `files.*` capability，不应通过修改 Playlist、Track sidecar 或任意
Storage JSON 来间接实现。推荐顺序是：

```text
files.inspect
    -> files.rename / files.move dryRun
    -> 检查影响摘要、目标路径和 Source containment
    -> 单文件直接执行，批量操作请求 App 前台确认
    -> source.refresh / jobs.get
    -> files.inspect + library.tracks 验证
```

`files.rename` 和 `files.move` 只能操作 App 已授权的 Referenced Source；路径不能逃出
Source 根目录，移动到未授权路径会被拒绝。`files.delete` 是高风险操作：先 preview，确认
scope 已由用户授予，再让 App 前台显示影响并确认。执行后文件进入 macOS 废纸篓，Track、
Metadata、History 和 Playlist membership 不会被静默删除。

需要批量整理时，保留返回的 Job ID 并报告每项 failure；不要把文件移动当作“从 Playlist
移除”。如果只需要分类，优先使用 Playlist membership，避免不必要的物理文件改动。

## Lyrics and metadata

- 先查询 `lyricsStatus`/`metadataConfidence`，再批量选择目标。
- Lyrics refresh 返回 Job；不要为几万首歌逐首发同步调用。
- 默认只在新结果质量更高时替换：word-synced > line-synced > plain > none。
- `metadata.get` 返回当前 Track 的完整 App-owned 元数据投影；`metadata.patch` 可修改标题、
  艺人/credits、专辑、专辑艺人、描述、流派、语言、厂牌、发行日期、QQ/MusicBrainz/provider
  字段、置信度、抓取时间和歌词偏移。它不是用户原始音频文件的 embedded tags 写入器。
- `artwork.search` 复用 App 内 NetEase/Sacad/QQMusic 聚合搜索，返回排序候选、匹配信息和
  `imageBase64`，适合 Agent 直接视觉审阅；审阅后可把候选数据交给 `artwork.apply`。
  `artwork.get` 只返回 App-owned 封面的存在、文件名、大小、SHA-256 和 Track revision；
  不把当前已写入图片字节塞入查询响应。`artwork.apply` 可使用 App picker、`imagePath`（仅作
  picker 初始位置）、`imageBase64` 或 `clear`，并写入资料库 artwork sidecar。
- `lyrics.apply` 的 `candidate` 和 `ttmlText` 必须二选一。候选遵循质量门槛；`ttmlText`
  适合 Agent 在中间台完成翻译/时间轴微调后直接写回，App 会先验证 TTML 再经现有歌词
  persistence owner 持久化。
- 不要无条件覆盖已有较高置信度或用户手工数据。Metadata/Artwork 的 10 首及以上批量应先
  `dryRun`；真实调用必须带 `confirm=true`，并等待 App 前台弹窗，调用方的 `--yes` 不能
  绕过弹窗。完成后重新调用 `metadata.get`/`artwork.get` 或 `library.tracks` 验证
  applied/skipped/conflicted。

## Playback and queue

播放控制只作为用户明确请求的副作用。插播歌曲时先读取 queue revision，使用
`queue.enqueueNext`，然后验证当前 Track 和剩余队列；不要用 `queue.replace` 覆盖用户手工排队
内容，除非用户明确要求替换整个队列。

## Safety policy

- 不删除真实音乐文件，除非用户明确要求且 App 前台确认成功。
- 大量删除、清空 History、destructive mirror、批量覆盖和文件移动先 preview。
- `--yes` 或 MCP 参数 `confirm=true` 只是调用方 acknowledgement，不绕过 App alert。
- 遇到 `conflict`：重新 query，不要盲目重放旧 payload。
- 遇到 `authorizationRequired`：读取 scope 状态；需要 grant 时让 App 处理前台授权。
- 失败的 Job 只 retry failed entries；不要重复整个批次造成不必要 provider 压力。
- 真实文件 delete 的 scope 默认是 denied；不要为了绕过 App policy 直接编辑 scope 文件或
  Storage。

## Storage fallback

正式顺序必须是：

```text
Automation API
  -> diagnostics / repair
  -> 当前版本 docs 和 GitHub 源码
  -> backup
  -> 最小 controlled JSON/filesystem change
  -> schema/invariant validate
  -> reload/rescan/restart（按真实 owner）
  -> query 验证并报告
```

当前公开源码仓库是 <https://github.com/kmgcc/kmgccc_player>，但 Agent 必须以当前 checkout
的 `git remote -v` 和对应 commit 为准，不应假设旧版本 schema。Direct storage write 不是
普通 Tool，也不应修改 secret、锁文件、迁移 journal 或缓存来“修复”表面症状。

当前正式 Storage 能力是 `storage.inspect`、`storage.validate` 和受限的
`storage.repair`。后者只补齐 App-owned scaffolding；若仍需底层修改，先备份并按上面的
顺序核对 owner、schema、锁和缓存。

## Recommended report

完成后报告：selection 条件、实际 targets、applied/skipped/conflict、Job ID、确认结果、
验证查询、未验证的 UI/签名 App/重启边界。不要把“有多少 Tools”当成任务成功标准。
