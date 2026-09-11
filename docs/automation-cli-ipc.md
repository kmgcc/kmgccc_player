# Automation CLI / 本地 IPC / MCP

这是当前 Automation contract 的入口说明。它保留既有 length-prefixed AF_UNIX IPC 和
App 生命周期 owner，同时覆盖可组合 Track 查询、Source/Playlist、文件管理、Playback/Queue、
History、Metadata、Lyrics Job、Diagnostics、scope policy 和 MCP stdio。完整领域语义见
[Capability Reference](automation-capability-reference.md) 与 [Agent Behavior Guide](agent-behavior-guide.md)。

## 构建与运行

在仓库根目录执行：

~~~sh
cd Dependencies/PlayerAutomation
swift run player-automation cli system info --json
swift run player-automation cli library list --json
swift run player-automation cli library tracks --query "artist" --json
swift run player-automation cli library tracks --source <source-id> --json
swift run player-automation cli playlist list --json
swift run player-automation cli source refresh <source-id> --json
swift run player-automation cli automation capabilities --json
swift run player-automation cli automation call library.tracks \
  --params-json '{"filter":{"all":[{"hasLyrics":true}]},"limit":20}' --json
~~~

CLI 默认通过 LaunchServices 启动 kmgccc_player，并连接当前用户的：

~~~text
~/Library/Application Support/kmgccc.player/Automation/automation.sock
~~~

测试或不希望启动 App 时使用 --no-launch，也可以用
KMGCCC_AUTOMATION_SOCKET 或 --socket 指定测试 socket。--socket 必须是绝对
路径，且 socket 目录由 App 创建为 0700，socket 本身为 0600。
App 同时在同一目录维护 0600 的 `automation.secret`，CLI 通过一次性握手证明
连接的是本安装的 App；服务端还会验证 AF_UNIX peer 属于当前用户。secret 不代表
业务 actor 或 scope，后续权限仍由 App 自己解析。
CLI 可以用 `--library <uuid>` 为请求附加资料库 scope；App 只接受当前 active
session，因此 CLI/MCP 请求不会偷偷切换资料库。

## 当前能力

| CLI / MCP tool | wire method | 作用 |
| --- | --- | --- |
| system ping | system.ping | 检查 listener 是否可达 |
| system info | system.info | 返回协议版本、App 版本、能力和 active library ID |
| library list | library.list | 返回已注册资料库摘要和 active library ID |
| library tracks | library.tracks | 按组合 predicate、Source/Playlist membership、日期、技术字段和状态查询 Track |
| playlist list | playlist.list | 返回 Playlist、统计值和不透明 revision |
| source list | source.list | 返回原位来源、路径、绑定 Playlist 和扫描状态 |
| source refresh | source.refresh | 预览或刷新已授权来源，只导入尚未入库的文件 |
| playlist create | playlist.create | 预览或创建 Playlist |
| playlist add | playlist.addTracks | 预览或加入已有 Library Track，不重新导入文件 |
| playlist remove | playlist.removeTracks | 预览或移除 Playlist membership，不删除 Track 或文件 |
| files inspect | files.inspect | 检查当前/最后已知物理路径、可用性和 Source 归属 |
| files rename | files.rename | 在已授权 Referenced Source 内重命名文件；单文件可直接执行，批量需 App 确认 |
| files move | files.move | 在已授权 Referenced Source 内移动文件；支持 preview，批量移动需 App 确认 |
| files delete | files.delete | 预览并将真实文件移入 macOS 废纸篓；始终需要 scope 和 App 前台确认 |
| playback / queue | playback.* / queue.* | 控制本地播放和查询/插播/替换 Queue |
| metadata | metadata.get/patch | 读取或批量修改 App metadata，不写 embedded file tags |
| lyrics | lyrics.get/refresh | 查看歌词；批量刷新返回 Job，并只应用质量更高结果 |
| jobs / diagnostics | jobs.* / diagnostics.health | 查看进度、取消 Job 和收集 Source/Library evidence |
| policy | automation.capabilities/scopes/grantScope/revokeScope | 查看或经 App 确认管理统一 scope |

每次请求使用 length-prefixed JSON frame。--json 时 stdout 只输出一个版本化
response envelope；连接、启动和诊断信息走 stderr。未知协议版本、方法或参数会返回
稳定的结构化错误。

