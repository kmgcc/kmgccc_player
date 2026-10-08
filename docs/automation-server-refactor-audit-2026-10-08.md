# Automation Server 架构审计与重构

## 范围与行为基线

审计对象是 App 内 Automation 执行层；PlayerAutomationProtocol 的 catalog/schema、CLI、MCP 和 AF_UNIX transport 均保持原状。基线工作树干净。原文件 12,962 行，execute 从 687 至 7,618 行。行数仅用于定位，拆分依据为调用链和状态 owner。

调用链：AppSessionHost 创建一个 AutomationIPCServer → listener 的 cancellableHandler → handle → execute → LibrarySession / AppSessionHost / LibraryViewModel / PlaybackCoordinator 等现有 owner。传输包验证 peer/secret、处理 framing/EOF；Server 不重建传输、认证、数据库或 Job 框架。

## 原职责与迁移目标

下表行号是重构前的位置。

| 原区域 | 职责与实际依赖 | 迁移目标 |
| --- | --- | --- |
| 10–387 | TaskLocal、App identity、scope/idempotency/selection persistence、storage backup models/retention | 请求编排、策略持久化、Selection store、Storage 各自文件 |
| 388–686 | listener、weak host、候选缓存、幂等等待者、start/stop/handle | Server 保留 listener/幂等；候选缓存进入各领域 |
| 687–824 | version、caller 开关、未知参数、动态 scope、background 包装 | Server 保留校验顺序 |
| 855–2165 | registry/lifecycle、import、query/report、bundle export、selection | Library Handler；生命周期仍走 Host，导入/bundle 仍走 Session |
| 2166–3735（交错） | Playlist mutation 与 Source 管理/配置交换 | Playlist / Source Handler；mutation 不绕过 ViewModel 事务 |
| 3736–4095 | 授权媒体解析、inspect/reveal/export/rename/move/delete | Files Handler；授权路径 helper 供 embedded/bundle 共用 |
| 4096–4346 | 播放命令与队列预览/修改 | Playback Handler；Coordinator/PlayerViewModel 仍是 owner |
| 4347–4540 | History 读取、统计、确认清空 | History Handler；复用 PlaybackHistoryStore |
| 4541–4972 | Artwork target、候选、revision、图片输入/应用 | Artwork Handler 独占有界候选缓存 |
| 4973–6028 | Metadata 文档、provider、entity patch、embedded tags | Metadata Handler；复用 provider、MP3 服务与 mutation owner |
| 6029–6438 | Lyrics 搜索/cache、质量、apply/clean/refresh | Lyrics Handler 独占候选缓存；写入仍走 Session |
| 6439–6731 | Job 观察/等待/取消/重试 | Jobs Handler；Coordinator 继续拥有工作及持久历史 |
| 6732–7508 | diagnostics、settings/audio、storage | Settings 与 Storage Handler；storage helper 跟随 Storage |
| 7509–7618 | capability/scope 授权与撤销、未知方法 | Server |
| 7620–12743 | 参数/响应、领域 helper、query、审计、background/batch、文件授权 | 随领域迁移；共享 helper 只承担窄职责 |
| 12745–末尾 | typed 参数解析、参数与文件错误 | 独立参数与错误定义 |

跨领域复用的真正边界：有序 Track ID 解析、曲目过滤/排序/Selection revision、Track/Playlist 投影及歌词状态、授权媒体路径、响应编码/错误映射、App 前台 picker/确认、Job summary。不让 Handler 调用另一 Handler。Playlist Selection 原本再次调用 execute，需保留 Server 校验再执行 Playlist 子操作。

## 必须保持的约束

- 幂等 replay/pending coalescing 在 execute 之前，指纹包括 Library/principal/caller/params；只缓存成功写操作/后台提交；重放改 requestID 保留原 serverTime。相同 key 不同指纹返回 invalidRequest。等待者共用响应，取消提交者不得误取消共享 Job。
- 所有正常请求、background/batch 子请求都经过相同 version/caller/schema/scope 校验。dry-run 的写 scope 豁免、history 条件 scope、导入/重试附加 scope 保持。
- activeSession 对 request.libraryID 校验；Job/候选/Selection 均有原有资料库归属。异步等待与搜索之后现有 identity/revision 校验继续保留。
- mutation 的 revision、preview、confirm=true 与 App 前台确认次序、阈值、原错误文案/结构保持。不给已有简单操作增加确认门槛。
- LibraryOperationCoordinator 拥有取消、quiesce 和持久 Job；批次仅允许原有 Metadata/Artwork/Lyrics 方法，逐项持久化结果，聚合确认通过 TaskLocal 传递。
- jobs.wait 取消只结束等待；已返回 Job 显式由 jobs.cancel 管理。刚提交且没有幂等等待者的 Job 保留原请求取消传播。
- 只传 Sendable 值跨后台边界，不传 Track、ViewModel、SwiftData 或 scope owner。目的目录 scope 成对开始/结束；来源授权由现有 Session 保持，切库必须等待在途复制完成。

