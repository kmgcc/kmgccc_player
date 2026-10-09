# kmgccc_player AI Agent Automation / MCP / CLI 实施计划

本文是 `kmgccc_player` 面向外部 Agent、CLI、脚本和高级用户的长期自动化计划，
也是当前工作树的持续维护文档。它吸收了原始 AI / Agent Automation 计划中的产品
目标，并按当前代码、macOS 权限模型和已完成的实现重新排序。

本文不是 Built-in AI runtime 计划。本轮暂缓内置聊天、Apple Foundation Models、
Pi runtime 和远程聊天 provider；本轮先把播放器本身建设成一个稳定、丰富、可组合、
可审计的 Application Automation 平台。

## 1. 原实施基线与当前状态

- 工作树：独立工作树 `myPlayer2-ai-agent-automation`
- 分支：`codex/ai-agent-automation-next`
- 基线：`main/origin/main`，commit `236a1b5d`
- 历史完成范围：共享协议、Tool Catalog、CLI、AF_UNIX IPC、MCP stdio，以及部分领域能力。
  Phase A–K 的基础落地不表示第 5 节所有目标都已完成。
- 当前阶段（2026-10-04）：跨模式导入、跨来源元数据、Source/Metadata 文档交换、Artwork 质量、Library bundle、MP3 embedded-tag 写回、持久播放偏好查询、导入 Job 重试、History 分页检索、音频输出状态与 App 路由控制、现代 MCP Jobs 资源订阅已实现；逐项验收与格式边界见
  [计划实现审计](automation-plan-audit-2026-10-03.md)。下文各日期 checkpoint 为历史证据。
- 暂缓：Built-in Agent runtime 和任何独立模型数据层

公开仓库地址以当前 `git remote -v` 为准，当前已验证为
<https://github.com/kmgcc/kmgccc_player>。私有资料、私有资源和机器本地路径不应
写入公开文档、公开提交或对外 schema。

## 2. 产品目标

外部 Agent 应能通过 MCP、CLI 或脚本完成开发者没有预先设计 UI 的合理音乐管理
需求。MCP 和 CLI 不是 UI remote control，而是播放器业务能力的两个控制面。

长期目标结构：

```text
普通 UI / CLI / MCP / 未来 Built-in Agent / Background Intelligence
                             |
                 Shared Automation Application Layer
                             |
     LibrarySession / domain services / mutation owners / job owners
                             |
              repository / sidecar / filesystem / external helpers
```

所有控制面必须共享实体语义、验证、权限、revision、jobs、错误和审计，不得让 MCP
复制一套业务逻辑，也不得让 CLI 通过 shell-out 间接实现业务。

## 3. 已确定的产品行为

### 3.1 Track、Library、Playlist、Source 和 File 是不同关系

- `Track` 是资料库中的逻辑歌曲记录。
- `File` 是实际音频文件，可以属于一个或多个外部 `Source`，也可以位于 managed
  library 内部。
- `Library membership` 表示歌曲是否存在于资料库。
- `Playlist membership` 表示歌曲是否属于某个播放列表。
- `Source membership` 表示逻辑歌曲与外部来源路径的关系。

因此：

```text
Track 已经存在 != 不能加入 Playlist
从 Playlist 移除 != 从 Library 移除 != 删除真实文件
```

### 3.2 Source 新增和 macOS 权限

Agent 可以请求新增文件或文件夹 Source。若当前没有 security-scoped access，App
必须在前台发起正确的 `NSOpenPanel` 或等效系统授权流程；用户允许后，App 持久化
bookmark、创建 Source，并让原请求继续执行。用户拒绝时不得留下半成品 Source，
MCP / CLI 应收到结构化 permission denial。

已经授权的 Source 支持查询、刷新、排除规则、自动监听策略和监听状态；CLI/MCP 不得绕过 App 的文件权限
和 LibrarySession owner。

### 3.3 Source 文件消失

默认策略是保守的：文件消失后将 Track 标记为 `missing` / `unavailable`，保留
Track、Playlist membership、Metadata 和 History。文件重新出现时应尽可能恢复
`available`。strict mirror、移除 Library 或移除关联 Playlist 是单独配置的高风险
策略，不能作为默认行为。

### 3.4 Mutation 和确认

低风险 mutation 在已有授权下可以直接执行，例如创建 Playlist、加入 Track、刷新
普通 Source、普通 Metadata patch 和播放控制。所有 mutation 仍必须走统一 policy，
支持 dry-run、幂等和 revision。

只有高风险或难以恢复的动作必须由 App policy 生成影响摘要并在前台确认，例如真实
文件删除、大量 Library 删除、清空 History、破坏性 Source mirror、大规模移动/重命名、
批量覆盖用户手工 Metadata/Lyrics/Artwork、直接 Storage 写入。

Agent 自己在对话里说“确定”不能替代 App 的确认。

## 4. 共享 Automation Application Layer

当前 `PlayerAutomationProtocol` 和 `PlayerAutomationIPC` 是传输与 wire contract，
`AutomationToolCatalog` 是能力描述。下一步要把业务实现逐步集中到 App-owned
application capabilities；适配器只负责输入解析、输出渲染、连接和 transport。

### 4.1 共享合同

每个 capability 至少定义：

- 稳定名称、版本和输入 JSON Schema；
- 结构化结果、分页和稳定错误码；
- read / write / destructive 风险等级；
- 所需 scope；
- dry-run、confirmation、revision、idempotency 要求；
- 是否同步完成或返回 Job；
- 影响摘要、失败项和可恢复方式。

### 4.2 Query / Selection

不要为每个自然语言需求创建特化 Tool。建立可组合的 Selection abstraction，逐步
支持：

- ID、title、artist、album、genre、path、Source、Playlist；
- codec、format、sample rate、bit depth、duration、date added；
- missing、Lyrics status、Artwork status、metadata quality；
- 真实持久的播放偏好字段：手动 `likeState`、播放／完成／跳过计数、总聆听时间、最近播放时间和偏好分数；当前没有数值星级字段；
- text、enum、range、date、path、membership；
- `AND`、`OR`、`NOT` 和稳定排序、分页。

第一版优先结构化 predicate，而不是复制完整 SQL。Selection 结果应能作为后续
Playlist、Lyrics、Metadata、Artwork、Report 和 Job 的输入，并可以携带查询快照或
revision，避免长任务期间悄悄改变目标集合。

## 5. 能力路线图

下面的顺序是实现顺序，不是机械的 Tool 数量清单。某领域只有在当前代码确实存在
相应能力时才开放；不存在的能力要通过 diagnostics 明确报告，而不是伪造。

