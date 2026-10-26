# 技术文档

这里收录经过筛选的 kmgccc_player 使用指南、稳定架构、算法与工程规范，帮助用户使用产品，也帮助贡献者理解和参与项目。每篇文档都应有明确、长期的阅读用途。

更新时优先补充已有专题；只有现有文档无法承载、且确有独立公开用途时才新增，并同步本索引。实施计划、调研报告、排障记录、阶段状态和 Agent 工作记录不在本目录收录；功能完成或结论稳定不构成收录理由。

## 快速导航

### 1. 核心架构与工程门禁

| 文档 | 核心关注点 |
| --- | --- |
| [实现约束与坑（PITFALLS）](PITFALLS.md) | **修改代码前必读**。收录所有现行生效的架构铁律、组件踩坑与调试陷阱 |
| [架构概览](architecture.md) | 应用启动组合根、单向数据流、统一展示模型（`NowPlayingPresentation`）、双模式资料库 Session 与外部服务接入 |
| [外部组件与构建依赖](dependencies.md) | 外部独立运行组件（AMLL 背景、LDDC、QQ Music Helper、MediaRemoteAdapter、SACAD）与 Swift Package 依赖管理 |

### 2. 歌词与视听系统

| 文档 | 核心关注点 |
| --- | --- |
| [原生 Swift 歌词系统](native-lyrics.md) | 原生 Swift（`MelismaKit`）渲染哲学、Core Text 字体排版与注音（Ruby）、Core Animation 动效与硬件音频时钟同步 |
| [歌词渲染系统](lyric-rendering.md) | TTML 结构解析、多 Surface 统一调度生命周期、视觉提前量与 Seek 不变量、临近切行算法 |
| [色彩系统](color-system.md) | 封面统计分析模型、OKLCH 感知色彩空间、Display P3 映射、局部区域稳健分位数对比度评分与 Plus 混合文字 |
| [虚拟低音算法笔记与文献参考](virtual-bass-algorithm-notes.md) | 缺失基频（Missing Fundamental）心理声学原理、差频互调失真（IMD）消除、后级 4 阶高通滤波与工业级设计法则 |

### 3. 音频管线与 DSP

| 文档 | 核心关注点 |
| --- | --- |
| [DSP 脚本语言 v1](audio-dsp-script-language.md) | 内置固定内存 VM 语言规范、参数/状态原语（biquad、delay、smooth）、延迟补偿声明与测试 Fixture |
| [DSP 处理负载](audio-dsp-processing-load.md) | 节点与整链处理耗时测量口径、四级语义色视觉表达、开销控制与测试验收路径 |

### 4. 界面规范与皮肤系统

| 文档 | 核心关注点 |
| --- | --- |
| [产品文案与界面规范](product-ui-guidelines.md) | 极简书面语风格、自然长句、禁用装饰点号、胶囊按钮、设置行规范与视觉层级 |
| [弹窗标准](popup-standards.md) | `PopupKit` 共享视觉标准、长内容边缘淡出与悬浮动作区、交互式玻璃点击命中顺序与单一退出入口规则 |
| [原生皮肤开发](skin-authoring-native.md) | 开发中的原生场景 v2、数据绑定、效果、包管理与样例 |
| [皮肤包 JSON Schema v2](skin-package-v2.schema.json) | 皮肤清单与场景节点的编辑器补全及结构定义 |
| [皮肤包示例](examples/skins/) | 唱片、浮光、字里行间与流彩四个完整打包示例 |

### 5. 现代本地资料库与检索

| 文档 | 核心关注点 |
| --- | --- |
| [现代本地音乐资料库体系](library-system.md) | 原位引用与自包含托管双模式、多资料库物理隔离、标签与目录双轴并行浏览的设计哲学 |
| [资料库存储实现](library-storage.md) | 磁盘文件分层结构、安全作用域书签（Security-Scoped Bookmark）、Sidecar 权威数据、派生缓存分级与删除策略 |
| [曲库搜索](search.md) | SQLite FTS5 全文检索、字符 n-gram 模糊召回、TTML 纯文本提取、多阶段字段加权精排 |
| [偏好随机播放](smart-shuffle.md) | 行为信号建模（喜欢、跳过、完播）、长期行为基础权重、时间阻尼衰减、冷门探索与偶发再曝光 |

### 6. 自动化与 Agent 协议

| 文档 | 核心关注点 |
| --- | --- |
| [Automation CLI / 本地 IPC / MCP](automation-cli-ipc.md) | Length-prefixed AF_UNIX IPC、安全握手协议、CLI 命令集、Scope 权限模型与 Mutation 确认边界 |
| [Automation Capability Reference](automation-capability-reference.md) | 自动化领域完整能力清单（曲库、元数据、封面、歌词、播放队列、文件操作、后台 Job） |
| [Agent Behavior Guide](agent-behavior-guide.md) | 面向外部 AI Agent 的稳定行为约束、数据校验流程、进程独占检查与实测安全红线 |
| [Automation CLI Reference](automation-cli-reference.md) | 命令行详细参数、选项、JSON 输入输出格式与批处理示例 |
| [Automation MCP Setup / Reference](automation-mcp.md) | 现代与兼容 MCP stdio 传输协议、Dynamic Resources、Tasks 扩展与客户端对接指南 |
| [Automation Troubleshooting](automation-troubleshooting.md) | 常见错误码、握手失败、权限拒绝、挂载卷离线与网络超时排查指南 |
| [kmgccc-player-automation Skill](skills/kmgccc-player-automation/SKILL.md) | 供 AI 辅助工具直接加载的 Agent 行为 Skill 规范 |

