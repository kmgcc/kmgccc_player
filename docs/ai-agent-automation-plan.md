# kmgccc_player AI Agent Automation / MCP / CLI 实施计划

本文是 `kmgccc_player` 面向外部 Agent、CLI、脚本和高级用户的长期自动化计划，
也是当前工作树的持续维护文档。它吸收了原始 AI / Agent Automation 计划中的产品
目标，并按当前代码、macOS 权限模型和已完成的实现重新排序。

本文不是 Built-in AI runtime 计划。本轮暂缓内置聊天、Apple Foundation Models、
Pi runtime 和远程聊天 provider；本轮先把播放器本身建设成一个稳定、丰富、可组合、
可审计的 Application Automation 平台。

## 1. 当前状态与工作树

- 工作树：独立工作树 `myPlayer2-ai-agent-automation`
- 分支：`codex/ai-agent-automation-next`
- 基线：`main/origin/main`，commit `236a1b5d`
- 已完成：Phase A–K 的共享协议、Tool Catalog、CLI、AF_UNIX IPC、MCP stdio，以及
  Library / Playlist / 已授权 Referenced Source 的第一条垂直切片
- 当前阶段：Phase E/F 收尾与 P0 验收；共享合同和高价值基础能力已落地，本轮继续补齐
  durable Jobs、Lyrics 候选工作流与可重试批处理，随后仍需完成真实 Host、授权拒绝和前台
  高风险确认验收，不把能力目录数量当作完成度
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
- history、rating、favorite 等真实存在的字段；
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
| Metadata | read/patch/batch/candidates/quality/preview/apply | App metadata 与嵌入文件标签分开，后者风险更高 |
| Artwork | current/candidates/search/quality/preview/apply/batch | 不覆盖更好的手工结果，真实 provider 优先 |
| Playback | state/play/pause/toggle/next/previous/seek/play Track/Playlist/repeat/shuffle/volume | 统一进入 PlaybackCoordinator |
| Queue | get/replace/enqueue/next/remove/reorder/clear/upcoming/revision | 保留手动队列，stale write 冲突 |
| History | query、时间范围、统计、Track/Artist/Album 维度 | 隐私；清空必须高风险确认 |
| Settings | schema/get/patch/validate/reset/preview | 当前只开放有明确 App 合同的持久配置；不开放 hover/动画等临时状态 |
| Audio | 真实存在的 EQ、ReplayGain、output、device、gapless 等 | 不伪造当前没有的 DSP 能力 |
| Diagnostics | library/source/playlist/lyrics/storage/automation/MCP health、report、repair | repair 只做可证明安全的动作 |
| Jobs | create/status/progress/result/retry/cancel、durable/transient、restart 行为 | 扫描、导入、批量歌词/Metadata/Artwork 不阻塞同步 Tool |
| Files | inspect/existence/rename/move/delete | 已实现的物理操作只允许授权 Referenced Source；reveal/copy/export 尚未开放，delete 独立为高风险 |
| Storage | inspect/schema/version/validate/repair/backup/diff/orphan/reload | 当前 inspect/validate/repair 仅覆盖 App-owned scaffolding；不把任意 JSON write 暴露成普通 Tool |
| Import/Export | playlist、metadata、library report、source config、diagnostics machine-readable | 输出不得泄露 secret |

## 6. Permission、Audit、Revision 和 Idempotency

统一 scope 目录，不允许每个 Tool 自己发明权限。首批 scope 以实际开放能力为准，
方向包括：`library.read/write`、`source.read/write`、`playlist.read/write`、
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

当前 adapter 已提供 `server/discover`、`tools/list`、`tools/call`、resources 和 `ping`。
2026-07-28 路径使用无 session 的 per-request `_meta` version；2025-11-25 路径保留
`initialize` / `notifications/initialized` compatibility lifecycle。MCP Tasks、Prompts
和真正的 request cancellation 仍明确列为后续工作；协议行为继续以官方 lifecycle、tools、
resources、errors 和 transports 为准，不得把自定义 wire contract 冒充 MCP。

MCP 未来可暴露的 Resources 包括 capability catalog、schema、Agent behavior guide、
player state、Jobs、diagnostics 和 Source 状态；只有能改善 Agent discoverability
的内容才加入。Prompts 不是安全机制。

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
retry、cancel、result、timestamps、durable/transient 和 restart 行为，再映射到 CLI 和
MCP Tasks（若 SDK/协议适合）。当前已将有界历史持久化到每个资料库的
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
  关系；
- Phase C：Playlist get/rename/delete/replace/reorder、Source create/bind/remove/refresh、
  directory-relative exclude/include、自动监听 on/off、App-owned NSOpenPanel 授权流程和
  已有 Track membership 复用已接入；关闭自动监听仅阻止自动 reconcile，显式 refresh 仍可用；
  missing/reappear、物理 rename/move 的 Track identity 和 Playlist membership 语义已接入；