| 领域 | 对外能力目标 | 主要风险 / 约束 |
| --- | --- | --- |
| Library | list/get/search/filter/sort/page/batch/import/rescan/missing/stats/health | active session、identity、duplicate、文件不被静默删除 |
| Source | list/get/create folder/file/update/rename/remove/enable/disable/refresh/watch/exclude/scan policy | security-scoped bookmark、授权 UI、create/import 与 refresh 返回 Job、missing 默认保留；关闭自动监听不影响显式 refresh |
| Playlist | list/get/create/rename/delete/add/remove/replace/reorder/diff/union/intersection/import/export | membership 与 Library/File 解耦，删除/清空需风险 policy |
| Query / Selection | 结构化 predicate、组合、排序、分页、selection snapshot | 不做不可维护的 SQL clone |
| Lyrics | status/search/candidates/score/compare/preview/apply/refresh/batch/retry | 当前 provider、TTML/LRC、quality policy、长任务 |
| Metadata | read/patch/batch/candidates/quality/preview/apply；实时读 embedded tags，安全写 MP3 ID3v2 | App metadata 与嵌入文件标签分开；其他容器目前只读，文件写入需 revision、preview、前台确认和原子替换 |
| Artwork | current/candidates/search/quality/preview/apply/batch | 不覆盖更好的手工结果，真实 provider 优先 |
| Playback | state/play/pause/toggle/next/previous/seek/play Track/Playlist/repeat/shuffle/volume | 统一进入 PlaybackCoordinator |
| Queue | get/replace/enqueue/next/remove/reorder/clear/upcoming/revision | 保留手动队列，stale write 冲突 |
| History | query、时间范围、统计、Track/Artist/Album 维度 | 隐私；清空必须高风险确认 |
| Settings | schema/get/patch/validate/reset/preview | 当前只开放有明确 App 合同的持久配置；不开放 hover/动画等临时状态 |
| Audio | 真实存在的 EQ、ReplayGain、output、device、gapless 等；支持枚举并持久选择 App 输出设备 | 不伪造当前没有的 DSP 能力；App 路由不修改系统默认设备 |
| Diagnostics | library/source/playlist/lyrics/storage/automation/MCP health、report、repair | repair 只做可证明安全的动作 |
| Jobs | create/status/progress/result/retry/cancel、durable/transient、restart 行为 | 扫描、导入、批量歌词/Metadata/Artwork 不阻塞同步 Tool |
| Files | inspect/existence/reveal/export/rename/move/delete | reveal/export 仅访问 App 已授权路径；export 通过 App picker 复制且保留原件；delete 独立为高风险 |
| Storage | inspect/schema/version/validate/repair/backup/diff/orphan/reload | 当前 inspect/validate/repair 仅覆盖 App-owned scaffolding；不把任意 JSON write 暴露成普通 Tool |
| Import/Export | playlist、metadata、library report、source config、diagnostics machine-readable | 输出不得泄露 secret |

## 6. Permission、Audit、Revision 和 Idempotency

统一 scope 目录，不允许每个 Tool 自己发明权限。首批 scope 以实际开放能力为准，
方向包括：`library.read/write`、`selection.write`、`source.read/write`、`playlist.read/write`、
`lyrics.read/write`、`metadata.read/write`、`artwork.read/write`、
`playback.read/control`、`queue.read/write`、`history.read/write`、
`settings.read/write`、`audio.read/write`、`diagnostics.read/repair`、
`files.read/write/delete`、`storage.read/write`。

Scope 需要支持 requested、granted、denied、temporary、persistent、grant、revoke、
inspect，并由 App policy 保存和执行。MCP/CLI 只传递 caller context，不成为安全
边界本身。

每个会改变可观察状态的对象逐步增加 revision 和 `expectedRevision`。查询之后 UI
先修改时返回结构化 `conflict`，不能覆盖新状态。会被 Agent 重试的 mutation 采用
自然幂等语义或显式 `idempotencyKey`；例如 add membership 应是集合语义，重复请求
不能制造重复关系。

可逆 mutation 优先复用现有 rollback / transaction owner，并逐步提供最小 audit：
时间、caller（UI/CLI/MCP）、capability、target、摘要、结果、Job 和 destructive
confirmation。日志不得保存不必要的用户音乐内容或 secret。

## 7. MCP 设计

MCP adapter 使用独立 executable，通过稳定的本用户 AF_UNIX IPC 调用 App；不复制
Library business logic，也不通过 CLI subprocess 绕行。stdio 是第一 transport；
之后按真实需求评估 loopback HTTP / Streamable HTTP、XPC 和远程授权。

当前 adapter 已提供 `server/discover`、`tools/list`、`tools/call`、resources、现代 Jobs 资源订阅和 `ping`。
2026-07-28 路径使用无 session 的 per-request `_meta` version；2025-11-25 路径保留
`initialize` / `notifications/initialized` compatibility lifecycle。Resources、Prompts 和
MCP Tasks (`tasks/get/update/cancel`) 已接入；只有现代协议请求逐次声明
`io.modelcontextprotocol/tasks` 时，长 Job Tool 才返回 Task 句柄。Task 与 App 持久 Job
共享生命周期；Task cancellation 复用协作式 Job 取消。现代 stdio 可订阅 `kmgccc://jobs`，也可按
`taskIds` 接收标准 `notifications/tasks` 状态通知。stdio 通过 `notifications/cancelled` 取消在途请求，
并将 IPC 连接关闭传播至 App handler；若已取消的请求刚创建 Job 且没有共享的幂等等待者，App 会请求取消该 Job。
已返回的持久 Job 仍通过 `tasks/cancel` 或 `jobs.cancel` 显式取消。Streamable HTTP/XPC/远程授权仍未开放；
这些 transport 在本计划中属于按实际需求评估的范围。
协议行为继续以官方 lifecycle、tools、resources、errors 和 transports 为准，不得把
自定义 wire contract 冒充 MCP。

MCP Resources 已提供 capability catalog、Agent behavior guide 和当前 Jobs；后续可按 Agent
discoverability 增加 schema、player state、diagnostics 和 Source 状态。Prompts 不是安全机制。

Tool 描述必须说明：查询是否只读、是否改变原文件、是否需要确认、分页、错误、
Job 和 membership 语义。不要机械把每个 CLI 子命令都变成一个 Tool。

## 8. CLI 设计

CLI 是正式产品入口，必须同时服务人、shell、脚本、Agent、测试和 troubleshooting：

- 人类可读输出和稳定 `--json` envelope；
- stdout 只输出结果，stderr 输出诊断；
- 稳定 exit code、版本、capabilities 和 scope 状态；
- `--dry-run`、`--yes` / noninteractive、分页、过滤和 batch；
- Job status/progress/cancel、失败项目和 retry；
- shell completion 在命令合同稳定后再加入；
- 默认不偷偷切换 active Library，不静默启动错误的 App 实例。

CLI 和 MCP 共用 DTO、schema、validation、policy、revision、jobs、audit 和 errors。

## 9. Skills 与 Agent 行为文档

Skill 只负责教 Agent 如何理解和组合能力，不是底层安全机制。即使没有加载 Skill，
App 仍必须执行权限和破坏性操作 policy。