## Mutation safety

普通 Playlist/Source/Metadata/Playback mutation 在 scope 已授权后默认直接执行；使用
`--dry-run` 主动生成 preview。高风险 mutation 仍必须有 `confirm` acknowledgement，且
由 App 前台再次确认：

~~~sh
swift run player-automation cli playlist add <playlist-id> <track-id> --json
swift run player-automation cli playlist add <playlist-id> <track-id> --yes --json
swift run player-automation cli playlist remove <playlist-id> <track-id> --yes --json
~~~

普通 mutation 不需要伪造确认；高风险操作必须满足 App policy。查询得到的 Playlist revision 可以通过
--expected-revision 或对应 MCP 参数传回，revision 变化时返回 conflict，不会覆盖
新的 Playlist 状态。当前 Playlist mutation 只改变 Playlist membership：它不会导入、移动、重命名
或删除真实音频文件；source.refresh 是单独的、已授权后可直接执行的来源扫描操作，可能导入尚未
入库的文件，但仍不会移动、重命名或删除真实音频文件。

文件操作是单独的正式 capability，不是 Playlist mutation 的隐藏副作用。`files.rename` 和
`files.move` 只允许在 App 已授权的 Referenced Source 范围内工作；单文件操作可直接执行，
批量操作应先 `dryRun`，再以 `confirm=true` 请求 App 前台确认。`files.delete` 只接受真实
文件删除请求的 preview/apply，执行时会将文件移入 macOS 废纸篓，Track、Metadata、History
和 Playlist membership 保留，随后由 Source refresh 标记 Track 为 missing。`files.delete`
真实 apply 所需的 `files.delete` scope 默认拒绝；未获 App 授权时 apply 返回
`authorizationRequired`，不会触碰文件。只读 `dryRun` 仍可用普通 Library scope 查看影响。

当前设置窗口的“自动化与智能”板块控制本机 Automation endpoint、MCP 连接和 CLI/脚本
入口。关闭 endpoint 会停止本机 socket；只关闭 MCP 或 CLI 时，其他控制面仍可用。

## MCP stdio

以独立 executable 运行 MCP adapter：

~~~sh
swift run player-automation mcp-stdio
~~~

adapter 的 stdout 只输出 MCP JSON-RPC 消息，诊断走 stderr。它支持标准
initialize → notifications/initialized 生命周期，接受 2026-07-28 和 2025-11-25
版本协商，并提供 tools/list、tools/call、resources/list、resources/read 和 ping。
server/discover 仅作为历史兼容扩展。MCP tool schema、描述、只读标记、scope 和风险提示都来自
PlayerAutomationProtocol 的 AutomationToolCatalog，不会通过包装 CLI 文本来实现业务。

MCP stdio 启动后按需连接 App 的本用户 AF_UNIX endpoint；默认通过 LaunchServices
启动 App，再等待同目录的 secret。它不实现 Streamable HTTP、MCP Tasks 或远程授权；
内部长任务通过 `jobs.*` 暴露。

## AI boundary

AutomationToolCatalog 是 CLI、MCP 和未来内置 Agent 的共同能力目录。它只描述工具
和 JSON Schema；验证、权限、持久化、referenced-source membership 事务仍由 App
负责。当前仓库没有内置模型 runtime 或独立的 AI 数据层，因此本阶段不会把“能被
Agent 调用”冒充成“已经提供内置聊天/后台智能”。

## 边界

- CLI 和 MCP adapter 共用 PlayerAutomationProtocol 与 PlayerAutomationIPC，
  不解析 Track/Playlist sidecar。
- 每条连接先完成本安装 secret 握手，再读取一个请求；错误 secret 只返回结构化
  `authorizationRequired`，不会进入业务 handler。
- App 进程拥有当前 LibrarySession；本阶段不会因为查询非 active 资料库而切换 UI。
- mcp-stdio 已提供本地 stdio adapter；Streamable HTTP、远程授权和 MCP Tasks 映射仍留在
  后续阶段。
- 实际文件的 reveal/copy/export 还没有独立 capability；需要文件改名、移动或删除时使用
  `files.*`，不要直接改 Playlist 或 Storage JSON。
- 真实签名 App、冷启动、切库期间和 sandbox 分发仍需在对应构建产物上做人工 smoke
  test；SwiftPM 单元测试不代替这些验收。
