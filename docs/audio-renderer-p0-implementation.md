# Renderer P0 实施记录

日期：2026-10-08。状态：源码迁移已完成；尚未编译、执行 XCTest 或进行主 App 与设备实测。

本轮依据 [输出统一计划](audio-renderer-unification-plan.md) 实施 [DSP 计划](audio-dsp-implementation-plan.md) 的 P0。这里只统一播放输出与分析入口，DSP 效果从 P1 开始接入。

## 1. 播放与分析入口

本地播放现在只有 `AVAudioPlaybackService → RendererPlaybackPipeline → AVSampleBufferAudioRenderer / AVSampleBufferRenderSynchronizer` 一条输出路径。旧 engine、player node、mixer、delay node、后端选择、故障回退和 node-clock 调度已删除。`PlaybackScheduling.swift` 已删除；Services 使用 Xcode 文件夹同步组，没有需要保留的显式工程引用。

`AVAudioFile` 解码、canonical Float32 PCM、源采样率与声道数沿用现有实现。多声道 layout 根据声道数量推定的现存边界没有在本轮扩展。

`LEDMeterServiceProvider` 只接收配置；资料库 factory 不再索取 mixer 或创建备用 engine。Renderer 按播放时钟投递 PCM 给共享 `AudioAnalysisHub`，保留 FFT、消费者、可见性启停和暂停衰减。PCM 回调明确为 `@Sendable`，跨队列的分析工作不继承主线程 actor。

频谱响度分类直接使用 master gain 前的 PCM，移除旧 mixer 采样路径的音量除法。改变输出音量或静音不会把同一份源 PCM 误判为更响的信号。

`SpectrumRecorder` 改用 Renderer 管线和独立的录制分析实例，复用生产 FFT、频谱与 LED 算法。录制输出静音；完成、失败、超时和取消均经过停止屏障清理，采集不阻塞主线程，也不向主播放会话混入 PCM。

Apple Music、系统 Now Playing 的 provider、控制入口与模拟频谱路径保持原有 owner。

## 2. 恢复与异步状态

| 事件 | 源码行为 |
| --- | --- |
| Renderer 失败或持续时钟停滞 | 同一连续故障只允许一次重建；只有 renderer 正在 rendering 且时钟确实推进，才重新开放恢复预算 |
| 源读取、定位或 sample buffer 创建失败 | 停止当前请求，不触发正常 EOF 的队列推进 |
| 无法恢复 | 清理输出、分析、进度计时和 pending seek；保持当前曲目、时长与位置，用户 resume 可重新准备同一曲目 |
| 新 load、seek 或 stop | 立即使旧时间线代际失效；排队的旧进度、结束、失败与配置变化回调不能回写新请求 |
| 输出配置变化、暂停中换设备 | 保留有效时钟锚点、音量、设备 UID、原播放意图与应用 lead |
| 正常 EOF | 仍由服务原有完成和播放顺序 owner 收尾，与故障终止分开 |

时钟写入与 flush/enqueue 在同一管线队列执行。恢复选段使用逻辑区间 `presentationEnd − lead`，重新排队的 PTS 保留 `clock + lead`，避免在无缝边界附近选到已经结束的源段。

预取追加同时校验服务的调度 generation 和管线的 load segment ID。无缝提交只改变当前 segment，保留同一 load 身份；AAC priming/padding 的现有判断与裁剪继续使用。

## 3. 文件访问权限

`stop(completion:)` 和 `discardSegments(after:completion:)` 在串行管线完成解码/flush/移除 segment 后执行回调。服务先分离旧 lease，再在回调中释放，回调不修改新的播放会话。

无缝提交后仍为 outgoing 曲目保留原有 180 ms 窗口，随后通过 `retireSegments(through:completion:)` 移除旧 provider，再释放 lease。停止、切歌、预取取消和终止沿用同一队列顺序，避免文件权限先于读取任务失效。

## 4. 验证记录

本轮未执行编译、编译型测试或主 App 启动，遵守仓库 AGENTS.md 的构建授权边界。以下静态检查仅证明源码和连接关系，不能证明运行可用或可听连续。

- `git diff --check`：通过。
- App 自有 Swift 源码与 XCTest 的旧输出类型、mixer/tap 接口、后端分支、旧回退与旧调度类型残留检查：通过。
- 文件夹同步组和删除文件的工程引用检查：通过。
- 本轮新增或修改的本地文档链接检查：通过。索引原有 4 个资料库文档链接已失效，本轮保留，未扩展为资料库文档整理。

测试源码已补充或更新：

- `RendererPipelineTests`：恢复预算、输出 lead 下的 segment/frame/PTS 映射、时间线代际失效、源定位失败收尾及 stop 完成屏障。
- `SkinLifecycleCompletionTests`：无 mixer 的消费者生命周期、独立 hub 的 Renderer PCM 分析输入、master volume 不改变源频谱响度分类。

这些测试尚未执行。现有 sample buffer、跨采样率时间线、细粒度分析断言继续保留。

## 5. 维护者验收

先运行 `./scripts/check-app-process-state.sh` 核对主 App，再按 `./scripts/build_and_run.sh` 的现有流程构建与启动。构建入口的 `check-melismakit-dependency.sh --require-local` 前置仍须通过；确认实际编译输入来自本地歌词组件。

在 Xcode 执行 `RendererPipelineTests` 所在的 sample-buffer/timeline/recovery 测试类、`SkinLifecycleCompletionTests`、`PlaybackKeyboardSeekTests` 和 `DynamicAuthorizedSourceRootsTests`。随后按 [完整验收矩阵](audio-renderer-unification-plan.md#7-验收矩阵) 实测，重点覆盖：

- 内置、有线/USB、普通蓝牙与 AirPods；关闭、固定和头部跟踪空间化。
- 显式输出与默认输出切换、设备断开、睡眠唤醒；暂停状态保持。
- 零/180 ms lead、快速 seek/切歌、AAC 无缝专辑及下一首预取失败。
- 恢复途中 pause/stop/seek/切库，持续失败后的同曲目同位置重试。
- 普通窗口、MiniPlayer、全屏、歌词、Dock、频谱，以及外部来源往返切换。
- 开发录制的导出、取消与连续重复录制。

无缝音频、蓝牙时钟、空间音频和资源占用仍未获得设备验证。完成上述验收后，再固定实际构建版本与设备条件作为 P1 的 DSP A/B 基线。