最终提供一份可适配不同 MCP host 的 Agent Behavior Guide / Skill，至少包含：

- Domain concepts：Track/File/Library/Playlist/Source/Lyrics/Metadata/Artwork/Queue/Job；
- Playlist membership、Library membership、真实文件删除的区别；
- Source missing 的默认保守行为；
- folder organization、Playlist reconstruction、lyrics maintenance、metadata cleanup、
  source health、missing repair、dedup、complex playlist 的推荐工作流；
- query → preview → apply → verify → report 的组合方式；
- API → Diagnostics/Repair → 文档/源码 → backup → Storage fallback → validate 的顺序；
- 当前仓库版本和 `git remote -v` 的源码调查方法；
- 不覆盖高质量用户数据、不绕过 App policy、不把 UI 临时状态当成业务能力。

## 10. 直接 Storage fallback

任意 JSON / filesystem write 不是普通高频 Tool，但高级 Agent 不能被文档误导为永远
不可能完成。正式顺序必须是：

```text
Automation API
  -> Diagnostics / Repair / Storage API
  -> 当前版本文档和源码
  -> backup
  -> 最小直接修改
  -> schema / invariant validate
  -> reload / rescan / restart
  -> 结果报告
```

Storage API 需要隐藏 secret，明确 owner、schema version、锁、缓存、迁移和恢复边界。
生产真实用户库不能作为破坏性测试对象；使用 temporary fixture 验证。

## 11. 分阶段实施

### Phase A：收尾并审计基础

审查当前未提交差异、恢复 MediaRemote bootstrap、完成真实 App Debug build、审计
MCP version negotiation、CLI contract、错误码、secret/peer/auth 和 lifecycle，补
独立只读 review。验收是 SwiftPM、App build、MCP handshake、CLI JSON 和 dirty baseline
均有证据。分成基础修复、MCP/CLI 合同、文档三个可 review commit。

### Phase B：Query / Selection

在不复制 repository 的前提下建立结构化过滤、排序、分页、membership 和 selection
snapshot。先覆盖真实 Track 字段，再加入技术音频字段、missing、Lyrics/Artwork/quality
状态。验收包括 AND/OR/NOT、分页稳定性、invalid predicate、空集合和 stale snapshot。

### Phase C：Library / Source / Playlist

补齐 get/batch、Source 生命周期、授权流程、refresh/watch policy/exclude rules、missing/reappear/
rename/move、Playlist rename/delete/replace/reorder/diff/export，并把现有 UI 高价值 mutation
逐步接入 shared capability。
必须覆盖目录 A 的 1–10 加 11–15 案例：无 duplicate Track，Playlist 包含 1–15，
已有 Track 可以加入，membership removal 不删文件。

### Phase D：Permission / Confirmation / Audit / Concurrency

建立统一 scope、App 前台授权/确认、风险矩阵、audit、revision、幂等和 conflict。
低风险 mutation 不被无意义确认阻塞；文件删除、mass delete、strict mirror、direct
storage 等高风险动作必须可 preview、cancel、confirm、recover。当前文件 rename/move 已支持
授权范围内直接执行，批量请求要求 preview 和 App 前台确认；delete scope 默认拒绝并始终
要求 App 前台确认。

### Phase E：Jobs / Batch

建立 App-owned Job abstraction：ID、status、phase、progress、completed/total、failures、
retry、cancel、result、timestamps、durable/transient 和 restart 行为，并映射到 CLI 与 MCP Tasks。
当前已将有界历史持久化到每个资料库的
`Settings/automation-jobs.json`，重启时把未终态 Job 恢复为带 recovery failure 的 failed
记录，并对 Lyrics/Source 提供安全重建；Source scan/import、歌词、Metadata、Artwork、repair
不得用无限等待的同步 Tool。

### Phase F：Lyrics

调查现有 provider、candidate、ranking、TTML/LRC、cache 和 replace policy。当前已实现
status/get、search/candidates、compare、apply、quality policy、batch Job 和 retry；refresh
先尝试逐字歌词，没有可用逐字结果再尝试逐行歌词，默认只在新候选明确更好时替换，不覆盖
用户手工结果。仍需补真实 provider/批量失败和前台产品验收。

### Phase G：Metadata / Artwork

分别开放 App metadata 与原始文件 tag 的读写；实现质量检查、candidate、preview diff、
batch 和 conflict。Artwork 遵循同样的 candidate/quality/replace policy，不静默覆盖更好
或手工选择的结果。

### Phase H：Playback / Queue / History / Settings / Audio

复用 `PlaybackCoordinator`、Now Playing 和既有 owner，提供状态、控制、Queue revision、
插播后恢复、历史查询、已具备合同的持久设置 get/patch/validate 和真实存在的 Audio 能力。清空
History、影响巨大的 Settings 和破坏性 Queue 替换单独处理风险。

### Phase I：Diagnostics / Repair / Storage

让 Agent 能解释 Source 不同步、权限/bookmark/watcher/scan/mapping/missing/cache/parser
问题，生成可机器读取的报告。当前提供 App-owned storage inspect/validate 以及只修复缺失
脚手架的 repair；backup、diff、orphan、reload 和任意 JSON fallback 仍需独立的受控实现，
避免把未知 schema 写入伪装成安全 repair。

### Phase J：Skills / Agent Documentation

发布 Domain Skill、Workflow Skill、Capability Reference、CLI Reference、MCP Setup、
Troubleshooting 和 maintenance notes；让 MCP、CLI、Skill 引用同一份核心语义。

### Phase K：MCP / CLI UX 收口

统一 Tool description、schema、resources、errors、versioning、examples、JSON、help、
scope status、Jobs 和 completion。运行真实 MCP host 与 CLI script smoke，不只检查静态
JSON。

### Phase L：完整验收与独立 Review

按真实用户场景进行 temporary fixture、App、MCP、CLI、权限、重启和 GUI regression 验收，
派独立只读 Agent review 当前分支，修复问题后再形成最终阶段 commit；全程不 push。

## 12. 验收矩阵

至少保留以下测试族：

- SwiftPM：协议、frame、secret、catalog、CLI JSON、MCP parser/handshake；
- Query：字段、组合 predicate、排序、分页、空结果、非法输入；
- Library/Source：授权、增量 scan、duplicate identity、missing、rename/move/reappear；
- Playlist：membership、reorder、replace、diff、rollback、revision、幂等；
- Lyrics/Metadata/Artwork：candidate、quality、preview、apply、batch、retry、冲突；
- Jobs：start/status/progress/cancel/retry/restart/result；
- Playback/Queue/History/Settings/Audio：真实已有能力和 owner 边界；
- Diagnostics/Storage：backup、controlled change、validate、reload、orphan；
- MCP：版本协商、tools/resources/prompts（若开放）、结构化错误、tool call、权限；
- CLI：human/JSON、stdout/stderr、exit code、pagination、dry-run、noninteractive；
- Destructive：preview、App confirmation、cancel、confirm、失败恢复；
- Regression：现有 UI workflow、切库、退出、冷启动和真实 signed App。

