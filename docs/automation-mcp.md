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
- `kmgccc://agent-guide`：Track/Playlist/Source、安全和 Storage fallback 语义。

`tools/call.params.arguments` 是对应的 domain 参数对象。需要指定 Library 或安全重试
mutation 时，可以在 `tools/call.params` 旁带本项目扩展的 `context` 对象，例如
`{"libraryID":"...","idempotencyKey":"..."}`；它不会污染每个 tool 的输入 schema。

长操作的 catalog annotation 会额外标记 `x-kmgccc-supports-jobs: true`。目前
`source.create`（用户完成 App picker 授权后）、`source.refresh` 和 `lyrics.refresh`
返回包含 Job ID 的结构化结果；调用方应使用 `jobs.get` 轮询并在 Job 完成后重新查询
Source/Track 状态。这个项目扩展与 MCP Tasks 是两个不同层次的能力。

当前内部 Job abstraction 通过 `jobs.list/get/cancel/retry` 暴露；它还没有被错误地冒充成
MCP Tasks capability。Job 历史按资料库持久化，重启恢复和可重建的 Lyrics/Source retry
仍由 App-owned Job contract 管理。等 Swift MCP SDK/协议映射和 MCP Tasks 语义稳定后再增加
Tasks 映射。

当前 stdio reader 是顺序同步 reader，不会把 legacy `notifications/cancelled` 虚报成已
完成的底层取消。长任务应使用返回的 Job 与 `jobs.cancel`；MCP Tasks、transport-close
取消传播和更细的 request cancellation 是明确的后续工作。

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
