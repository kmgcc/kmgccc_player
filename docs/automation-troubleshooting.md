# Automation Troubleshooting

## App 或 endpoint 不可用

1. 运行 `player-automation system ping --json`。
2. 检查 `~/Library/Application Support/kmgccc.player/Automation/automation.sock` 和同目录
   `automation.secret` 是否由当前 App 创建。
3. 不要复制 secret 到别的用户或远程主机；AF_UNIX peer 和 shared secret 都属于本机边界。
4. 需要现有实例时使用 `--no-launch`；否则让 CLI/MCP 启动同一个 App bundle。
5. `libraryNotActive` 表示请求的 `--library` 不是当前 active session，接口不会偷偷切库。

设置窗口中的“自动化与智能”板块可以分别关闭本机 endpoint、MCP 入口或 CLI/脚本入口。
如果 endpoint 关闭，先在该板块重新开启；如果只关闭了 MCP 或 CLI，对应 caller 会得到
结构化 `authorizationRequired`，另一个控制面不受影响。

## Source permission / watcher

- `source.list` 查看 Source path、status、lastScan 和 playlist bindings。
- 未授权 Source 必须通过 `source.create` 触发 App-owned picker；原始 path 不能直接伪造授权。
- 用户拒绝或取消时应得到 `interactionRequired`/permission denial，且不应出现半成品 Source
  或 import Job。
- NAS/移动盘不在线时，默认保留 Source 和 Track，检查 `offline`、`permissionDenied`、
  `stale` 状态后再执行 `source.refresh`。
- 文件消失默认是 missing + preserve；不要把 missing 误判成需要删除 Track。
- `files.inspect` 可确认最后已知路径和 Source 归属；改名/移动后等待 `sourceScan` Job
  完成，再用 `library.tracks` 检查 `availability` 和 `sourceMemberships`。
- `files.delete` 的真实 apply 默认 scope 被拒绝是预期安全行为；用户必须在 App 前台授予
  scope，之后仍要通过 App confirmation。`dryRun` 不修改文件，可以先查看影响摘要。不要把
  `confirm=true` 当作绕过授权的开关。

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
jobs.get -> 读取 state/currentPhase/completedCount/totalCount/failures/failedItemIDs
jobs.retry -> 对 retryable 的失败或部分失败 Job 重试（歌词优先只重试失败项）
jobs.cancel -> 请求协作式取消
重新查询 -> 验证已持久化的 domain data
```

Job 历史按资料库写入 `Settings/automation-jobs.json`，最多保留有界数量。App 重启时未完成
的 Job 会以 recovery failure 变成 `failed`；安全可重建的 Lyrics/Source Job 可以通过
`jobs.retry` 新建 Job。取消是协作式的，不会撤销已经提交的 domain data；不要把旧 Job 的
取消误解为事务回滚。

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
Automation query 验证。优先使用：

```text
storage.orphans -> 找到可定位的 Playlist/Track 引用问题
storage.backup -> 创建 metadata-only backup 并取得 manifest
storage.diff <backup-path> -> 比较受控修改前后文件
storage.reload -> 重新载入当前 App-owned storage
storage.validate -> 验证完整 invariant
```

`storage.backup` 不复制真实音频、缓存、索引或 live SQLite；它不是整库文件备份。不要修改
secret、writer lock、pending transaction 或 migration journal 来绕过错误；不确定时报告
evidence，而不是猜测。