### 核心 Source / Playlist 场景

```text
A/1.mp3 ... 10.mp3 已在 Library
A/新增 11.mp3 ... 15.mp3
refresh Source A
create Playlist
query Source A
add selection to Playlist
```

结果必须是 Library 只有 1–15、没有 duplicate Track、Playlist 有 1–15，移除
membership 或删除 Playlist 不删除音频文件。Source 文件消失时默认保留 Track、
membership、Metadata 和 History，并在重新出现后尽可能恢复可用状态。

## 13. 当前 checkpoint（2026-09-12）

本轮已把原始计划落成持续维护的实体文档，并在保留 dirty baseline 的新工作树继续实现：

- Phase A：MediaRemote bootstrap 已恢复；PlayerAutomation SwiftPM 测试通过；App Debug build
  通过；MCP lifecycle/version negotiation 已按标准收敛；
- Phase B：`library.tracks` 已支持结构化 `all`/`any`/`not`、membership、状态、日期、技术
  音频字段、稳定排序和 offset 分页；Track summary 返回 source/playlist/lyrics/artwork/metadata
  关系，并返回可用于跨页 stale snapshot 检测的 `revision`；未知顶层参数会按 schema 拒绝；
- Phase C：Playlist get/rename/delete/replace/reorder、Source create/bind/remove/refresh、
  directory-relative exclude/include、自动监听 on/off、App-owned NSOpenPanel 授权流程和
  已有 Track membership 复用已接入；关闭自动监听仅阻止自动 reconcile，显式 refresh 仍可用；
  missing/reappear、物理 rename/move 的 Track identity 和 Playlist membership 语义已接入；
- Phase C/D：`files.inspect/rename/move/delete` 已接入共享 capability。rename/move 只允许
  已授权 Referenced Source，单文件可直接执行，批量要求 preview 和 App 前台确认；delete
  scope 默认拒绝且始终要求 App 前台确认，执行语义为移入废纸篓并保留 Track；
- Phase D：统一 catalog scopes、持久 scope policy、App 前台高风险确认、opaque revision、
  idempotency key 重试缓存和不记录音乐内容的 JSONL audit 已接入；MCP 默认使用 JSON-RPC id
  保持同一请求的 mutation 重试幂等；Source picker 授权失败返回结构化 denial；
- Phase E/F：统一 Job descriptor 增加 progress/phase/failure/cancel，并写入每个资料库的
  `Settings/automation-jobs.json`；终态历史在 App 重启后可查询，未终态 Job 会转为带 recovery
  failure 的 failed 记录；Lyrics/Source retry spec 可通过 `jobs.retry` 重建，Lyrics 批处理
  优先只重试 `failedItemIDs`。Lyrics 已使用现有 provider/ranking pipeline 暴露
  `search/candidates/compare/apply`，refresh 先逐字后逐行，并在写入前检查 Track revision；
  授权后的 Source create/import 与 Source refresh 也已改为立即返回 App-owned Job，避免
  MCP/CLI 请求超时；
- Phase G：App metadata get/patch 已接入，明确不写原始文件 embedded tags；Artwork 当前状态
  已进入 query，并通过 App-owned artwork apply 直接写入 sidecar；provider candidate search/
  ranking 仍保留给后续专门 owner；
- Phase H/I：Playback、Queue、History、Diagnostics 和 scope status 已提供；已开放有明确
  合同的 `settings.get/patch`（当前为 referenced-track deletion policy）以及 App-owned
  `storage.inspect/validate/orphans/backup/diff/reload/repair`。Diagnostics 会投影 failed
  Job、Playlist orphan reference 和 storage validation evidence；backup 是 metadata-only，
  不复制音频、index、cache 或 live SQLite。MCP Resources 已提供 capability/Agent guide；
  CLI 有主要命令 alias 和通用 `automation call` escape hatch；设置窗口新增“自动化与智能”
  板块，提供 endpoint、MCP、CLI 开关、socket 状态和风险说明；
- Phase J/K：Capability Reference、Agent Behavior Guide、CLI/MCP/troubleshooting 文档和可加载
  Skill 已落盘，并由 `docs/README.md` 统一索引。

2026-09-12 时的阶段记录没有覆盖后续加入的 MCP Tasks、文件 reveal/export 和设置扩展；这些
历史边界已分别在 2026-10-03 checkpoints 更新。当时记录的限制包括原音频 embedded tag 写入、
统一跨 provider metadata/artwork quality policy、可重新求值的持久筛选 predicate、包含媒体文件的
完整资料库 bundle 导出、远程 HTTP transport 和任意 JSON write。真实文件 delete 仍受默认 denied scope 和 App 前台
确认保护；历史验证未删除用户真实文件。

最近验证（2026-09-12）：PlayerAutomation SwiftPM 测试 16/16 通过；Xcode
`MusicSettingsStateTests` 全部通过（含 durable Job history/restart recovery）；从当前工作树
生成的独立 Debug App 产物启动成功；`MCP stdio smoke` 已验证现代
`2026-07-28` stateless discovery/per-request metadata、旧版 `2025-11-25` initialize
compatibility、Resources 2 个和 Tools 65 个；`xcodebuild ... -configuration Debug ...
CODE_SIGNING_ALLOWED=NO build` 通过；`git diff --check` 通过。独立 Debug App 的真实 MCP
会话已完成 initialize、`source.list`、`playlist.get`、`storage.validate`、Playlist 幂等
加入、`files.delete` dry-run 和 Lyrics candidates；连接的 Referenced Library 为
`0D4C4169-7848-44B0-A149-984C698D9063`，Source 为外置 SSD `/Volumes/SSD/Music/testmus`
及其 `810` 子目录。MCP 发起 Source refresh Job `E711F5A9-F58A-4EC2-90A9-A3E7A02C305F`
并完成；重启同一独立 App 后仍可通过 CLI 读取该 Job、测试 Playlist membership 和 storage
validation，磁盘上的 `Settings/automation-jobs.json` 与 Playlist JSON 均已核对。现有
12 个 missing Track 仍保留 Library、Metadata/Playlist 关系，健康诊断正确报告 missing。
已使用本机 Claude Code 作为第三方 MCP Host，通过临时只读配置成功读取 `system.info` 和
`source.list`，没有发生 mutation。临时关闭 `automationMCPEnabled` 或
`automationCLIEnabled` 的实测分别返回结构化 `authorizationRequired`，随后已恢复为原本的
未显式设置（代码默认开启）状态。设置窗口截图确认“自动化与智能”板块可见，三个开关、
socket 状态和风险说明已显示。
随后按单实例资料库规则停止旧 App，启动当前工作树生成的新 Debug App，并把 active library
恢复到外置 SSD 上的 managed Library `678B60AF-724E-4202-A9A9-D4A0DC6555A3`。通过 CLI
和 MCP 实测了 `storage.orphans`、`diagnostics.health`、`storage.backup`、`storage.diff`
和 `storage.reload`：backup 复制 1,736 个 metadata/sidecar 文件、无失败且未包含音频；
现有 managed Library 的真实校验仍报告原有的 `playlistReferenceMissing`，同一个 missing
Track `D88945DC-BCCB-4FEC-9E89-9CEF82B524A3` 被 `apl` 与 `2026` 两个 Playlist 引用。
这些历史数据没有被自动清理，orphan 检查保持只读。
仍未验证真实 signed App、拒绝 Source 授权分支、批量文件操作的实际前台确认交互、真实
高风险文件删除、MCP Tasks/跨重启真正取消，以及真实 provider 大批量歌词结果；本轮没有
删除或移动外置 SSD 上的真实音乐文件。一次独立只读 review 因外部模型预算耗尽未返回报告，
因此不把它计作 review 通过。

