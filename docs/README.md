# 技术文档

这里收录 kmgccc_player 可以公开复用的架构、算法和工程设计。文档面向贡献者与希望了解实现原理的开发者。

## 阅读顺序

| 文档 | 内容 |
| --- | --- |
| [架构概览](architecture.md) | 应用组合根、本地与外部播放、统一展示模型、歌词、主题和频谱的主链路 |
| [外部组件与构建依赖](dependencies.md) | AMLL、LDDC、QQ Music Helper、MediaRemoteAdapter、SACAD 与 Swift Package 依赖 |
| [歌词渲染系统](lyric-rendering.md) | TTML 解析、WebView 生命周期、多 surface 管理、时间偏移和提前切行算法 |
| [色彩系统](color-system.md) | 封面分析、OKLCH 语义色、Display P3 输出和局部可读性判断 |
| [资料库存储](library-storage.md) | 用户数据、缓存、索引、播放历史和清理操作之间的边界 |
| [曲库搜索](search.md) | FTS5、字符 n-gram、TTML 纯文本提取、候选召回与排序 |
| [偏好随机播放](smart-shuffle.md) | 行为信号、负向衰减、探索与再曝光的权重模型 |
| [崩溃报告与分析](crash-reporting.md) | 捕获与上报架构、隐私边界、Breadcrumb/会话关联、GitHub Release dSYM、符号化和受控验证 |

## 术语约定

- **资料库**：用户管理的本地音乐及其 sidecar 数据。
- **播放来源**：本地播放、Apple Music 或系统 Now Playing。
- **展示模型**：由 `NowPlayingPresentation` 统一发布的只读播放快照。
- **surface**：一个独立歌词承载面，例如窗口歌词或全屏歌词；保留英文是为了与代码中的 `LyricsSurfaceRole` 对齐。
- **语义色**：按用途命名的颜色角色，例如强调色、封面前景色和歌词活动色。
- **派生缓存**：可以从资料库数据重新生成的缓存，不包括播放历史、喜欢状态和手动覆盖。
