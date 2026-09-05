# 技术文档

这里收录 kmgccc_player 可以公开复用的架构、算法和工程设计。文档面向贡献者与希望了解实现原理的开发者。

## 阅读顺序

| 文档 | 内容 |
| --- | --- |
| [实现约束与坑](PITFALLS.md) | 只收仍生效的实现约束与坑；**改对应功能代码前先读** |
| [架构概览](architecture.md) | 应用组合根、资料库 session、本地与外部播放、统一展示模型、歌词、主题和频谱的主链路 |
| [外部组件与构建依赖](dependencies.md) | AMLL、LDDC、QQ Music Helper、MediaRemoteAdapter、SACAD 与 Swift Package 依赖 |
| [歌词渲染系统](lyric-rendering.md) | TTML 解析、WebView 生命周期、多 surface 管理、时间偏移和提前切行算法 |
| [色彩系统](color-system.md) | 封面分析、OKLCH 语义色、Display P3 输出和局部可读性判断 |
| [资料库存储](library-storage.md) | 托管/原位模式、registry、目录、source、缓存、索引、播放历史和删除边界 |
| [资料库写入 authority matrix](library-write-authority.md) | Phase 0 的函数级持久化 owner、提交顺序、失败补偿与生命周期合同 |
| [Automation CLI / 本地 IPC](automation-cli-ipc.md) | Phase 1 的版本化只读协议、AF_UNIX framing、CLI 探针和边界 |
| [本地音乐资料库重构计划](music-library-rearchitecture-plan.md) | 原位资料库重点重构、托管兼容、文件夹与播放列表关系、领域模型迁移、分阶段实施和验收 |
| [阶段 0-1 入口审计](archive/music-library-stage0-1-entry-audit.md) | 时点快照（已归档）：阶段 0-1 已冻结入口、生命周期 owner、服务链路和验收基线 |
| [阶段 8 验收记录](archive/music-library-stage8-acceptance.md) | 时点快照（已归档）：诊断投影、重复审查、原位排除目录、搜索扩展、批量写回状态和验收边界 |
| [曲库搜索](search.md) | FTS5、字符 n-gram、TTML 纯文本提取、候选召回与排序 |
| [偏好随机播放](smart-shuffle.md) | 行为信号、负向衰减、探索与再曝光的权重模型 |
| [崩溃报告与分析](crash-reporting.md) | 捕获与上报架构、隐私边界、Breadcrumb/会话关联、GitHub Release dSYM、符号化和受控验证 |
| [代码重构计划](code-refactor-plan.md) | 上帝文件拆分、print 清理与测试保险网的分阶段路线图（含进度表） |

## 文档分区

- 权威文档：上表所列，随代码演进维护。
- [PITFALLS.md](PITFALLS.md)：只收仍生效的坑，改代码前先读。
- [archive/](archive/README.md)：不再维护的时点快照，结论已蒸馏进权威文档或 PITFALLS。

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