每完成一个阶段，都必须更新本节、验收矩阵和 `docs/README.md`，记录实际改动、测试、
未验证边界和下一阶段，不得用“Tool 数量”代替验收。

### 13.1 资料库生命周期补齐 checkpoint（2026-09-19）

本轮人工试用暴露了一个真实的产品缺口：目录只有 `library.list`/`library.tracks`，
外部 Agent 无法完成“新建并切换资料库”这一正常协同流程。现已把 App 已有的
LibrarySession owner 接入共享 Automation contract，新增：

- `library.create`：创建并激活 managed/referenced 资料库；
- `library.open`：通过 App-owned picker 打开并登记已有资料库；
- `library.switch`：按已登记 ID 切换 active Library；不可访问时返回
  `interactionRequired` 并指向 `library.open` 重连；
- `library.rename`、`library.relocate`、`library.remove`：分别修改显示名、通过
  recovery transaction 搬迁、或移入 macOS 废纸篓。

这些能力共用 CLI/MCP/未来内置 Agent 的 catalog、scope、dry-run、confirm、idempotency
和 audit contract。新增 `library.manage` 默认开放；`library.delete` 与已有的
`files.delete`、`storage.write` 仍默认拒绝，删除预览可在不授予 delete scope 时执行。
路径只作为 AppKit picker 导航提示，不能代替 security-scoped authorization。目录从 65
扩展为 71 个 capability；其它审查结论是当前已开放的 Playlist/Source/Metadata/Playback/
Queue/History/Lyrics/Jobs/Diagnostics/Settings/Storage/Files scopes 已有对应 handler，
没有再发现仅因 catalog policy 遗漏而无法完成的普通操作。仍未开放的是任意 JSON write、
embedded tags、Artwork candidate mutation、远程 HTTP 和 MCP Tasks。

本轮已验证：PlayerAutomation SwiftPM tests、Debug App 增量编译和 `git diff --check`；
新的资料库生命周期尚待用包含本轮代码的独立 App 完成真实 picker/alert/切库/恢复人工
smoke，不能用协议层测试代替。真实 signed/sandbox 分发仍是后续发布门禁。

### 13.2 Metadata / Artwork 控制扩展 checkpoint（2026-09-19）

人工试用继续暴露了一个实际缺口：已有 `artworkRead`/`artworkWrite` scope，却没有
对应的独立 handler；`metadata.patch` 也只覆盖少量字段。现已补齐：

- 新增 `artwork.get`：返回每首 Track 的 App-owned 封面存在状态、文件名、字节数、SHA-256
  和 Track revision，不把图片字节直接回传；
- 新增 `artwork.apply`：支持 App-owned NSOpenPanel、`imagePath` 初始目录提示、
  `imageBase64` 和 `clear`，通过现有 `persistTrackMetaAndArtwork` owner 写入 sidecar；
- `metadata.get` 的 Track summary 增加当前模型已有的 credits、描述、语言、厂牌、provider
  IDs、抓取时间、置信度、MusicBrainz release ID 和歌词偏移；`metadata.patch` 同步支持
  这些字段，并保持 expected revision/concurrency 检查；
- Artwork 和 Metadata 的 10 首及以上批量真实写入都要求 `confirm=true` 并由 App 前台
  弹窗确认；`dryRun` 可在不触碰数据前查看 targets/skipped/conflicts；
- CLI alias、MCP catalog/schema、Agent guide、capability reference 和 skill 已同步。

本轮明确没有伪造“原始音频 embedded tag 写入”：当前代码没有可复用的音频格式 writer
owner，直接改原文件会绕过现有 sandbox/备份/失败恢复边界，因此仍作为独立后续能力设计。
当前 catalog 由 71 扩展为 73 个 capability。已完成协议测试和 App Debug build；真实
封面选图、sidecar 落盘、批量 10 首弹窗、清除封面、重启后读取和 signed/sandbox 分发仍
需要在独立测试 App / 发布产物上人工验收。

### 13.3 Artwork 搜索与直接 TTML 写回 checkpoint（2026-09-19）

根据人工试用提出的“搜索候选 → Agent 视觉审阅 → 应用”和“歌词中间台精修后直接写回”
缺口，本轮继续扩展同一 App-owned contract：

- 新增只读 `artwork.search`，按 `trackID` 复用共享的 NetEase、Sacad、QQMusic 搜索聚合与
  排名，返回最多 5 个候选；每个候选含来源、匹配字段、分辨率、置信度、原图 URL 和
  `imageBase64`/MIME 信息，可由 Agent 直接视觉审阅后把图片数据交给 `artwork.apply`；
- `lyrics.apply` 的 `candidate` 改为与 `ttmlText` 二选一。`ttmlText` 走与手工编辑相同的
  TTML 校验和 repository owner，支持 `dryRun`、Track revision conflict 和持久化后结果，
  不把精修文本绕过现有 owner 直接写文件；
- 封面 provider 服务提升为当前 LibrarySession 的共享依赖，交互式编辑器和 Automation
  搜索使用同一 session-scoped service/cache，避免两套 provider 状态；
- CLI alias、MCP catalog/schema、协议测试、Agent guide、capability reference 和 skill 已
  同步；catalog 当前由 73 扩展为 74 个 capability。

已完成 PlayerAutomation 测试、Xcode ARM64 Debug build 和 `git diff --check`；新的
`artwork.search` 网络 provider 返回质量、实际 `ttmlText` 应用后的重启读取、签名/sandbox
分发及人工多模态审阅仍需在独立运行 App / 发布产物上完成验收。

### 13.4 Entity-first Metadata / Artwork checkpoint（2026-09-19）

本轮继续按人工试用暴露的抽象缺口审查实体对等性，确认 Track、Artist、Album、Playlist 的
实际 sidecar/UI owner 后，把 Metadata/Artwork contract 从 Track-only 扩展为实体级目标：