### 7. 稳定性与遥测

| 文档 | 核心关注点 |
| --- | --- |
| [崩溃报告与分析](crash-reporting.md) | PLCrashReporter 进程崩溃捕获、两阶段客户端脱敏、Breadcrumb 追踪、GitHub Release dSYM 匹配与本地符号化 SOP |

---

## 全局核心约束与难点导览

在参与 kmgccc_player 开发或修改代码时，请特别注意以下贯穿全工程的关键不变量：

### 1. 单向数据流与状态所有权
- **单一发布点**：UI、MiniPlayer、Dock、全屏与歌词**严禁**各自监听底层播放服务或独立猜测当前状态。所有播放快照统一收敛至 `PlaybackCoordinator`，并通过 `NowPlayingPresentation` 向外发布。
- **命令流向**：所有播放控制指令（播放、暂停、跳转、下一首、切换模式）必须统一调用 `PlaybackCoordinator`，由协调器决定本地引擎与外部来源的流转。

### 2. 原生歌词与时钟同步
- **纯原生渲染**：生产环境歌词完全由 Swift 原生组件（`MelismaKit`）渲染，基于 Core Text 矢量排版与 Core Animation 图层管线驱动，完美适配 ProMotion 120Hz；AMLL 仅用于背景网格渐变（`amll-background.js`），不得在歌词层引入 DOM 或 WebView fallback。
- **时间不变量**：视觉提前量（`timeOffsetMs`）仅用于补偿听者的视觉感知延迟，**绝对不得**污染点击歌词跳转时的真实音频寻道位置（`seekTimeOffsetMs`）。

### 3. 本地资料库与代际防线
- **原位引用原则**：原位模式（Referenced Mode）是播放器对用户既有文件秩序的尊重。**绝不擅自移动、改名或修改原音频文件**，所有元数据和修改均存放在资料库内的 Sidecar 文件中。
- **Generation Fencing**：所有异步扫描、索引重建和缓存任务必须捕获当前资料库 Session 的不可变 `LibraryContext` 和代际标识（Generation）；切换资料库时，旧代际的未决写入必须被丢弃，严禁跨库污染。

### 4. OKLCH 语义色彩与稳健对比度
- **严禁直接取色**：视图层不得直接使用原始像素 RGB 或以 `Color(hue:saturation:brightness:)` 临时微调；所有颜色必须经由 `ThemeStore` 分发自 `SemanticPalette` 的语义角色。
- **低分位数对比度**：计算文字在封面或渐变背景上的可读性时，采样点集必须使用**低分位数稳健评分**，而不是平均值，确保局部文字不会因局部高亮而完全失真。

### 5. 虚拟低音与互调失真（IMD）抑制
- **物理根因**：复音频经过非线性谐波生成时，必产生差频互调失真（如 50Hz 与 65Hz 产生 15Hz 次声波），在小型扬声器上会引起低频“噗噗噗”马达声。
- **设计黄金准则**：谐波生成后必须串联 4 阶 Butterworth 高通滤波器；谐波阶数严格限制在 2 次与 3 次，严禁使用高次多项式；采用带平滑 Attack/Release 的动态限幅，严禁单采样硬截断。

### 6. Liquid Glass 交互与弹窗标准
- **点击命中顺序**：交互式材质（`.interactive()`）必须包裹在已声明形状的内容上，严格遵循「`label` $\to$ `contentShape` $\to$ `glassEffect`」声明顺序；否则胶囊按钮周围区域会出现“有高亮但无法触发点击”的失效现象。
- **单一退出入口**：弹窗底部若已有“取消”或“关闭”按钮，右上角必须隐藏关闭叉图标，避免视觉杂乱，同时保持 Esc 快捷键与取消回调完全有效。

---

## 术语约定

- **资料库**：由 `library.json` 标识的一套自包含数据，可固定为托管或原位模式。
- **托管模式（Managed）**：音频副本位于资料库的 `Tracks/` 目录内，播放不依赖导入源。
- **原位模式（Referenced）**：音频留在外部来源，资料库通过安全作用域书签保存引用，元数据保存在 Sidecar JSON 中。
- **LibrarySession**：当前资料库的一组可完整加载、停用和关闭的运行时 owner 集合。
- **播放来源**：本地播放（Local）、Apple Music 或系统 Now Playing。
- **展示模型**：由 `NowPlayingPresentation` 统一发布的只读播放快照。
- **Surface**：一个独立歌词承载面，例如窗口歌词、全屏歌词或悬浮歌词（对应代码中的 `LyricsSurfaceRole`）。
- **语义色**：按用途命名的感知颜色角色（如全局强调色、封面前景色、歌词高亮色），由 `SemanticPalette` 统一生成。
- **派生缓存**：可以从资料库数据安全重建的临时缓存，不包括播放历史、喜欢状态和手动覆盖配置。
