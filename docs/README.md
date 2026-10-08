# 技术文档

这里收录 kmgccc_player 可以公开复用的架构、算法和工程设计。文档面向贡献者与希望了解实现原理的开发者。

## 阅读顺序

| 文档 | 内容 |
| --- | --- |
| [实现约束与坑](PITFALLS.md) | 只收仍生效的实现约束与坑；**改对应功能代码前先读** |
| [架构概览](architecture.md) | 应用组合根、资料库 session、本地与外部播放、统一展示模型、歌词、主题和频谱的主链路 |
| [本地音频输出统一计划](audio-renderer-unification-plan.md) | 单一 sample-buffer renderer、旧 engine 移除、设备恢复、无缝播放与分析迁移 |
| [Renderer 音频 DSP 实施计划](audio-dsp-implementation-plan.md) | 自定义效果链、等响补偿、完整预设实时切换、全局淡化/固定响度均衡、音质性能与 MCP/AI 控制 |
| [App 维护备忘](app-maintenance-backlog.md) | App 本体的职责拆分、播放发布与开发工具整理，以及核心测试和实际 UI 验收范围 |
| [皮肤体系演进计划](skin-system-evolution-plan.md) | 皮肤解耦、组件与自由排版、ZIP 导入与重载、Web 效果、开发工具及 Folium 兼容阶段 |
| [皮肤基础重构记录](skin-system-p0-p2.md) | P0–P2 的行为基线、登记契约、宿主拆分、生命周期及实际验证边界 |
| [皮肤组件与自由场景实施记录](skin-system-p3.md) | P3 的组件边界、场景接入、产品决定与实际进度 |
| [皮肤 P0–P4 审查](skin-system-review.md) | 计划覆盖、修正、组件扩展边界、维护债务与实际验证 |
| [原生皮肤开发](skin-authoring-native.md) | JSON ZIP 示例、可选组件、自适应布局、少量参数与 Swift 原生扩展入口 |
| [MotionKit 动画标准化与迁移计划](motion-kit-plan.md) | 原生弹簧 API、语义 motion token、动画分类、歌词边界与分阶段迁移门禁 |
| [外部组件与构建依赖](dependencies.md) | AMLL、LDDC、QQ Music Helper、MediaRemoteAdapter、SACAD 与 Swift Package 依赖 |
| [原生 Swift 歌词系统](native-lyrics.md) | 原生 Swift 渲染架构、Core Text 字体排版、Core Animation 动效与硬件时钟同步 |
| [歌词渲染系统](lyric-rendering.md) | TTML 解析、多 surface 生命周期管理、时间偏移计算与多后端适配层 |
| [色彩系统](color-system.md) | 封面分析、OKLCH 语义色、Display P3 输出和局部可读性判断 |
| [产品文案与界面规范](product-ui-guidelines.md) | 用户文案、设置页、按钮、弹窗和跨页面视觉一致性 |
| [现代本地音乐资料库体系](library-system.md) | 原位引用与托管双模式、多资料库隔离、标签与目录双轴浏览哲学 |
| [资料库存储实现](library-storage.md) | 目录规格、安全书签、权威 sidecar、缓存分级、播放历史与索引清理边界 |
| [资料库存储](library-storage.md) | 托管/原位模式、registry、目录、source、缓存、索引、播放历史和删除边界 |
| [资料库写入 authority matrix](library-write-authority.md) | Phase 0 的函数级持久化 owner、提交顺序、失败补偿与生命周期合同 |
| [Automation CLI / 本地 IPC / MCP](automation-cli-ipc.md) | 共享 Automation contract、CLI、AF_UNIX IPC、MCP stdio、文件管理和安全边界 |
| [AI Agent Automation 实施计划](ai-agent-automation-plan.md) | 面向外部 Agent 的持续实施计划、阶段状态、Source/文件验收和安全边界 |
| [Automation 计划实现审计（2026-10-03）](automation-plan-audit-2026-10-03.md) | 逐领域实现差距、导入闭环、Source 配置交换、Metadata 快照读取与实际验收边界 |
| [MCP 实测优化验收（2026-10-07）](automation-improvement-audit-2026-10-07.md) | 报告核对、请求可靠性、批量操作、任务等待、诊断和迁移验收 |
| [Automation Server 架构审计与重构（2026-10-08）](automation-server-refactor-audit-2026-10-08.md) | Handler 职责、请求约束、阶段验证、后台文件操作与剩余技术债务 |
| [Automation Capability Reference](automation-capability-reference.md) | 当前可用的领域能力（含 Metadata/Artwork 控制）、组合查询、文件操作、风险、scope、revision 和 Jobs |
| [Agent Behavior Guide](agent-behavior-guide.md) | Agent 的领域语义、安全规则、推荐 workflow 和 Storage fallback |
| [Automation CLI Reference](automation-cli-reference.md) | 人、脚本和 Agent 可用的命令、JSON、exit code 和 batch 约定 |
| [Automation MCP Setup / Reference](automation-mcp.md) | MCP lifecycle、Resources、stdio transport 和 App boundary |
| [`scripts/automation_mcp_smoke.sh`](../scripts/automation_mcp_smoke.sh) | 对运行中 App 执行现代/兼容 MCP handshake、Tools、Resources 和 tool call smoke |
| [Automation Troubleshooting](automation-troubleshooting.md) | App、权限、MCP handshake、watcher、Jobs、bootstrap 和 Storage 排障 |
| [kmgccc-player-automation Skill](skills/kmgccc-player-automation/SKILL.md) | 可加载/适配的 Agent 行为 Skill |
| [本地音乐资料库重构计划](music-library-rearchitecture-plan.md) | 原位资料库重点重构、托管兼容、文件夹与播放列表关系、领域模型迁移、分阶段实施和验收 |
| [阶段 0-1 入口审计](archive/music-library-stage0-1-entry-audit.md) | 时点快照（已归档）：阶段 0-1 已冻结入口、生命周期 owner、服务链路和验收基线 |
| [阶段 8 验收记录](archive/music-library-stage8-acceptance.md) | 时点快照（已归档）：诊断投影、重复审查、原位排除目录、搜索扩展、批量写回状态和验收边界 |
| [曲库搜索](search.md) | FTS5、字符 n-gram、TTML 纯文本提取、候选召回与排序 |
| [偏好随机播放](smart-shuffle.md) | 行为信号、负向衰减、探索与再曝光的权重模型 |
| [崩溃报告与分析](crash-reporting.md) | 捕获与上报架构、隐私边界、Breadcrumb/会话关联、GitHub Release dSYM、符号化和受控验证 |

## 文档分区

- 权威文档：上表所列，随代码演进维护。
- [PITFALLS.md](PITFALLS.md)：只收仍生效的坑，改代码前先读。

## 术语约定

- **资料库**：由 `library.json` 标识的一套自包含数据，可固定为托管或原位模式。
- **托管模式**：音频副本位于资料库内，播放不依赖导入源。
- **原位模式**：音频留在外部来源，资料库保存 locator、bookmark、App 元数据和派生数据。
- **LibrarySession**：当前资料库的一组可完整加载、停用和关闭的运行时 owner。
- **播放来源**：本地播放、Apple Music 或系统 Now Playing。
- **展示模型**：由 `NowPlayingPresentation` 统一发布的只读播放快照。
- **surface**：一个独立歌词承载面，例如窗口歌词或全屏歌词；保留英文是为了与代码中的 `LyricsSurfaceRole` 对齐。
- **语义色**：按用途命名的颜色角色，例如强调色、封面前景色和歌词活动色。
- **派生缓存**：可以从资料库数据重新生成的缓存，不包括播放历史、喜欢状态和手动覆盖。