- `metadata.get/patch` 支持 `trackID`、`artistID`、`albumKey`、`playlistID` 四选一；保留
  Track 的 `trackIDs` 批量兼容路径。Artist 和 Album 的显示/描述/分类/provider 字段可写，
  Playlist 的名称/描述可写；canonical identity、统计量、创建/更新时间作为只读投影返回；
- `artwork.search` 复用现有 Artist provider 和 Album/Track CoverSearch pipeline，支持
  Track/Artist/Album；`artwork.get/apply` 支持四类实体，Playlist artwork 使用已有 sidecar
  custom/generated owner，不伪造 Playlist 联网搜索；
- 新增实体级 artwork/metadata revision，并让旧 Track `expectedRevisions` 与新增 artwork
  revision 保持兼容；Artist artwork 文件清除、Album artwork 写回、Playlist artwork 清除均
  走 App-owned persistence owner；10 首及以上 Track artwork/metadata batch 继续由 App
  前台确认保护；
- CLI 新增 `--track-id`、`--artist-id`、`--album-key`、`--playlist-id` 目标选择器；协议
  Codable 对新增结果字段提供旧响应默认解码；另外 `metadata.get` 支持
  `entityType + query + offset/limit`，让 Agent 可以先发现 Artist/Album/Playlist 再操作；
  Capability Reference、CLI/MCP 文档、Agent guide 和 Skill 已同步。

本轮已完成 PlayerAutomation SwiftPM 18/18 测试、CLI product build、Xcode ARM64 Debug
build 和 `git diff --check`（仍需在最终收口后重跑）。尚未把协议层成功当作运行验收：Artist/
Album/Playlist metadata 与 artwork 的真实 sidecar 落盘、切库后的目标隔离、旧响应/旧 CLI
互操作、10+ Track 确认弹窗、重启读取和 signed/sandbox 分发仍需独立 App 与发布包人工验收。

## 14. 与本轮原始计划的对齐

本轮对话提供的长篇原计划是需求全集；本文是把它落成仓库内可持续维护的公开版本，
不是只记录对话结论的附件。原计划中已经确定的产品语义全部作为本文件的约束保留：
外部 Agent 高自主但由 App policy 管理高风险动作、Agent 可发起 Source 授权、Source
文件消失默认保留 missing Track、普通 mutation 直接执行、MCP/CLI 共用业务层、Built-in
AI 暂缓，以及正式 API 之后允许谨慎 Storage fallback。

两者的差别在于：原计划覆盖未来完整范围，本文额外绑定了当前代码的 owner、schema、已
开放 capability、验证证据和未开放边界。当前代码与旧文档冲突时，以代码和本文件的
checkpoint 为准；新能力必须先更新这里，再更新 CLI/MCP/Skill 的引用，避免三套语义漂移。

## 15. 实施纪律

- 先读当前代码和 dirty baseline，再做最小可运行改动。
- 保护其他 worktree、用户改动、私有子仓库和 AMLL 生成物。
- 每个阶段使用一个或少量独立、可 review、可 revert 的本地 commit；不 push。
- 常规改动不编译。只有跨多个核心子系统并改变共享接口/owner 的架构调整、影响既有资料库的数据迁移，或实质改变 App 与 Swift Package/外部组件依赖边界的集成，才可在实现全部完成后做一次最终 Debug build-only 编译；文件数或 diff 大小不构成理由，判断不确定时不编译。失败时只修编译错误并再次 build 确认。此例外不包含测试、启动 App、`build_and_run.sh`、`verify.sh` 或 Release 构建；测试及其他编译动作仍须用户在当前任务明确要求，完整 `verify.sh` 也仅限明确要求。
- 真实 App、权限、冷启动、切库、重启、signed build 和 filesystem 行为不能用单元测试
  冒充；交付时分别列出已验证、未验证和建议人工检查。

## 16. 当前 checkpoint（2026-10-03，导入闭环）

原计划第 5 节的 Library import 未由 Source create/refresh 完整覆盖：此前它们仅允许
referenced，managed 没有正式外部导入入口。这是实现遗漏，并非计划取消。

本轮新增 `library.import` 与 CLI `library import`，复用手动导入的 destination context、
FileImportService、NCM 转换和 enrichment owner。支持文件／目录及可选歌单；立即返回
Job，结构化结果持久化到 Job 历史，区分入库失败和后台补全无匹配。无需独立转换工具即可
处理 NCM 导入。该 checkpoint 当时尚未支持跨重启重试；后续 §23 增加 `jobs.retry`，由调用方重新
提交 `filePaths` 并由 App 再次取得授权，identity 去重继续生效。

详细状态与实际验收记录维护于 [计划实现审计](automation-plan-audit-2026-10-03.md)。
旧文档中的“Artwork candidate mutation 未开放”需结合后续 `artwork.search/apply` checkpoint
阅读；后续已加入 15 分钟、Library/target/revision 绑定的候选 ID 直用合同；跨 provider 统一质量
策略仍待实现。

## 17. 当前 checkpoint（2026-10-03，读取、播放列表和队列控制扩展）

按第 5 节与第 12 节的路线补上低风险且有现存业务 owner 的组合能力：

- `library.stats` 汇总活动库曲目可用性、实体数、来源关联、补全覆盖和时长。
- `playlist.diff` 以首个歌单的稳定次序返回多个歌单的 union、intersection 或 directional difference，支持分页。
- `playback.toggle`、`playback.playPlaylist` 通过 PlaybackCoordinator 统一处理。
- `queue.remove/reorder/upcoming` 使用队列 revision；重排按多重集合校验以保留重复条目语义。
- 队列清空现在能把空集合送到 SmartPlaybackController，同时保留已载入的当前音频。
- `history.stats` 按时间范围汇总播放次数、聆听秒数以及 Track/Artist/Album 聚合。
- `source.get` 与 `source.rename` 提供单条策略读取和保留授权状态的显示名修改。
- `settings.schema/validate/reset` 与 `audio.get/patch` 补齐受支持设置的发现、无副作用校验、gapless 控制和 App 输出路由选择。
- `playlist.import/export` 通过有序 M3U8 文本交换歌单；绝对路径导出受 `files.read` scope 控制。

截至该 checkpoint，CLI、Capability Reference 和 Agent Behavior Guide 已同步新增合同。原始音频 embedded-tag 写回、
跨 provider metadata/artwork quality policy、可重新求值的持久筛选 predicate、Source/Metadata 文件交换、
完整 Library bundle 导出、更多 Settings／真实 Audio 控制、跨重启路径授权恢复及更广的
诊断报告仍需按 owner 逐项补齐；逐项状态见计划实现审计。无可复用 owner 的硬件音频路由、
内置模型运行时或远程授权不会伪装成已实现能力。

## 18. 当前 checkpoint（2026-10-03，Tasks、Metadata 候选和文件操作）

