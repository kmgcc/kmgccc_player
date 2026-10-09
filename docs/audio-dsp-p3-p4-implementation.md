# DSP P3–P4 实施记录

日期：2026-10-08。范围依据 [DSP 实施计划](audio-dsp-implementation-plan.md) 的 P3、P4。源码实现、交叉审查、静态检查及经用户授权的 Debug 编译已完成；尚未运行测试或进行设备验收。

## 范围与验收矩阵

| 范围 | 实现职责 | 验收要求 |
| --- | --- | --- |
| 全局设置 | App 级 `AudioProcessingGlobalsController`，独立保存 fade、loudness、deviceReferences | 切换或保存 DSP 预设不改变全局设置；切库重新绑定同一 owner |
| 播放淡化 | renderer 队列的 `PlaybackOutputGainController` | dB 域 smoothstep，精确端点；反向操作从当前包络继续；只在过渡中运行 5 ms timer |
| 实际 transport | 淡出期间继续推进媒体时钟，终点暂停；状态公开 desired/actual/phase/envelope | UI 与自动化不提前发布已暂停；主音量变化不覆盖包络；seek/stop/设备变化取消旧过渡 |
| 固定响度 | 每个 renderer segment 锁定增益，处理位于预设节点前 | 曲内样本比例恒定；gapless、回读、恢复与 seek 保留增益；测量结果不改变正在播放的 segment |
| 完整测量 | 离线 K weighting、400 ms 块／100 ms 步进、绝对与相对 gate、全声道峰值 | 不平均 LUFS；LFE 不计响度但参与峰值；静音、短文件和未知布局返回明确状态 |
| 专辑 | 聚合线性能量与最坏峰值，连续专辑意图锁定同一决定 | 完整记录缺失时统一 unity；不在专辑接缝加入隐藏包络 |
| 缓存与扫描 | 资料库派生缓存、既有定位与 lease、单并发 utility 工作、既有 Job owner | 文件身份与版本校验，取消／重试／进度／切库关闭；不自动扫描全库 |
| 等响 | 可排序的 `equalLoudness` v1 节点，两个 shelf 与静态余量合成 | 参考以上恒等、降低音量时单调有界、静音安全；只读取 App 主音量和设备参考 |
| 设备参考 | 按实际 CoreAudio UID 保存，默认输出解析为实际设备 | 不使用虚构 SPL；硬件音量未校准时明确 `appOnly`；与预设分离 |
| 自动化 | `audio.get/patch`、`audio.loudness.get/analyze`、DSP schema 与资源订阅 | scopes、完整参数、共享 revision、原子验证与 dryRun；等待沿用真实 Job 状态 |

## 关键语义

- 淡化默认关闭，播放 100 ms、暂停 120 ms，曲线 `perceptualDB`，默认底值 -80 dB。预设切换的 30 ms 内部过渡与全局 transport 淡化由不同控制量驱动。
- 响度均衡默认关闭。打开后默认 auto，目标 -18 LUFS，最大 boost 12 dB、衰减 24 dB、峰值上限 -1 dBTP。缺测使用 unity；峰值约束优先于目标响度和衰减限制，没有压缩器、逐段 AGC 或隐藏 limiter。
- 开始播放时锁定响度决定；配置修改与后台测量为后续播放准备，seek 不重新选择增益。强制 track 模式的接缝可能出现固定增益差，完整 album 记录及明确连续专辑意图使用同一增益。
- 等响默认参数为低架 70 Hz／最多 +6 dB，高架 3.5 kHz／最多 +3 dB，窗口 20 dB。计算量由主音量与设备参考决定，排除 transport fade、静态余量与歌曲归一化增益。
- 无设备参考时显示满 App 音量为参考的相对补偿；不表示耳机或扬声器的物理校准。主音量立即更新 renderer，补偿频响通过 35 ms 合并后进入既有未来音频替换流程，不改预设 revision 或 modified。

## 自动化

`audio.patch.values` 增加 `fade`、`loudness`、`deviceReferences`。fade/loudness 支持局部字段合并，设备参考为完整映射，以 `audio.get` 的稳定设备 ID 为键。所有字段先共同验证，再写入 owner；预览不写设置或申请声音切换。

`audio.get` 返回上述全局值、`processingRuntime`、当前 `normalization` 与输出状态。`dsp.schema` 声明 EQ 和等响节点参数；`dsp.state.equalLoudness` 将当前参考下的预期补偿增益和应用阶段分别返回，预期值不冒充已可听值。

`audio.loudness.get` 按需读取缓存快照，不启动扫描；播放使用前另校验源文件。默认按资料库分页读取（offset/limit，每页最多 200）；显式 trackIDs 每次最多 200，includeEnergyHistogram 可取统计详情。`audio.loudness.analyze` 根据显式 trackIDs 创建资料库 Job，进度、取消、失败项重试与终态使用现有 `jobs` API。扫描不修改当前播放增益。

CLI 增加 `audio loudness get|analyze --params-json <object>`。MCP 增加可读可订阅的 `kmgccc://audio/state`，沿用现有订阅 worker，仅在已订阅时读取状态。

## 测量与缓存边界

