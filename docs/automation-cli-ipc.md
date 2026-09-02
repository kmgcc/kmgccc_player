# Automation CLI / 本地 IPC（Phase 1）

Phase 1 提供一个只读的本地探针，用来验证 CLI 到运行中 App 的进程边界。业务
写入、MCP tool 和任意文件系统操作都还没有开放。

## 构建与运行

在仓库根目录执行：

~~~sh
cd Dependencies/PlayerAutomation
swift run player-automation cli system info --json
swift run player-automation cli library list --json
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

## 当前只读方法

| CLI | wire method | 作用 |
| --- | --- | --- |
| system ping | system.ping | 检查 listener 是否可达 |
| system info | system.info | 返回协议版本、App 版本、能力和 active library ID |
| library list | library.list | 返回已注册资料库摘要和 active library ID |

每次请求使用 length-prefixed JSON frame。--json 时 stdout 只输出一个版本化
response envelope；连接、启动和诊断信息走 stderr。未知协议版本、方法或参数会返回
稳定的结构化错误。

## 边界

- CLI 和未来 MCP adapter 共用 PlayerAutomationProtocol 与 PlayerAutomationIPC，
  不解析 Track/Playlist sidecar。
- 每条连接先完成本安装 secret 握手，再读取一个请求；错误 secret 只返回结构化
  `authorizationRequired`，不会进入业务 handler。
- App 进程拥有当前 LibrarySession；本阶段不会因为查询非 active 资料库而切换 UI。
- mcp-stdio 目前明确返回 unsupported，直到 Phase 6 的 MCP compatibility layer
  完成后才会启用。
- 真实签名 App、冷启动、切库期间和 sandbox 分发仍需在对应构建产物上做人工 smoke
  test；SwiftPM 单元测试不代替这些验收。