- MCP 2026-07-28 Tasks 扩展现映射 App 的持久 Job；`tools/list` 按 capability 标记可异步工具，
  `tools/call` 只在客户端逐请求声明扩展且 Job 已可读取时返回 Task。新增 `tasks/get`、
  `tasks/update`、`tasks/cancel`，Library/Job 复合句柄支持切库隔离。该 checkpoint 当时尚未实现
  Task 通知订阅；后续已在 §26 补齐。通用在途请求取消仍未实现。
- `metadata.search/applyCandidate` 复用 QQMusic helper 与 App 的 detail/persistence owner。候选
  返回 Track revision 和实际 `previewPatch`；默认仅补空字段，覆盖必须显式启用。原音频标签写入
  仍没有安全的 App-owned persistence owner。
- `files.reveal` 通过授权的 Managed/Referenced 路径在 Finder 定位；`files.export` 通过 App picker
  获得目标目录，复制音频且避免覆盖重名文件，不修改资料库原件。文件导出未复制 metadata sidecars。
- `artwork.search` 为每个候选生成 Library/target/revision 绑定的稳定 `candidateID`；
  `artwork.applyCandidate` 可直接 dry-run 或应用候选，15 分钟过期、切库和 revision 冲突时拒绝写入。
- MCP 已有 Resources/Prompts，本轮再加入 `import_audio_workflow`。审计同步至 [计划实现审计](automation-plan-audit-2026-10-03.md)。

PlayerAutomation package build、modern MCP catalog/Prompt/Tasks capability smoke、MelismaKit 本地
依赖检查、主 App Debug build 均通过。未启动主 App；Finder picker、sandbox 授权、真实 QQMusic
provider 和物理文件 export 未做运行验收。完整剩余项与 transport 评估边界见审计表。

## 19. 当前 checkpoint（2026-10-03，Artwork 候选直用与持久 Selection）

- `artwork.search` 候选增加由 Library、实体目标、provider item 和图片 digest 组成的稳定 opaque
  `candidateID`；`artwork.applyCandidate` 支持 dry-run 与直接应用，候选在 App 内存保留 15 分钟，
  绑定搜索时的 artwork revision，并校验活动 Library 与目标。
- 新增 `library.selection.list/create/get/delete` 和 `playlist.addSelection`。selection 可持久保存
  有序 Track IDs，或保存 `library.tracks.filter` 结构化 predicate；不存媒体或路径。每 Library 最多
  100 个、每次最多解析 10,000 首、30 天后过期，文件使用 App Support 私有权限。predicate 在读取和
  加入歌单时按当前 Library 重算；可用 `expectedRevision` 与 `expectedSelectionRevision` 拒绝过期结果，
  并继续复用原 Playlist mutation owner 和 expected playlist revision。
- 新增 `library.report` 版本化分页读取，把 Library stats、Track metadata 投影和 Playlist 摘要合并为
  machine-readable JSON；Track 与 Playlist 可独立分页、每页上限 100，并共用集合 revision。文件路径需
  显式请求且要求 `files.read`。报告不包含图片、歌词正文或音频；完整含媒体 Library bundle 导出仍未实现。
- CLI alias、Zsh completion、Capability Reference、Agent Guide 和本计划已同步。embedded tags、
  Source/Metadata 文件交换和包含媒体文件的完整 Library bundle 导出仍有明确 owner/格式边界，
  后续按审计表处理。

## 20. 当前 checkpoint（2026-10-03，Source 配置交换）

- 新增 `source.config.export/import`，用 schema-versioned JSON 迁移 Referenced Source 的显示名、
  自动监听策略与排除路径；不导出文件路径、security-scoped bookmark、扫描状态或 Playlist binding。
- 跨库导入必须把每个来源映射到目标资料库已有 Source；支持 dry-run、当前配置 revision 和 App 前台确认，
  写入复用 AppSessionHost 的 Source owner。CLI 与 Zsh completion 已提供对应入口。
- PlayerAutomation 21 项协议／传输测试、CLI Debug build、MelismaKit 本地依赖检查和 App Debug
  build 均通过；主 App 未启动，picker／授权／磁盘持久化尚未做真实运行验收。
- Track metadata 投影新增导入时 `embeddedMetadataSnapshot`，经 `metadata.get`、`library.tracks` 和
  `library.report` 一并读取；它是历史快照，不会重新打开音频文件。

Source policy exchange 已实现。后续缺口收窄为原音频 embedded tags、Metadata 文件包、跨 provider
Artwork 质量流程、完整 Library media bundle 与 Diagnostics 深化；HTTP/XPC/远程授权仍按原计划
基于真实需求评估。

### 21. Metadata 跨来源候选与质量排序（2026-10-03）

- `metadata.search` 现聚合 bundled QQMusic helper 与 MusicBrainz recording search。结果分别包含
  provider 原生 `confidence`、provider-neutral `matchQuality` 与逐 provider 错误；字段匹配分数按
  标题 45%、艺人 30%、专辑 15%、时长 10% 计算，缺失字段按剩余权重归一化。该值表达文本／时长
  相似程度，用于候选排序，不表示 provider 成功概率。
- MusicBrainz 使用 App 版本和项目 URL 构成 User-Agent，所有 search/lookup 请求经单 actor 排队，
  平均不超过每秒一个请求。MusicBrainz 候选以 `musicbrainz:<recording UUID>` 标识；应用前重做
  搜索并 lookup 录音详情，可补标题、艺人、专辑、流派标签、发行日期及 release ID。写入仍走现有
  Metadata patch owner、默认只填空字段、dry-run 与 Track revision 冲突保护。
- PlayerAutomation 22 项测试、CLI Debug build、MelismaKit 本地源检查和 App Debug build 通过。
  尚未通过主 App 运行流程验证真实 MusicBrainz 网络结果与候选质量；新的 MCP 客户端需重新发现工具。

## 22. 当前 checkpoint（2026-10-03，文件内标签读写与完整 Library bundle）

- 新增 `metadata.embedded.get/patch`。读取重新打开当前受授权的音频文件；MP3 直接解析 ID3v2，
  其他容器使用 AVFoundation 可提取的字段，并明确标记不可写。App sidecar metadata 与文件内标签
  维持独立 owner。
- 写入目前支持 MP3 ID3v2.3/v2.4 的标题、艺人、专辑、专辑艺人、作曲、流派、年份、曲目号、
  碟号、评论和歌词字段。先用 `dryRun` 检查目标与 Track revision；正式写入要求
  `confirm=true` 和 App 前台确认，每文件在同目录暂存、标签读回校验后原子替换，批次用可取消
  Job 顺序执行并逐首报告。其他格式、损坏文件、或带有当前 writer 无法安全保留的 ID3 特性会拒绝，
  原文件保持不变；这条路径不转码。
