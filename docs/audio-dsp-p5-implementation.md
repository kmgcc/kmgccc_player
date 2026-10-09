# DSP P5 实施记录

实施日期：2026-10-08；编译验证：2026-10-09。P5 源码、静态检查与授权 Debug 编译已完成；尚未执行测试、启动主 App 或测量 CPU。

承接 [DSP 实施计划](audio-dsp-implementation-plan.md) 的 P5。可编程节点仍属于 P6。

## 1. 交付范围

| 节点 | 算法 | 默认值与旁路 | 声道范围 |
| --- | --- | --- | --- |
| `stereoWidth` | 前置左右声道 M/S，调整 Side 幅度 | width=1、outputTrimDB=0 时恒等 | `frontPair`；必须有唯一、明确的 Left/Right，单声道旁路 |
| `virtualBass` | 提取低频带，产生有界偶次/奇次谐波，湿路去 DC、滤波后叠加 | mix=0 或 amount=0 时完整旁路，包含节点输出增益 | `fullRange` 仅适用于已知 mono/stereo；多声道可明确选择 `frontPair` |
| `tube` | 带偏置、归一化的 tanh 软饱和与可选 DC blocker | mix=0 时完整旁路，包含节点输入/输出增益 | `fullRange` 排除已知 LFE；`allChannels` 明确包含全部声道 |

三个节点均支持添加、启停、排序、移除、参数编辑、完整预设保存与实时选择。沿用唯一 `AudioDSPController`、renderer runtime 和已有未来 PCM 替换事务。全局淡化、固定响度均衡、设备聆听参考继续独立于预设。

### 参数契约

| 节点 | 参数 | 范围 | 默认 |
| --- | --- | --- | --- |
| stereoWidth | width | 0…2 | 1 |
| stereoWidth | outputTrimDB | −24…6 dB | 0 |
| virtualBass | lowFrequencyHz / highFrequencyHz | 20…180 / 40…300 Hz，前者必须小于后者 | 40 / 120 |
| virtualBass | amount / harmonics / mix | 0…1 | 0.5 / 0.5 / 0 |
| virtualBass | driveDB / outputTrimDB | 0…18 / −24…6 dB | 6 / 0 |
| tube | driveDB / bias / mix | 0…18 dB / −0.5…0.5 / 0…1 | 6 / 0.15 / 0 |
| tube | inputTrimDB / outputTrimDB | −24…12 / −24…6 dB | 0 / 0 |
| tube | dcRemovalEnabled / dcBlockHz | Bool / 5…40 Hz | true / 10 |

算法版本均为 1。宽度使用 `standard`；两种非线性效果默认 `oversampling2x`，可选 `oversampling4x`。改变质量不会暗中降采样源音频，也没有隐藏的压缩器、AGC 或限幅器。启用节点的未知参数、质量或算法版本会返回可定位错误；禁用节点保留未知 JSON，便于预设往返。

## 2. 数值核与音质边界

### 立体声扩展

`M=(L+R)/2`，`S=(L−R)/2×width`，输出为 `M+S` 与 `M−S`。显式输出增益之前保持左右单声道合成和；宽度增加可能增加单边峰值，需要既有静态余量机制。未知布局不猜测声道位置，不自动 downmix。

### 虚拟低音

在源采样率下以 HP/LP 提取设定频带。插值后计算 `tanh(drive×bass)`，其平方与立方归一化后按 harmonics 混合；0 倾向偶次、1 倾向奇次。湿路使用 DC blocker、高通和低通，再重建到源采样率。湿路高通衰减原低频带，并不保证逐个基频完全消失。效果是在干声之外添加谐波，不是还原扬声器无法输出的实际低频。

### 电子管模拟

湿路使用 `(tanh(x×inputGain×drive+bias)−tanh(bias)) / (drive×(1−tanh(bias)²))`，保持零输入零输出，并归一化小信号斜率。偏置改变谐波关系；默认开启一阶 DC blocker。它是可控的非线性音色模型，尚未提供真实电子管电路的物理拟合证明。