## 实际问题与暂缓项

- 已确认 files.export 在 @MainActor execute 内执行同步 copyItem，最多 500 首；同步 existence/唯一文件名检查也位于同一循环。原分支未注册 Library operation，移出主线程会新增切库可重入窗口，必须同时纳入现有 operation owner。
- file rename/move 的 applyFilePlans 虽在 runLibraryOperation 内，闭包仍在 MainActor；不能认为 async 即后台 I/O。
- 主线程还有图片直读、ImageIO resize/base64、Selection/幂等/审计持久化、diagnostic sidecar 查验、query/report 遍历/序列化。Storage inventory/backup/diff 已有 nonisolated 后台值操作；embedded metadata 复用 extractor/MP3 service。逐项优化需要独立 snapshot/授权/取消设计，不能统一 Task.detached。
- execute 与 AutomationParameters 都检查未知参数；全局检查优先于 scope，领域 parser 还保护内部调用。本轮保留顺序和 parser 合同；不为微小性能收益改变错误优先级。
- Artwork 与 Metadata 的 entity target 解析形似但允许参数和错误不同；保持独立。响应编码/错误已集中，迁移不再复制它们。
- 幂等 replay 在授权重新检查之前，长期 cache 的授权撤回语义需要专门决策。本轮不改变既有行为。
- Lyrics cache 当前以 Track ID 索引，未像 Artwork candidate 显式保存 Library/revision；不同库相同 UUID 的语义与 TTL 属于后续兼容性议题。
- AppKit runModal 保留现有交互语义；其在途取消不等于面板取消。未把 legacy MCP 兼容删作死代码。
- 部分公开入口和私有 Phase 1 文档仍描述早期只读/MCP 能力，最新实现审计与源码才是本轮基线。文档修订限定本次边界。

## 分阶段实施与回滚

A：审计并建立当前协议测试、App 定向测试基线，提交本计划。

B：原样迁移参数、响应、前台交互、持久化与共享查询/路径辅助。只为跨文件使用调整到 module internal；领域私有方法继续 private。不增加 public API，使用 Xcode 已有 Services synchronized group。

C：逐领域迁移原 switch 分支及其私有 helper/cache；Server 用显式 method 分组分发。后台/batch 保留请求层协调，Playlist 子请求使用窄 execute 闭包，避免 Handler 互相依赖。核对每个原 case 与迁移 body，运行协议/定向 App 测试并提交。

D：单独修复文件复制/移动阻塞，以串行后台文件 worker 执行同步磁盘操作。请求/operation 等待实际 I/O 完成再释放 scope；取消为协作式、发生在文件边界，不承诺中断 copyItem。覆盖命名冲突、逐文件失败、取消、scope/operation 等待边界。

E：审查 diff、可见性、所有 method 路由、协议包零差异及真实 App 只读 CLI/MCP smoke（条件允许）。只删除迁移后有确证的重复/无效代码；记录剩余运行验收边界。

每阶段使用独立提交，性能提交可独立 revert，结构迁移可逆序 revert；不 reset、不 push、不合并。测试失败先定位阶段内变化，不扩大修改范围。

## 验收矩阵

| 路径 | 自动基线/计划 | 人工或真实 App 边界 |
| --- | --- | --- |
| 协议/传输/MCP | PlayerAutomation 全部测试，现代/legacy smoke；协议源零差异 | 第三方客户端 |
| 全局校验/隔离/幂等 | 临时 Library 的真实 AF_UNIX fixture：无权限、未知参数、旧 libraryID、重放/冲突 | 权限面板、系统 sandbox |
| 批次 | 现有 AutomationJobIntegrationTests：dry-run、revision、distinct targets、持久逐项结果 | 大量实体、真实 provider |
| Job | wait timeout/terminal/cancel；新增资料库切换等待边界 | 重启恢复、GUI 切库 |
| 文件操作 | worker 实际临时文件复制/移动/冲突/取消，主线程可继续执行 | Finder picker、授权拒绝、外部卷、大文件、切库 |
| Metadata/bundle/query | MP3EmbeddedTag、LibraryBundleExport、PreferenceQuery 定向测试 | NCM、外部媒体、真实图像/provider |
| App | 每阶段增量 Debug build/test，本地 MelismaKit 输入检查 | 构建通过不等于全部 GUI/自动化验收 |

## 执行记录

- A：PlayerAutomation 40 项基线通过；App 定向基线正在建立。
