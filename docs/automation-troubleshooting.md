# Automation Troubleshooting

## App 或 endpoint 不可用

1. 运行 `player-automation system ping --json`。
2. 检查 `~/Library/Application Support/kmgccc.player/Automation/automation.sock` 和同目录
   `automation.secret` 是否由当前 App 创建。
3. 不要复制 secret 到别的用户或远程主机；AF_UNIX peer 和 shared secret 都属于本机边界。
4. 需要现有实例时使用 `--no-launch`；否则让 CLI/MCP 启动同一个 App bundle。
5. `libraryNotActive` 表示请求的 `--library` 不是当前 active session，接口不会偷偷切库。

## Source permission / watcher

- `source.list` 查看 Source path、status、lastScan 和 playlist bindings。
- 未授权 Source 必须通过 `source.create` 触发 App-owned picker；原始 path 不能直接伪造授权。
- 用户拒绝时应得到 `authorizationRequired`/permission denial，且不应出现半成品 Source。
- NAS/移动盘不在线时，默认保留 Source 和 Track，检查 `offline`、`permissionDenied`、
  `stale` 状态后再执行 `source.refresh`。
- 文件消失默认是 missing + preserve；不要把 missing 误判成需要删除 Track。

## MCP handshake

确认客户端先发送 `initialize`，读取服务器协商的 protocol version 和 capabilities，再发送
`notifications/initialized`。如果工具调用在此之前发生，修复客户端生命周期，不要把
`server/discover` 当成标准握手。stdio stdout 只能是 JSON-RPC；将调试日志写入 stdout 会
破坏 MCP framing。

## Scope / confirmation

`automation.scopes` 查看 granted/denied scopes。scope 缺失时，App 返回 required/denied
scope；`automation.grantScope` 会把请求带到前台并要求用户确认。`--yes`/`confirm=true`
不绕过 App alert。高风险操作取消时应得到 `interactionRequired`，且没有副作用。

## Jobs

`lyrics.refresh` 或其他 App-owned 长任务返回 Job ID 时：

```text
jobs.get -> 读取 state/currentPhase/completedCount/totalCount/failures
jobs.cancel -> 请求取消
重新查询 -> 验证已持久化的 domain data
```

当前 Job observation 是 launch-scoped；App 重启后先查询 domain data 和 `source.list`，不要
假设旧 Job ID 仍存在。当前 Source refresh/create 仍可能是同步 bounded operation，不要把
它们当成已经具备跨重启 durable Job 的能力。

## Build / helper

App Debug build 依赖 bootstrap 产物。若失败指向 `MediaRemoteAdapter`：

```sh
./scripts/bootstrap.sh --check --component mediaremote
./scripts/bootstrap.sh --component mediaremote
```

不要为了让 build 变绿修改 MediaRemote 业务代码。根据受影响组件再执行完整 bootstrap；
外部 helper 的 stdout contract 仍必须保持 JSON，诊断走 stderr。

## Storage fallback

Storage 主要包含 manifest、Track/Playlist/Source sidecar、settings、index 和 history store。
直接处理前必须：使用当前 commit 的源码确认 schema/owner，复制到 temporary fixture 或先
做可恢复 backup，最小化修改，运行 validate，按 owner reload/rescan/restart，再通过正式
Automation query 验证。不要修改 secret、writer lock、pending transaction 或 migration
journal 来绕过错误；不确定时报告 evidence，而不是猜测。
