# Automation MCP Setup and Reference

当前提供本机 MCP stdio adapter：

```sh
cd Dependencies/PlayerAutomation
swift run player-automation mcp-stdio
```

它通过本用户 AF_UNIX socket 连接已经运行或由 LaunchServices 启动的
`kmgccc_player`，不 shell out 到 CLI，也不复制 Library business logic。stdio stdout 只
能出现 newline-delimited JSON-RPC message，诊断走 stderr。

## Protocol lifecycle

adapter 同时支持两个明确的协议时代，不把它们混成一个 lifecycle：

### Current stateless protocol: `2026-07-28`

当前客户端应先发送带 per-request metadata 的 discovery：

```text
client -> server/discover(params._meta.io.modelcontextprotocol/protocolVersion)
then  -> tools/list, tools/call, resources/list, resources/read, ping
```

此路径没有 `initialize`、`notifications/initialized` 或 session。stdio 没有 HTTP header，
所以版本信号放在每个请求的 `params._meta`：

```json
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "tools/list",
  "params": {
    "_meta": {
      "io.modelcontextprotocol/protocolVersion": "2026-07-28"
    }
  }
}
```

### Compatibility lifecycle: `2025-11-25`

仍兼容旧客户端的标准顺序：

```text
client -> initialize(protocolVersion, capabilities, clientInfo)
server -> initialize result(protocolVersion, capabilities, serverInfo)
client -> notifications/initialized
then  -> tools/list, tools/call, resources/list, resources/read, ping
```

`initialize` 只接受 `2025-11-25`；对 `2026-07-28` 发送 initialize 会返回结构化
invalid-params，提示改用 stateless discovery/per-request metadata。所有请求必须带
`jsonrpc: "2.0"`；notification 不返回 response。未初始化就走旧版标准操作会返回
structured JSON-RPC error。

官方协议参考：

