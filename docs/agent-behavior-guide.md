# Agent Behavior Guide

这份文档是给 Claude、Codex、脚本和其他外部 Agent 的稳定行为约束。Skill、CLI help 和
MCP Resources 应引用它；它不是安全边界，真正的 scope 和确认 policy 永远由 App 执行。

## Before changing anything

1. 用 `automation.capabilities`/MCP `tools/list` 确认当前版本实际开放的能力。
2. 用 `library.stats` 概览、`library.tracks`／`playlist.get` 分页查询，或通过
   `playlist.diff` 比较集合；队列读取使用带 revision 的 `queue.get`／`queue.upcoming`。
3. 保存返回的 Track/Playlist/Queue revision；可组合 selection 后一次批量提交。
4. 对 medium/high risk mutation 先 `dryRun`，检查影响摘要、skipped、missing、conflict 和 Job。
5. 只在正式接口不能表达需求时才进入 Storage fallback。

## 导入新音频

外部文件或文件夹使用 `library.import`，可同时提供 `targetPlaylistID`。managed 与
referenced 均支持，NCM 由 App 转换。`playlist.addTracks` 仅用于已有 Track ID。

```text
library.import(filePaths, targetPlaylistID?)
    -> MCP Task tasks.get，或 jobs.get 至终态
    -> result / fileTrackMappings / failures / enrichmentWarnings
    -> library.stats / library.tracks / playlist.get / artwork.get / lyrics.get 核验
```

导入与在线补全可能超过一次请求时限；收到 Job 不代表全部完成。按 App 设置自动补全
歌词、封面、曲目／歌手／专辑信息，provider 无结果应报告缺失项。不要为导入手写
`meta.json`、复制 Tracks 目录或外部解密 NCM。取消或重启中断后的导入需要重新调用
`library.import`，使用新 idempotency key，并核验已有 Track 与歌单关系。
MCP modern 请求如声明 Tasks 扩展，会获得绑定 Library 与 Job 的 Task ID；切换资料库后查询前
先切回创建任务的资料库。CLI 与未声明 Tasks 的 MCP 客户端继续使用 `jobs.get`。

跨资料库迁移时，先从来源资料库用 `metadata.export` 导出每页不超过 100 首的版本化文档，
并保留来源 Track ID。导入目标资料库时传 `enrichmentPolicy:"migration"`，让 App 读取嵌入标签与歌词、
跳过联网补全；完成后用 Job 的 `result.fileTrackMappings` 将输入音频绝对路径映射到最终 Track ID。
若输入路径来自 bundle manifest 的 `tracks[].audioPath`，先相对 bundle 根目录解析路径，再按路径连接映射；
据此构造来源 Track ID 到目标 Track ID 的完整 `trackIDMap`，逐页调用已有 `metadata.import`。
最后用 `operations.batch` 按目标 Track 分别应用歌词或封面。不要把源 Track ID 当成目标 ID，
也不要为迁移另写 sidecar。普通 `source.refresh` 只协调来源位置与可用状态，不会覆盖已保存的 Metadata。

## 主 App 启动与实测前置

kmgccc_player 的资料库是独占资源。所有主 App 实测都必须先完成进程状态检查：

1. 运行 ./scripts/check-app-process-state.sh，列出当前 kmgccc_player 的 PID、启动时间和实际二进制路径。
2. 检查到已有进程时，运行入口可以自动处理精确匹配的 kmgccc_player 进程：先记录 PID、启动时间和实际路径，再优雅结束，必要时强制结束。该授权只覆盖主 App 进程，不覆盖其他应用或辅助进程。
3. 进程清理完成并复查为空后，才允许继续构建；启动前立即再检查一次，防止构建期间出现竞争实例。
4. 主 App 的目标是 kmgccc_player。Demo、示例、临时 bundle 和其他测试实例不能作为主 App 的运行验收。
5. 构建成功、LaunchServices 返回成功或窗口曾经出现，都不能单独证明运行成功；交付时至少保留 PID、实际二进制路径和相应的真实界面或功能证据。

scripts/build_and_run.sh 使用运行锁，把这项检查放在构建前和启动前，并在启动后确认只存在一个主进程。不应通过其他命令绕过。

## 歌词组件 Swift Package 前置

歌词组件通过 Swift Package `MelismaKit` 接入，组件原项目是 `NativeLyrics`。修改组件原项目的源码不会改变 App 当前已经解析的远程依赖；因此本机测试不能只看组件仓库的提交，还要确认 App 的依赖图和实际编译输入：