### 抗混叠与干声

Swift 自有 polyphase Blackman-windowed sinc FIR，2× 为 129 taps，4× 为 257 taps。插值分相做 DC 归一化；重建在 phase 0 抽取。两级各有 32 个源帧群延迟，活跃非线性节点固定共 64 帧；这属于算法声明，尚待数值 fixture 验证。

只有选中的湿路运行 FIR；干声与未选声道使用精确 64 帧 FIFO 对齐，不被抗混叠滤波器改动。未选声道只分配短 FIFO 与最小空历史，不分配完整湿路 FIR 状态。

虚拟低音与管模拟主动改变音色。非线性链返回 `peakGuarantee=unavailable`，静态余量估计不等于真实峰值保证。2×/4× 是否达到目标混叠、THD/IMD、频响和噪声指标，需后续测量；不能据源码宣称所有极端参数下无劣化。

## 3. Renderer 时间线与资源

处理仍在 `CanonicalPCM → 自定义 DSP → CMSampleBuffer → AVSampleBufferAudioRenderer → Apple 系统输出` 上，Apple 空间化在自定义 DSP 之后。PCM 源采样率、声道布局、原 frame count 和 PTS 不变。

`AudioDSPProcessor.process(_:lookahead:)` 的 live 状态只推进当前输入的 N 帧；独立预分配 preview 状态复制 live 状态后计算 L 帧未来输入，将结果按 L 帧向前映射。输出仍是 N 帧，不追加尾帧或累计移动 PTS；短块 N<L 也使用这条映射。每个活跃非线性节点 L=64，最多 32 个节点，总读取上限 2048 源帧。既有音频延迟设置不叠加这部分算法延迟。

`RendererDSPLookahead` 读取时保留每段整曲固定响度增益：同格式、PTS 连续的下一段可以作为未来输入；EOF、时间间隔或格式边界才补零，解码错误向上传播。格式改变时重建 DSP 状态，并在实际播放时钟到达该块后发布该格式的路由、余量及延迟。

普通读取通过 `AVFilePCMProvider` 的小型未来 PCM 缓存完成，逻辑解码位置不被 peek 消耗；后续 nextChunk 先使用已解码前缀，避免逐块重复 AAC seek。替换预设时优先复用事务内已准备的原始 PCM；只有准备范围尾部继续读取源。旁路关闭可选缓存。FIR 系数只在准备节点时生成，Double 镜像环使用 Accelerate dot product，没有新增 DSP 定时器。

下一首晚于上首尾部排队才追加时，尝试通过现有事务重算仍安全处于未来的尾部。若可替换窗口已经过去，返回 `dsp.lateGaplessLookahead`，已排队尾部保留 EOF 边界；不能重写已播放音频。这种晚追加的真实听感与切换事务耗时仍需设备验收。

CPU 与内存目标尚未实测；4×、高采样率和长链成本更高，必须在 48/96/192 kHz、多声道和频繁编辑下确认，不以使用 Accelerate 代替性能证明。

## 4. MCP、CLI 与预设

`dsp.schema.nodes` 使用共享五节点 catalog：peq9、equalLoudness、stereoWidth、virtualBass、tube，包含完整参数 schema，以及 P5 默认值、质量、声道策略与活跃延迟。`dsp.patch` / `dsp.validate` 新增原子操作 `setQuality`、`setChannelPolicy`，配合已有 setParameter、setEnabled、addNode、setOrder 和完整配置替换。沿用 revision、dry-run、权限和既有 owner 验证，无新增第二套 DSP 状态。

`dsp.state.processing` 与 apply status/event 返回 `processingLatencyFrames`、`mediaMappingLatencyFrames` 和 `peakGuarantee`；未准备的值为 null。已补偿的 mediaMappingLatencyFrames=0 表示 App 的 PCM 时间映射，不是蓝牙或 DAC 到耳延迟测量。

