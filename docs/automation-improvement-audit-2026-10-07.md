# MCP 实测问题与优化验收（2026-10-07）

本轮先对照实测问题与当前源码，再修改共享 Automation 链路。App 是资料库与业务的唯一 owner，CLI/MCP 复用同一能力；不增加独立 headless 资料库服务，也不直接修改 SQLite 或手工生成 sidecar。

## 报告与当前实现的差异

| 问题 | 当前源码结论 | 本轮目标 |
| --- | --- | --- |
| 搜索和校验超时 | 默认 IPC timeout 为 10 秒且可配置；网络搜索仍在请求内等待 | 耗时调用可完成、取消、查询，错误区分超时与不可达 |
| GUI 退出后 MCP 中断 | 适配器已有自动启动；广泛 `pkill -f` 可能同时终止适配器 | 正常退出或重启后适配器存活并可恢复连接 |
| 批量能力不足 | metadata.patch、artwork.apply、lyrics.refresh 已支持批量；metadata.import 支持逐首不同字段 | 复用已有 handler，补齐不同歌曲的不同操作，逐项返回结果 |
| 元数据丢失 | 来源刷新主要更新 locator/availability；新库音频扫描不自动携带旧库人工数据 | 明确迁移步骤与身份映射，避免补全与恢复人工数据竞争 |
| 诊断不可行动 | 已有计数、来源、Job、歌单引用及校验原因；缺少统一歌曲级清单 | 有界返回 trackID、路径、原因及下一步 |
| Job 等待消耗 | 已有现代订阅，兼容客户端仍轮询；缺少 jobs.wait | 增加有界等待并保留 Job/Task 现有语义 |

额外发现：默认 MCP 幂等键仅由 JSON-RPC request ID 生成。不同适配器会话复用 ID 时会与持久缓存冲突；自动键必须带会话身份，显式调用方幂等键保持原有重试语义。

## 验收矩阵

| 路径 | 验收要求 | 状态 |
| --- | --- | --- |
| 传输、幂等 | 超过默认期限的合法操作；取消；两个会话复用 ID；明确错误分类 | SwiftPM 40 项通过，含总期限与 EOF |
| 生命周期 | 正常退出主 App 后 adapter 存活；精确主 App 重启后新调用恢复 | 主 App 正常退出后同一 adapter 存活；重启 Debug App 后原 adapter 重连通过 |
| 批量操作 | 逐项不同内容；权限、revision、dryRun；部分失败可定位与重试 | 主 App 不同元数据/歌词/封面批次通过；定向预检/dry-run/冲突测试通过 |
| Job 等待 | 终态、等待到期、未知 Job、取消；等待不再次执行原操作 | 隔离 IPC 集成测试通过；主 App 终态与后台校验 Job 通过 |
| 诊断 | 临时资料库缺失文件和不完整条目返回歌曲级证据；分页有界 | 主 App 缺失媒体与不完整元数据清单通过；媒体恢复后校验通过 |
| 导入与迁移 | 文件到 Track 映射；保留人工数据；明确在线补全策略 | 主 App 两首迁移映射/重复导入/自定义数据保留通过；迁移和 Source 保留测试通过 |
| 协议与构建 | SwiftPM 测试、现代/兼容 MCP smoke、增量 App Debug build、本地 MelismaKit | 40 项 SwiftPM、9 项 XCTest、现代/兼容 smoke、最终 Debug build 与签名检查均通过；本地编译输入已确认 |

## 执行 checkpoint

- 分工：传输/MCP 适配器、App 操作/协议、导入服务三块并行；审查和最终验收集中进行。
- 起始工作树干净；主 App 未运行；MelismaKit 指向本地 NativeLyrics。
- 自动化服务、导入和诊断的测试使用临时数据；真实用户资料库的内容不作为写入验收样本。
- 实现和验证结果完成后更新本表，分别记录源码、构建、运行与未覆盖边界。

### 实现审查 checkpoint