1. 默认运行 `./scripts/check-melismakit-dependency.sh --require-local`，确认 Xcode 工程引用本地 `NativeLyrics` checkout，而不是 `XCRemoteSwiftPackageReference`。
2. 构建使用 `xcodebuild -verbose` 保存的日志，再用同一脚本的 `--build-log` 检查编译输入包含 `NativeLyrics/Sources/MelismaKit`，且没有 `SourcePackages/checkouts/melismakit`。
3. `Package.resolved` 中残留旧远程 pin 只能作为复核信号；真正决定本次构建来源的是工程依赖图和编译日志。不要因为只修改了 `NativeLyrics` 就假设 App 已经使用了这次修改。
4. 只有明确进行远程依赖构建时才使用 `--require-remote`：组件发布新版本 tag 后，App 必须重新解析依赖并核对 `Package.resolved` 的新 revision。

`build_and_run.sh`、`build_app.sh` 和 `verify.sh` 默认执行本地依赖检查；远程构建必须显式设置 `MELISMAKIT_EXPECTED_SOURCE=remote`，不能用手动 `open` 或其他构建入口绕过依赖和进程检查。

## 构建与测试节奏

常规改动不编译。只有客观上属于重大工程变更时，才可在实现全部完成后做一次最终 Debug build-only 编译：跨多个核心子系统并改变共享接口/owner 的架构调整、影响既有资料库的数据迁移，或实质改变 App 与 Swift Package/外部组件依赖边界的集成。文件数或 diff 大小不构成理由；判断不确定时不编译。失败时只修编译错误并再次 build 确认；该例外不包含测试、启动 App、`build_and_run.sh`、`verify.sh` 或 Release 构建。用户在当前任务的明确要求可另行授权这些动作。

测试仍应随行为改动补充或更新，但编译型测试由维护者手动运行，或仅在用户于当前任务明确要求时运行；重大变更的最终编译例外不包含测试。交付时列出未运行项、建议命令和未验证边界。`verify.sh` 只有在用户于当前任务明确要求时才运行；准备合并、PR 或发布本身不构成授权。

`verify.sh` 是完整编译门禁，仅在用户于当前任务明确要求时运行；准备合并、PR 或发布本身不构成授权。GitHub macOS CI 仅保留手动触发，代码推送和 PR 不会自动编译。

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

完整迁移或备份使用 `library.bundle.export`：先 dry-run 检查曲目数、估算体积与不可用文件，
真实导出需要 `files.read` 等相关 scopes、`confirm=true` 和 App 前台确认；App picker 选择目标后
会返回可取消 Job。包内有 path-free Track metadata、Playlist membership、可用音频、Artwork、歌词和
校验清单，不含 Source bookmark 或原始文件路径。轮询 Job 到终态并检查失败项，再验证输出目录。

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

`source.config.export`/`source.config.import` 可在两套已授权的 Referenced Library 之间迁移来源策略。
先导出并 preview；导入不会创建 Source，跨库时必须把每个导出 Source ID 映射到目标库已有 Source。
本机路径、bookmark、扫描状态和 Playlist 绑定留在各自资料库中；不要把配置文档当成目录授权。

## Playlist workflow

“把目录 A 全部加入新 Playlist”应是：

```text
source.list / source.refresh
    -> library.tracks(filter: {sourceID: A})
    -> playlist.create
    -> library.selection.create(trackIDs, expectedRevision)
    -> playlist.addSelection(selectionID)
    -> playlist.get / library.tracks 验证
```

一次查询可直接把 IDs 传给 `playlist.addTracks`。跨页、跨请求或需要复用时，用
`library.selection.create` 可保存有序 ID 快照，也可用 `filter` 保存可重复求值的条件；两类快照
最多解析 10,000 首、保留 30 天，且创建时可用查询 revision 检查新鲜度。predicate 会在读取和
加入歌单时按当前资料重新求值；调用方可传回 selection revision，避免结果已变化时继续操作。

已存在 Library 的歌曲仍必须加入 Playlist；不要因为没有“新导入”就跳过 membership。不要
用删除 Track 来实现“从 Playlist 移除”，也不要用删除 Playlist 来实现“删除文件”。

复杂需求优先用 `all`/`any`/`not`、membership、日期、技术音频、metadata/lyrics 状态和
播放偏好字段组合，而不是请求开发者为每个自然语言句子新增一个专用 Tool。偏好查询可用
`likeState`、播放／完成／跳过次数及最近播放时间；只有在需要读取这些行为数据时才请求
`history.read`。需要检查每首歌的偏好分数时，使用 `library.tracks` 或 `library.report` 的
`includePreferenceStats:true`。

