# 技术文档

这里收录 kmgccc_player 可以公开复用的架构、算法和工程设计。文档面向贡献者与希望了解实现原理的开发者。

## 阅读顺序

| 文档 | 内容 |
| --- | --- |
| [实现约束与坑](PITFALLS.md) | 只收仍生效的实现约束与坑；**改对应功能代码前先读** |
| [架构概览](architecture.md) | 应用组合根、资料库 session、本地与外部播放、统一展示模型、歌词、主题和频谱的主链路 |
| [外部组件与构建依赖](dependencies.md) | AMLL、LDDC、QQ Music Helper、MediaRemoteAdapter、SACAD 与 Swift Package 依赖 |
| [原生 Swift 歌词系统](native-lyrics.md) | 原生 Swift 渲染架构、Core Text 字体排版、Core Animation 动效与硬件时钟同步 |
| [歌词渲染系统](lyric-rendering.md) | TTML 解析、多 surface 生命周期管理、时间偏移计算与多后端适配层 |
| [色彩系统](color-system.md) | 封面分析、OKLCH 语义色、Display P3 输出和局部可读性判断 |
| [现代本地音乐资料库体系](library-system.md) | 原位引用与托管双模式、多资料库隔离、标签与目录双轴浏览哲学 |
| [资料库存储实现](library-storage.md) | 目录规格、安全书签、权威 sidecar、缓存分级、播放历史与索引清理边界 |
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