- 导入层已加入 `enrichmentPolicy: standard | migration` 和 `fileTrackMappings: [{filePath, trackID}]`；migration 及其重试跳过在线补全。原始路径沿 NCM 转换、去重、引用合并及持久化结果传递。
- 传输层加入会话级默认幂等键、连接与业务期限，以及已送达状态不明确的错误分类。已指出并修正陈旧 socket 的重启条件和 jobs.wait 默认预算；适配器测试使用真实子进程与独立 AF_UNIX fixture。
- App Job 接口复用 `LibrarySession.operationCoordinator`；批量限定元数据、封面和歌词写入，不包含资料库切换、文件删除或嵌套批次。网络检索与诊断增加可选 background Job。
- 批次审查要求：聚合确认按实际实体计数，每项结果及时持久化，Track/Artist/Album/Playlist 冲突均可识别；Job 句柄返回前的取消维持原有行为。
- health/storage 的一致性问题与媒体路径不可用问题分开分页；存在性检查不代表音频解码验收。
- 旧 Debug bundle 未通过代码签名验证，未启动主 App；最终运行必须以重新构建的主 App 为准。
- 随后的验证结果见下方验收 checkpoint；最终构建和生命周期实测均已完成。

### 验收 checkpoint（2026-10-08）

- App 定向 XCTest 实际执行 9 项，全部通过、无跳过；覆盖 Job 等待/取消、批次预检/dry-run/revision 冲突、迁移路径展开与复用、导入 planner/committer 和 Source relocation 保留元数据。结果包：`build/automation-acceptance-20261007/targeted-import-batch-tests-2.xcresult`。结果包另记录一条主线程调用 runtime warning，尚未做性能归因；不将本轮测试视为性能验收。
- SwiftPM 实际执行 40 项，全部通过。新增 finite stdin EOF drain、stdout 关闭、会话键、前台交互预算、分帧读取总期限；测试子进程使用同一 scratch build 的明确 executable。日志：`build/automation-acceptance-20261007/transport-final-tests-2.log`。
- 使用重新构建的主 App，通过其 bundle 内 adapter 与正式 MCP 方法完成临时 managed Library 验收：迁移导入两首音频、目录展开到 Track 映射、逐首不同 Metadata/TTML/Artwork 批次、重复导入身份复用与内容保留、后台 storage Job、媒体缺失与 storage 一致性分离，以及恢复媒体后的再次校验。错误请求的失败也保存在逐项 Job/诊断中。
- 临时 Library 已由 App 生命周期 owner 移到 macOS 废纸篓并注销，原 active Library 与默认删除权限状态已恢复；未直接改写用户 sidecar、SQLite 或 registry。验收记录保留在 `build/automation-acceptance-20261007/live/`。
- UI 一致性与 strict-copy 检查通过，检查 2 个受影响 UI 文件。
- 真实 NCM 内容转换、完整跨库 bundle 搬迁和第三方客户端交互尚未复测；迁移 mapping/策略的自动测试及本地 WAV 流程不能替代这些路径。媒体诊断只验证存在性/可读性，不验证解码质量。

- 最终 Debug build 成功，日志确认实际编译输入来自本地 MelismaKit，并通过 deep/strict bundle 签名验证。使用标准 `build_and_run.sh` 运行入口，最终只存在一个精确 Debug 主进程。日志：`app-debug-build-final.log`、`run-entry-final.log`。
- 主 App 内置 adapter 的现代 discovery/tools/resources/tools-call 和兼容 initialize/ping smoke 全通过，包含一次性关闭 stdin 的真实调用。日志：`mcp-smoke-final.log`。
- 对主 App 执行正常 Quit，等待主进程退出后，同一个 adapter 仍存活并报告 `serverUnavailable` / `delivery:notSent`；经标准运行入口重启相同 Debug bundle 后，原 adapter 恢复 `system.info`，未重新创建 adapter。首次在退出进行中发请求得到了 `requestOutcomeUnknown`，符合该阶段无法保证未送达的语义；验收随后增加了进程退出完成的等待。日志：`live/lifecycle-assertions.json`、`run-lifecycle-restart.log`。此流程用 `--no-launch` 隔离了实际二进制，不将它视为系统默认安装版本自动启动路径的实测。
- 最终主二进制 SHA-256：`53e6f4ad83fe5e45badeea63af38fe5269857af64447d2bd40b1dfbce713010e`；内置 adapter SHA-256：`b51f2363f9f5e7695789ed0857aee2a02fdf59d8a0cbd1373baa1095a89ee159`。
- 未替换系统安装版、未发布、未提交；验收使用工作区最终 Debug bundle。子代理遇到额度限制后，余下小范围审查修补及验收由主代理完成。