- `library.bundle.export` 以可取消 Job 输出 path-free Track Metadata、Playlist membership、
  可用音频/Artwork/Lyrics 与 SHA-256 manifest；destination 由 App picker 授权，导出不含本机路径、
  security-scoped bookmark 和 Source 授权。
- `diagnostics.health` 增加 Lyrics、Artwork、关键 Metadata 覆盖率；Artwork 候选有统一质量排序，
  文档交换和跨 provider 元数据搜索均已落地。CLI alias、completion、Agent Guide、Capability
  Reference 和 MCP catalog/schema 均已同步。
- 代码验证包括 PlayerAutomation SwiftPM 26/26 测试、MP3 writer 与 Library bundle 定向 XCTest 4/4、
  App ARM64 Debug build、MelismaKit 本地编译输入检查和 UI strict-copy 门禁；主 App 未启动。
  真实授权、前台确认、不同 MP3 encoder 标签变体和 signed/sandbox 文件替换仍需真实 App 验收。

当前代码层剩余边界是非 MP3 容器 embedded-tag 写回以及无持久 owner 的复杂全局 Settings。
AudioFile API 对 MP3、WAV 和 M4A 的写入探测均返回不可写，因此没有复用它；后续需引入
经过审查的容器专用 writer 并分别验证。导入 Job 重启后可用 retry spec 恢复目标 Playlist，但要求
调用方重新提供文件并重新取得系统授权；retry spec 不保存输入路径或 bookmark，逐文件失败结果
仍可能包含用于诊断的路径。stdio request cancellation 已贯通 MCP 与 AF_UNIX IPC；HTTP/XPC/远程授权
仍需单独的 transport 与身份边界设计。内置 Agent/runtime 继续暂缓，不作为本地 stdio automation 的缺失实现。

## 23. 当前 checkpoint（2026-10-03，播放偏好查询与导入 Job 重试）

- Query / Selection 现在读取持久化 `TrackPreferenceStats`：可按手动 like、播放／完成／跳过计数、
  总聆听时间、最近播放时间和偏好分数过滤、排序，并可选择返回统计投影。查询、动态 predicate、
  报告和加入歌单会按实际字段依赖检查 `history.read`；默认的纯 metadata 查询不会读取历史。
- Preference predicate 可嵌套 `all/any/not`，并参与 Selection revision；统计投影属于 revision
  内容，旧 Track DTO 缺少 `preferenceStats` 时继续解码为 nil。CLI 的 `library tracks --params-json`
  可组合使用新增字段。
- `jobs.retry` 新增导入重试：retry spec 只持久保存目标 Playlist ID，不保存输入路径或书签；跨重启后
  由调用方重新提供 `filePaths`，App 重新获取所需授权，再通过相同导入／去重／补全 owner 启动新 Job。
- 当前验证：PlayerAutomation SwiftPM 27 项通过；Query、MP3 embedded tags、Library bundle 与
  Job restart/retry spec 定向 XCTest 8 项通过；MelismaKit 本地依赖来源、CLI 无启动解析 smoke 和
  `git diff --check` 均通过。主 App 未启动。App picker／系统授权、真实 provider 与播放器硬件路径仍属运行验收边界。

## 24. 当前 checkpoint（2026-10-03，历史查询分页）

`history.list` 补上时间窗之外的组合检索和续页能力：支持全文本、Track ID、艺人片段与专辑片段筛选，
返回 `total`、`offset`、`limit`、`nextOffset`，并接受 `expectedRevision` 检测翻页期间的新播放记录。
CLI 现开放 `--offset`、`--query`、`--track-id`、`--params-json` 与 `--expected-revision`。历史由 App-owned
PlaybackHistoryStore 提供；查询只读，不改变播放器或 History。此增量遵照当前不启动真实 App／第三方 Agent
的要求，只完成源码与文档检查，未新增编译或运行验收证据。

## 25. 当前 checkpoint（2026-10-04，音频输出状态读取）

`audio.get` 读取 Core Audio 系统默认与 App 实际输出状态，并列出可用设备；`audio.patch` 支持 gapless
设置与持久化 App 输出路由选择，设备 UID 使用稳定 opaque ID 对外呈现。输出选择沿用现有 renderer route
owner，不修改系统默认设备。此阶段只审阅源码与文档，未启动 App 或运行编译／测试。

## 26. 当前 checkpoint（2026-10-04，MCP Jobs 资源订阅）

新增 `kmgccc://jobs` 动态 Resource，读取当前资料库的 Job 快照；现代 stdio MCP 客户端可用
`subscriptions/listen` 订阅该 URI，也可按 `taskIds` 订阅 Tasks 扩展的 `notifications/tasks`。
服务端确认受理的过滤器后，在后台约每 2 秒读取既有 `jobs.list` 接口：Job 列表变化时发资源变更通知，
Task 状态或进度变化时发完整 Task 状态通知。Task 通知要求请求逐次声明 Tasks 扩展；通知均带关联订阅 ID，
取消通知会结束对应 listen 请求。订阅轮询不会自动启动 App。legacy 客户端仍可通过 `jobs.get` 轮询。
通用 MCP 在途请求取消见 §28。

此增量只完成源码与文档审阅及 `git diff --check`，未运行编译、测试、主 App 或第三方 Agent 实测。

## 27. 当前 checkpoint（2026-10-04，App 输出设备控制）

`audio.get` 增加可用输出设备清单和 App 实际输出快照；对外设备 ID 是由 Core Audio UID 派生的稳定 opaque
标识，不返回原始 UID。`audio.patch.values.outputDeviceID` 接受该清单中的设备 ID，`null` 表示跟随系统默认；
偏好写入 AppSettings，通过 `AVAudioPlaybackService` 连接现有 `RendererPlaybackPipeline` 路由能力，并纳入
`expectedRevision` 与 dry-run。系统默认输出保持由用户和 macOS 管理。此增量只做源码与文档复核，遵照用户要求，
未运行构建、测试或真实音频设备验收。

## 28. 当前 checkpoint（2026-10-04，MCP 在途请求取消）

stdio adapter 将有 request ID 的 MCP 请求交由并发处理，读循环可继续接收 `notifications/cancelled`。
取消会关闭该请求拥有的 AF_UNIX socket；App listener 观察到 peer disconnect 后取消对应 handler，并通过
cancellation token 通知 AutomationIPCServer。若已取消的请求返回了新建 Job，且没有同幂等键的其他等待者，
App 会调用现有 Job cancel owner；已发出的 Task/Job handle 仍使用 `tasks/cancel`/`jobs.cancel`。
CLI/stdin 结束时也会取消所有尚未完成的请求。当前范围限于本地 stdio + AF_UNIX；阻塞中的 AppKit 面板、
外部 provider 和 HTTP/XPC transport 需要各自的取消 owner，未在本 checkpoint 宣称覆盖。

PlayerAutomation SwiftPM build、App ARM64 Debug build、依赖 preflight 与 `git diff --check` 通过；
没有启动主 App，也没有第三方 Agent 实测。