- [Lifecycle](https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle)
- [2026-07-28 stateless MCP announcement](https://blog.modelcontextprotocol.io/posts/2026-07-28/)
- [Tools](https://modelcontextprotocol.io/specification/2025-11-25/server/tools)
- [Resources](https://modelcontextprotocol.io/specification/2025-11-25/server/resources)
- [Prompts](https://modelcontextprotocol.io/specification/2025-11-25/server/prompts)
- [Transports](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports)
- [Tasks](https://modelcontextprotocol.io/specification/2025-11-25/basic/utilities/tasks)

## Capabilities and Resources

server capabilities 声明 `tools` 和 `resources`。`tools/list` 的 schema、描述、风险、
scope、dry-run 和 job hints 来自 `AutomationToolCatalog`。MCP annotations 是给 Agent 的
提示，不是安全边界；App IPC policy 仍会重新检查 scope 和 confirmation。

当前 Resources：

- `kmgccc://capabilities`：共享能力和组合查询概览；
- `kmgccc://agent-guide`：Track/Playlist/Source、安全和 Storage fallback 语义；
- `kmgccc://jobs`：当前资料库的持久 Job 列表，可用 `resources/read` 读取，也可由现代 MCP
  客户端通过 `subscriptions/listen` 订阅变化。

`tools/call.params.arguments` 是对应的 domain 参数对象。需要指定 Library 或安全重试
mutation 时，可以在 `tools/call.params` 旁带本项目扩展的 `context` 对象，例如
`{"libraryID":"...","idempotencyKey":"..."}`；它不会污染每个 tool 的输入 schema。

资料库生命周期工具包括 `library.create`、`library.open`、`library.switch`、
`library.rename`、`library.relocate` 和 `library.remove`。其中 `library.manage` 默认开放，
所以 Agent 可以发起正常的创建、打开、切换、重命名和迁移流程；每个会改变 active Library
或磁盘位置的操作都要求 `dryRun`/`confirm=true`，随后由 App 前台弹窗和 `NSOpenPanel`
完成最终确认与路径授权。`library.remove` 额外需要 `library.delete` scope，默认不会授予；
它的 dry-run 可以在不授予删除 scope 时先查看影响。路径参数只用于定位 picker，不能绕过
security-scoped authorization。

Metadata 与 Artwork 也共用同一套 App-owned contract，并把 Track、Artist、Album、Playlist
作为一等目标。单目标模式的 `metadata.get/patch` 使用 `trackID`、`artistID`、`albumKey` 或
`playlistID` 四选一；兼容的 Track 批量写入仍使用 `trackIDs`。Track 暴露歌曲字段，Artist 暴露显示名、
介绍、标签、地区、外文名和 provider metadata，Album 暴露标题、年份/日期、类型、标签、
语言、厂牌和 provider metadata，Playlist 暴露名称和描述。canonical ID、统计量、创建/更新时间
是只读投影。

Agent 需要先发现 Artist、Album 或 Playlist 时，可调用 `metadata.get` 并传
`entityType: "artist" | "album" | "playlist"`，再用 `query`、`limit`、`offset` 分页；响应的
`nextOffset` 和集合 revision 用于继续读取与记录快照。`entityType` 不能与单目标 ID/key 混用。

`artwork.search` 同样接受 Track、Artist 或 Album 目标，复用 App 的多 provider 搜索并返回带
`imageBase64` 的候选；Playlist 没有 provider search，但四类目标都可用 `artwork.get` 读取摘要，
并用 `artwork.apply` 接受 App picker、`imagePath` 路径提示、`imageBase64` 或 `clear`。这些操作
`metadata.patch` 与 Artwork sidecar mutation 不改写原始音频标签。要读写文件内标签，请使用
`metadata.embedded.get/patch`；写入限 MP3 ID3v2.3/v2.4，需逐首 revision、dry-run、`confirm=true`
和 App 前台确认，并以 Job 报告逐首结果。其他格式只提供系统可读取的标签投影。
过大的搜索图片会被压缩为受本地 IPC frame 限制的 inline JPEG，候选仍会保留原始大小提示。
对 10 首及以上 Track，先调用 `dryRun` 观察 targets/conflicts，再传 `confirm=true`；
App 会在前台弹出确认框，MCP 的 acknowledgement 不能绕过它。应用后应重新 query 验证。

Lyrics 的短路径同样支持中间台加工：`lyrics.apply` 的 `candidate` 和 `ttmlText` 必须且只能
提供一个。候选输入继续走 provider fetch/质量门槛；`ttmlText` 输入必须是有效 TTML，随后由
App-owned lyrics repository 直接持久化，仍支持 `dryRun` 与 `expectedRevision`。

长操作的 catalog annotation 会额外标记 `x-kmgccc-supports-jobs: true`。目前
`source.create`（用户完成 App picker 授权后）、`source.refresh` 和 `lyrics.refresh`
返回包含 Job ID 的结构化结果；调用方应使用 `jobs.get` 轮询并在 Job 完成后重新查询
Source/Track 状态。这个项目扩展与 MCP Tasks 是两个不同层次的能力。

当前内部 Job abstraction 通过 `jobs.list/get/cancel/retry` 暴露。2026-07-28 MCP 客户端
可逐请求声明 Tasks capability，长 Job Tool 会返回映射到 App-owned Job 的 Task；未声明时
仍返回原 Job 结果。Job 历史按资料库持久化。歌词和 Source retry 使用原 Job 的稳定输入，
导入 retry 需调用方重新传入 `filePaths`，由 App 重新取得文件授权；retry spec 不保存外部路径或书签，
逐文件失败结果可能包含诊断路径。

现代 stdio `subscriptions/listen` 支持订阅 `kmgccc://jobs`，也支持为已创建的 Task 订阅 `taskIds`。
服务端先确认订阅，再以约 2 秒间隔读取已有 Jobs 接口；Job 快照变化时发送
`notifications/resources/updated`，Task 状态或进度变化时发送完整的 `notifications/tasks`。
客户端收到资源通知后重新读取资源。轮询不会为订阅自动启动 App。取消订阅会关闭对应的 listen 请求；
请求 Task 状态通知时，客户端必须在该请求中声明 Tasks 扩展。legacy 客户端继续轮询 `jobs.get`。
stdio 的 `notifications/cancelled` 会终止对应在途请求并关闭其 App IPC 连接；如果取消发生在新 Job
返回前，App 会尝试取消该 Job。已经返回的持久 Job 使用 MCP `tasks/cancel` 或 `jobs.cancel`。
长操作仍可先返回 Job/Task 句柄，再通过这些接口查询和取消。

`audio.get` 返回 Core Audio 可用输出设备的 opaque ID、当前系统默认输出及 App 实际路由；
`audio.patch.values.outputDeviceID` 可选择 App 输出设备，传 `null` 则跟随系统默认。若已选设备暂时不可用，
`activeOutput.available` 为 `false`，配置仍保留，设备恢复后可继续使用。该接口不会改变 macOS 系统默认输出。

当前 catalog 也包含 Source 排除规则、受限持久设置以及
`storage.inspect`/`storage.validate`/`storage.orphans`/`storage.backup`/`storage.diff`/
`storage.reload`/`storage.repair`。Storage backup 是 metadata-only，diff 只接受当前资料库
由 App 创建的 backup 路径，repair 只处理 App-owned scaffolding；这些都不是任意 JSON 写入通道。

## Transport boundary

当前只支持 local stdio + App AF_UNIX IPC。没有远程授权，也没有 loopback HTTP/Streamable
HTTP server。未来加入 HTTP 时必须明确 localhost binding、Origin/authentication、peer
identity 和 secret rotation，不能把本地 shared secret 当作远程授权。

## App unavailable

默认 adapter 会尝试启动 App，然后等待 socket/secret；`--no-launch` 用于测试和明确只连接
现有实例的场景。App 未完成 Library setup、正在切库或 endpoint 不可用时，MCP tool result
会保留结构化 `serverUnavailable`/`libraryNotActive` 错误，不应反复写入旧库。

## Import workflow

`library.import` 使用 App 的手动导入流程，支持 managed/referenced、文件／目录、NCM，
以及自动歌词、封面和元数据补全。可访问文件直接执行，权限不足时由 App 请求选择。

```json
{"name":"library.import","arguments":{"filePaths":["/path/to/song.ncm","/path/to/folder"],"targetPlaylistID":"<playlist-uuid>"}}
```

将上述参数放进当前 host 的 `tools/call` 请求；收到 Job 后通过 `jobs.get` 查询终态及
`result`。导入成功数量与补全缺失分别报告，不保证网络补全耗时。