测量核采用有界的 0.1 LU 能量直方图，专辑聚合计数并在线性能量域重新 gating。直方图每块的代表能量量化范围不等于最终 gated integrated loudness 的误差保证，阈值附近的结果需标准 fixture 对照。真实峰值由独立的多相插值估计，尚未证明标准容差。

内存快照最多保留 256 个 record，其余记录按需读取；关闭响度均衡的默认启动不预读这些测量。文件身份、size/mtime、算法/解码/metadata parser 版本及 AAC trim 设置快照共同控制复用。播放与扫描共用 `AACDecodedFrameRange`，按实际解码长度判断是否已消费 priming/padding，统一初次播放与 gapless 的有效帧区间。seek 和可视化延迟重载沿用该 segment 的范围；扫描记录真实起止帧，裁剪规则版本更新使旧记录失效。异常提前 EOF 不作为完整歌曲测量。AAC 标准 fixture 和设备行为仍未验证。

标签缺乏可判定的 LUFS 参考或 Opus 解码增益基线时，不用于归一化增益；sample peak 不冒充 true peak。派生缓存不回写音频标签。

## 收尾审查与静态检查

- 修正首个音频 PTS 之前就结束淡入的问题；`waitingForAudio` 保持静音包络，随后才开始播放淡化。输出增益每 5 ms 更新，状态最多 20 Hz，完成后停 timer。
- 统一当前／预读／seek 的 AAC 帧范围和离线测量范围；新增防重复裁剪、完整解码及等待首个音频的测试源码。
- 修正按 Job 的目标归属、取消隔离、引用文件 lease 覆盖 stat、旧 cache 覆盖新测量，以及外部源和旧 timeline 回调发布问题。
- `git diff --check`、新增文件空白检查、`check-ui-consistency.sh --strict-copy` 和工程 plist 检查通过。
- 18 个 DSP／响度方法均有正式 IPC 分发；新增测试引用路径均存在。App 源码使用现有目录同步分组，测试只加入测试文件，不重复编译实现。

## 授权编译与修复

2026-10-08 用户明确授权编译并修复编译问题。本轮修复：

- renderer 的 `nonisolated` 类型不接受 `lazy` 增益控制器；改为在初始化时创建队列与控制器，随后安装回调。
- 等响节点复用的 `dspIconButtonStyle` 原为文件私有；调整为模块内共享，保持同一套按钮样式。
- 频响绘制的 `GraphicsContext` 遮蔽了等响参考；区分绘图参数和聆听上下文。
- 当前 macOS SDK 没有 `accessibilityLiveRegion`；改用 AppKit announcement 通知保留辅助功能播报。
- 响度测试中的 `XCTUnwrap` 会抛错；测试方法补充 `throws`。
- 清理 DSP 未使用变量与未使用返回值，metadata 字符串／数值改用异步 `load`。

| 编译范围 | 结果 | 日志（仓库本地 `build/logs/`） |
| --- | --- | --- |
| 主 App，arm64 Debug，关闭签名，独立目录完整构建 | 通过 | `dsp-p3p4-clean-build-20261008.log` |
| Xcode 测试目标，`build-for-testing` | 通过，未执行测试 | `dsp-p3p4-tests-build-final-20261008.log` |
| CLI／MCP，`swift build` | 通过 | `dsp-p3p4-automation-build-20261008.log` |
| 自动化测试源码，`swift build --build-tests` | 通过，未执行测试 | `dsp-p3p4-automation-tests-build-20261008.log` |

最终完整构建使用 `scripts/build_app.sh Debug`，本地 MelismaKit 源码与构建日志门禁均通过，日志包含 `NativeLyrics/Sources/MelismaKit` 编译输入，没有远程 `melismakit` checkout 输入；App 产物存在性检查通过。增量重试和测试编译使用另一独立目录，保留各次日志。构建没有启动 App。

## 验证边界

本轮已独立编译 P3–P4，不使用 P1–P2 的历史构建结果代替。未执行测试或启动主 App；标准 fixture、可听淡化、CPU、实际缓存使用、Apple 空间化与蓝牙设备兼容性仍需维护者验收。构建仍有 DSP 范围外的并发／捕获警告；通过编译不代表这些路径已通过运行验收。

## 维护者检查

1. 运行新增 transport、globals、等响、响度及自动化用例。
2. 对照 BS.1770／EBU 标准信号与可信实现确认 K weighting、gate、短输入、布局和 true peak 的误差，不能以测试源码存在作为合规证明。
3. 使用长曲目确认固定增益和内存边界；检查缓存恢复、文件变化、换音源、扫描取消与切库。
4. 连续专辑、混合队列、shuffle、显式 track 模式、缺记录专辑及 AAC 裁剪，检查增益选择、接缝和测量范围。
5. 快速播放／暂停反向、调主音量、seek、stop、源失败及输出切换，检查实际暂停时机、pop、包络和旧回调失效。
6. 等响设备参考保存与恢复、默认设备变化、静音、淡化期间频响、多个等响/EQ 节点和自动余量；量测 CPU 与可听更新时间。
7. MCP/CLI 参数全覆盖、原子拒绝、dryRun、revision 冲突、资源订阅及扫描 Job 失败／取消／重试。