- Phase C/D：`files.inspect/rename/move/delete` 已接入共享 capability。rename/move 只允许
  已授权 Referenced Source，单文件可直接执行，批量要求 preview 和 App 前台确认；delete
  scope 默认拒绝且始终要求 App 前台确认，执行语义为移入废纸篓并保留 Track；
- Phase D：统一 catalog scopes、持久 scope policy、App 前台高风险确认、opaque revision、
  idempotency key 重试缓存和不记录音乐内容的 JSONL audit 已接入；
- Phase E/F：统一 Job descriptor 增加 progress/phase/failure/cancel，并写入每个资料库的
  `Settings/automation-jobs.json`；终态历史在 App 重启后可查询，未终态 Job 会转为带 recovery
  failure 的 failed 记录；Lyrics/Source retry spec 可通过 `jobs.retry` 重建，Lyrics 批处理
  优先只重试 `failedItemIDs`。Lyrics 已使用现有 provider/ranking pipeline 暴露
  `search/candidates/compare/apply`，refresh 先逐字后逐行，并在写入前检查 Track revision；
  授权后的 Source create/import 与 Source refresh 也已改为立即返回 App-owned Job，避免
  MCP/CLI 请求超时；
- Phase G：App metadata get/patch 已接入，明确不写原始文件 embedded tags；Artwork 当前状态
  已进入 query，candidate mutation 保留给现有 provider owner；
- Phase H/I：Playback、Queue、History、Diagnostics 和 scope status 已提供；已开放有明确
  合同的 `settings.get/patch`（当前为 referenced-track deletion policy）以及 App-owned
  `storage.inspect/validate/repair`（repair 仅修复脚手架）；MCP Resources 已提供
  capability/Agent guide；CLI 有主要命令 alias 和通用 `automation call` escape hatch；设置
  窗口新增“自动化与智能”板块，提供 endpoint、MCP、CLI 开关、socket 状态和风险说明；
- Phase J/K：Capability Reference、Agent Behavior Guide、CLI/MCP/troubleshooting 文档和可加载
  Skill 已落盘，并由 `docs/README.md` 统一索引。

当前明确未宣称已实现：文件 reveal/copy/export、embedded tag 写入、完整 Artwork candidate
apply、超出当前合同的复杂持久 Settings patch、远程 HTTP transport、MCP Tasks 映射、任意
JSON write、Storage backup/diff/orphan/reload。文件
`inspect/rename/move/delete` 已有正式 capability，但真实 delete 仍受默认 denied scope 和
App 前台确认保护；本轮没有删除用户真实文件。

最近验证（2026-09-12）：PlayerAutomation SwiftPM 测试 12/12 通过；Xcode
`MusicSettingsStateTests` 全部通过（含 durable Job history/restart recovery）；App Debug
build 通过。此前 MCP stdio smoke 已验证现代
 `2026-07-28` stateless discovery/per-request metadata、旧版 `2025-11-25` initialize
compatibility、Resources 2 个和 Tools 56 个；`xcodebuild ... -configuration Debug ...
CODE_SIGNING_ALLOWED=NO build` 通过；`git diff --check` 通过。独立 bundle 的真实 Debug App
已通过 MCP 连接外置 SSD `/Volumes/SSD/Music` 的 Referenced Library：创建 Playlist、加入
4 个已有 Track、验证 idempotency、stale revision conflict、物理文件 rename/restore、
`files.inspect`、Source refresh Job 和磁盘上的 Playlist JSON。进一步将其中一个文件临时
移出两个重叠 Source 后 refresh，验证 Track `missing`、Playlist membership 保留；放回后
再次 refresh，验证恢复 `available` 和 Source memberships。`storage.validate` 通过，设置窗口
截图确认“自动化与智能”板块可见，三个开关、socket 状态和风险说明已显示。
仍未验证真实 signed App、第三方 MCP host、拒绝 Source 授权分支、批量文件操作的实际前台
确认交互、MCP Tasks/跨重启真正取消，以及真实 provider 大批量歌词结果。

每完成一个阶段，都必须更新本节、验收矩阵和 `docs/README.md`，记录实际改动、测试、
未验证边界和下一阶段，不得用“Tool 数量”代替验收。

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
- 普通代码修改做匹配的增量 Debug Build；完整 `verify.sh` 只在用户要求或最终门禁运行。
- 真实 App、权限、冷启动、切库、重启、signed build 和 filesystem 行为不能用单元测试
  冒充；交付时分别列出已验证、未验证和建议人工检查。