歌词维护应先组合 selection，再使用 `lyrics.search`/`lyrics.candidates`、`lyrics.compare`
和 `lyrics.apply` 处理明确候选；大批量维护使用 `lyrics.refresh` Job。它会逐字优先、无可用
逐字结果再考虑逐行结果，默认不覆盖同等或更高质量的当前歌词。Job 完成后检查
`failedItemIDs`，对可重试的失败使用 `jobs.retry`，不要因超时而盲目重复整批。

## File operations

文件操作只应针对 `files.*` capability，不应通过修改 Playlist、Track sidecar 或任意
Storage JSON 来间接实现。推荐顺序是：

```text
files.inspect
    -> files.reveal / files.export when the user asks to locate or copy audio
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
`files.reveal` 只能定位 App 已授权的文件；`files.export` 通过 App picker 授权目标目录，复制音频
并保留资料库原件。

需要批量整理时，保留返回的 Job ID 并报告每项 failure；不要把文件移动当作“从 Playlist
移除”。如果只需要分类，优先使用 Playlist membership，避免不必要的物理文件改动。

## Lyrics and metadata

- 先查询 `lyricsStatus`/`metadataConfidence`，再批量选择目标。
- Lyrics refresh 返回 Job；不要为几万首歌逐首发同步调用。
- 默认只在新结果质量更高时替换：word-synced > line-synced > plain > none。
- `metadata.get`/`metadata.patch` 把 Track、Artist、Album、Playlist 当作同级实体。用
  `trackID`、`artistID`、`albumKey` 或 `playlistID` 精确指定一个目标；Track 批量仍可用
  `trackIDs`。Track 可修改标题、艺人/credits、专辑、专辑艺人、描述、流派、语言、厂牌、
  发行日期、QQ/MusicBrainz/provider 字段、置信度、抓取时间和歌词偏移；Artist 可修改显示名、
  介绍、标签、地区、外文名和 provider metadata；Album 可修改标题、介绍、年份/日期、类型、
  标签、语言、厂牌和 provider metadata；Playlist 可修改名称和描述。canonical ID、统计量、
  创建/更新时间是只读投影。`metadata.embedded.get` 可实时读取音频文件标签；当前仅 MP3
  ID3v2.3/v2.4 可通过独立的 `metadata.embedded.patch` 写回原文件。
- Track 的 `metadata.search` 汇总 bundled QQMusic helper 与 MusicBrainz 候选，并按标题、艺人、
  专辑及时长计算 provider-neutral `matchQuality`。provider 的 `confidence` 保留原值，不跨来源比较；
  逐 provider 失败会随结果返回。先比较候选和 Track revision，再用 `metadata.applyCandidate` 预览、
  应用；默认只补空字段，`overwriteExistingFields:true` 才覆盖已有值。候选应用会重新验证来源记录，
  并通过 App metadata persistence owner 写 sidecar，不改原音频 embedded tags。
- 写文件标签前先读取 `metadata.embedded.get` 与 Track revision，再运行
  `metadata.embedded.patch` 的 `dryRun`。写入必须显式 `confirm=true` 并经 App 前台确认，
  每首歌曲作为独立原子替换处理；批次 Job 完成后查询逐首结果。非 MP3 或无法安全保留的
  ID3 变体会跳过并报告，不要转码后冒充原文件标签更新。
- `metadata.export/import` 可分页交换版本化 Track metadata JSON，每页最多 100 首；同库导入检查
  Track revision，跨库必须显式提供完整 `trackIDMap`，先 dry-run，再由 App 确认。该文档不包含媒体、
  封面、歌词正文或本机路径；要搬迁完整媒体请使用 `library.bundle.export`。
- 需要先发现目标时，使用 `metadata.get` 的 `entityType`（`artist`、`album`、`playlist`）
  分页读取实体清单，再用返回的 Artist ID、Album canonical key 或 Playlist ID 做后续读写；
  `query` 可按名称、canonical key 或描述筛选。
- `artwork.search` 复用 App 内 NetEase/Sacad/QQMusic 聚合搜索，支持 Track、Artist、Album，
  返回统一 `matchQuality`、provider 原始 `confidence`、匹配信息、`candidateID` 和 `imageBase64`，
  适合 Agent 直接视觉审阅；审阅后用
  `artwork.applyCandidate` dry-run 或应用，无需回传图片字节。候选 ID 绑定资料库、目标和封面
  revision，15 分钟后过期。Playlist 没有联网搜索，但可用 `artwork.get/apply` 维护 Playlist artwork。
  `artwork.get` 只返回 App-owned 封面的存在、文件名、大小、SHA-256 和目标 revision；不把当前
  已写入图片字节塞入查询响应。`artwork.apply` 可使用 App picker、`imagePath`（仅作 picker
  初始位置）、`imageBase64` 或 `clear`，并写入资料库 artwork sidecar。
- `lyrics.apply` 的 `candidate` 和 `ttmlText` 必须二选一。候选遵循质量门槛；`ttmlText`
  适合 Agent 在中间台完成翻译/时间轴微调后直接写回，App 会先验证 TTML 再经现有歌词
  persistence owner 持久化。
- 多首歌曲需要不同 Metadata、封面或歌词内容时，使用 `operations.batch`，每项沿用原工具的
  参数、scope、revision 与结果 envelope；最多 100 项，Job 会逐项保存结果。外层 `dryRun:true`
  会强制所有子项预览；10 项写入或 10 个不同写入目标以上需要 `confirm:true` 和一次前台确认。
  有冲突或失败时只重提对应项，并使用新的 idempotency key。共享 patch/image 或联网歌词刷新继续使用
  现有批量工具 `metadata.patch`、`artwork.apply`、`lyrics.refresh`。
- 不要无条件覆盖已有较高置信度或用户手工数据。Metadata/Artwork 的 10 首及以上批量应先
  `dryRun`；真实调用必须带 `confirm=true`，并等待 App 前台弹窗，调用方的 `--yes` 不能
  绕过弹窗。完成后重新调用对应目标的 `metadata.get`/`artwork.get` 或 `library.tracks`
  验证 applied/skipped/conflicted；不要把 Track revision 复用于 Artist、Album 或 Playlist。
- `diagnostics.health` 同时报告 Library/Source/Job/storage 完整性与缺歌词、缺封面、关键 Metadata
  字段覆盖数；主 `issues` 与 `mediaIssues` 分页独立。媒体检查只对已知路径做存在性/可读性检查，
  能使用任一已记录位置即视为可用，不解码音频；路径缺失提示也不证明文件已永久删除。
  缺歌词、缺封面和关键 Metadata 字段只是内容完整度提示，不等同于存储损坏。

`jobs.wait` 可用 `timeoutMs` 等待 Job 进入终态，默认 20 秒、最多 25 秒；结果包含最新 Job 快照、
`completed`、`timedOut`、`deadlineReached` 与 `waitedMs`。`completed:true` 表示已到终态，终态也包括
`partialFailure`、`failed` 和 `cancelled`；要判断是否成功，检查 `job.state`。等待超时或被取消不会取消 Job；
切换资料库会结束当前等待。批次结果在 `job.result.items[i].response.result`，每项另有完整 `response`；
`background:true` 搜索的原始 Automation response 在 `job.result`，候选数据位于 `job.result.result`。
可先 `jobs.wait`，再用 `jobs.get` 读取完整持久结果。

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
  -> 当前版本 docs；只有机制不明时才查看必要的官方源码
  -> backup
  -> 最小 controlled JSON/filesystem change
  -> schema/invariant validate
  -> reload/rescan/restart（按真实 owner）
  -> query 验证并报告
```

普通自动化不要求本机有源码，也不应为了常规迁移下载源码。确需理解正式工具无法解释的具体故障时，
只查阅官方仓库中与该故障相关的当前版本代码，核对来源和版本后立即删除临时 checkout；不要通读或
保留整份源码。Direct storage write 不是普通 Tool，也不应修改 secret、锁文件、迁移 journal 或缓存
来“修复”表面症状。

当前正式 Storage 能力是 `storage.inspect`、`storage.validate` 和受限的
`storage.repair`。后者只补齐 App-owned scaffolding；若仍需底层修改，先备份并按上面的
顺序核对 owner、schema、锁和缓存。`storage.validate` 的一致性结果与 `mediaIssues` 分开分页；后者只检查
已知媒体路径是否存在且可读，不解码文件，也不把音频状态作为 sidecar/index 一致性失败。

## Recommended report

完成后报告：selection 条件、实际 targets、applied/skipped/conflict、Job ID、确认结果、
验证查询、未验证的 UI/签名 App/重启边界。不要把“有多少 Tools”当成任务成功标准。