预设完整保存节点 ID、版本、参数、质量、策略、启用与顺序；参数修改、重新排序和质量切换使用既有实时事务。自定义代码编译、运行和错误修复仍待 P6，当前 catalog 不宣称已有可编程执行能力。

## 5. 验收与当前证据

| 项目 | 本轮证据 | 待完成 |
| --- | --- | --- |
| 参数/UI/MCP/预设一致性 | 源码审查、App 与 wire 默认值对照测试源码、严格 UI 静态检查 | 运行测试、主 App 与 Agent 操作 |
| Width、湿声零旁路、声道/LFE | processor 测试源码 | 执行并核验样本 |
| FIR、短块、链延迟、顺序 | impulse、分块/整块、warm/reset 与混叠测试源码 | 数值 fixture、THD/IMD/DC/频响、听感 |
| 来源读取与时钟映射 | lookahead、跨段固定增益、EOF/格式间隔、失败与缓存测试源码 | AAC 真实文件、晚追加尾部、预设替换及格式切换 |
| 工程与样式 | `git diff --check`、`plutil -lint`、`check-ui-consistency.sh --strict-copy` | 已通过授权 Debug 编译；测试执行待完成 |
| 设备与性能 | 未实测 | 内置/USB/蓝牙时钟、空间模式、延迟设置、48/96/192 kHz CPU/内存 |

新增测试源码：`AudioDSPNativeEffectsConfigurationTests`、`AudioDSPNativeEffectsProcessorTests`、`RendererDSPLookaheadTests`，已加入现有 Xcode 测试目标。协议 catalog 的测试位于 PlayerAutomation 包。测试源码存在不代表已通过。

后续获得测试或主 App 实测授权后，针对上述测试执行筛选测试，再按计划 P7 做主 App/设备验收。Release 对照和长运行按维护者验收流程进行。

### 2026-10-09 授权编译结果

- `xcodebuild build-for-testing`：Debug arm64，App 与 Xcode 测试目标通过；未执行测试。日志：`build/logs/dsp-p5-xcode-build-final-20261009.log`。独立 DerivedData：`build/DerivedData-DSP-P5-20261009`。
- `swift build --package-path Dependencies/PlayerAutomation --scratch-path build/PlayerAutomation-DSP-P5-20261009 --build-tests`：CLI/MCP 与自动化测试源码通过；未执行测试。日志：`build/logs/dsp-p5-automation-build-20261009.log`。
- 本地 MelismaKit 静态依赖与完整构建日志检查通过，编译输入来自 `NativeLyrics/Sources/MelismaKit`，没有远程 checkout 编译输入。
- 修复 `DSPPolyphaseFIRPlan` 初始化闭包提前捕获 self：历史长度使用局部常量，FIR 参数不变。
- 修复非线性测试参考信号的类型推断超时：显式 Double 驱动增益及分步 tanh 运算。
- 工程其他位置仍有非阻塞编译警告。本次未启动 App，也未证明数值测试、真实听感或 CPU 指标通过。

## 6. 参考

- [JUCE Oversampling 官方文档](https://docs.juce.com/master/classjuce_1_1dsp_1_1Oversampling.html)：参考 FIR 线性相位、整帧延迟和干湿对齐的工程取舍，本实现未引入 JUCE。
- [DAFX AntiAliasing 作者仓库](https://github.com/julian-parker/DAFX-AntiAliasing)：参考非线性抗混叠的研究与测量方向；本轮选择原生 FIR 过采样，没有直接移植 ADAA。
- [JamesDSP vacuumTube 模块](https://github.com/james34602/JamesDSPManager/blob/master/Main/libjamesdsp/jni/jamesdsp/jdsp/Effects/vacuumTube.c)：确认现成效果的模块组织；本轮使用自有 Swift 数值核，没有复制该模块源码或引入其运行时。

数学方法与源码复用分别管理。本轮未新增第三方 DSP 源码依赖。
