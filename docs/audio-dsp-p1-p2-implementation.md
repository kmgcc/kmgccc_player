# DSP P1–P2 实施记录

日期：2026-10-08。状态：源码实现与交叉审查完成；主 App、自动化工具及测试目标编译通过，静态检查通过。测试尚未运行，设备验收尚未进行。

本轮按 [DSP 实施计划](audio-dsp-implementation-plan.md) 的 P1、P2 推进，使用两个实现任务，由主任务负责组合根、自动化协议和交叉审查。P0 的单一 renderer 源码基线继续保留；不增加输出后端。

## 范围与验收矩阵

| 范围 | 本轮实现 | 验收关注点 |
| --- | --- | --- |
| 音频核 | 9 段 EQ、六类滤波器、Double 系数/历史、输入输出 trim、静态余量 | 恒等旁路、响应一致、数值稳定、无隐式压缩/重采样 |
| 格式 | 携带源布局，区分 full-range/LFE/未知声道 | 不按声道数猜 5.1，不删声道，不虚构布局支持 |
| 连续播放 | runtime 归 renderer，同格式 gapless 连续，seek/恢复 reset 明确 | frame/PTS/lease 与曲目提交不改变 |
| 实时更新 | 小输出块、有界原始 PCM 历史、未来 flush、预热、互补余弦过渡 | 排队音频和待分析 PCM 同步替换；旧请求失效；部分 flush 失败有限处理 |
| 预设 | 完整文档、工作草稿、选择/保存/另存/复制/重命名/删除/导入导出 | 原子持久化、disabled 参数与顺序保留、内置平直不可覆盖、切库保持 |
| 设置 | DSP 开关、预设、效果顺序、九列 EQ 和同算法响应曲线 | 主题/共享组件、窄窗口滚动、键盘/辅助功能、修改和应用状态 |
| AI 控制 | schema/state/validate/patch/wait、预设操作、资源读取和状态订阅 | audio scopes、revision、原子更新、UI 全参数、真实状态；不新增确认流程 |

全局淡入淡出和固定响度均衡属于 P3，等响补偿属于 P4，其他效果和代码运行属于 P5–P6。本轮 schema 只声明可运行的 EQ 节点；通用预设参数保留未知节点和参数。当前文档 schema 的未知算法可保留为未兼容预设，导入不应用声音，选择未知 enabled 算法必须返回不兼容诊断。

## 共同接口

配置与预设采用 Foundation Codable/Sendable 值类型，不引用 UI、SwiftData 或自动化 transport。完整声音配置包括总开关、输入/输出 trim、余量策略和有序节点；节点保存稳定 UUID、type ID、算法版本、enabled、声道策略、质量及 JSON 参数。

模型约定为 `AudioDSPConfiguration`、`DSPNodeConfiguration`、`DSPParametricEQBand`、`DSPHeadroomConfiguration`、`DSPPresetDocument`、`DSPJSONValue`、`DSPDiagnostic`、`DSPAudioFormat`、`DSPApplyStatus` 和 `DSPApplyEvent`。所有跨队列类型明确 `nonisolated` / `Sendable`。

运行时入口为：

```swift
RendererPlaybackPipeline.applyDSP(
    _ configuration: AudioDSPConfiguration,
    revision: String,
    requestID: UUID
)
RendererPlaybackPipeline.onDSPApplyEvent: (@Sendable (DSPApplyEvent) -> Void)?
```

`AudioDSPController` 为唯一 MainActor 配置 owner，管理完整配置、revision、预设列表、当前预设 UUID、modified、准备/排队/可听状态。控制器提供完整配置验证和原子 apply，以及预设 CRUD；通过注入的 apply closure 交给当前播放服务，通过 `receive(_:)` 接受运行状态。无播放时配置为 ready；外部来源为 inactiveExternalSource。

AppSessionHost 创建并持有控制器。发布资料库 session 时绑定现有播放服务，沿用来源变化回调；UI 从 AppSessionHost 取得相同实例。自动化 handler 委派该 owner，不直接读写预设文件或处理 PCM。

## 实时切换约束

1. 保留 8192-frame 解码读取，输出拆为 2048-frame 块并保留不足一块的尾段。缓存记录原始源 frame、segment、PTS、格式与处理版本，按字节数有界裁剪。
2. 切换点选择未来完整 buffer 边界；新 runtime 从该边界之前的 raw history 预热，旧分支使用对应时间的已处理 PCM，不能拿 horizon 的历史直接处理当前位置。
3. 同时最多一个部分 flush，completion 回串行队列核对播放与 DSP 代际。旧队列在失败时保持，最多改用更远边界重试一次；受控重缓冲必须报告实际中断。
4. 从切换点重处理到原 decode horizon，替换同区间 analysis，保持 provider cursor、decodeIndex 和下一 PTS 一致。跨 segment 不重复发 exhaustion 或逻辑曲目提交。
5. 30 ms 互补 raised-cosine 过渡；audible revision 只随设备媒体时钟达到切换点更新。停止、seek、设备恢复与切库使旧替换事务失效。
6. 默认关闭处理且没有活动节点时保持原 PCM 真实旁路；缓存不保存整首歌。CPU、内存与切换 p95 需要实测，代码存在不能代替结果。

## 本轮验证边界

初次交付仅执行静态检查。2026-10-08 维护者明确要求编译后，补充 Debug 主 App、自动化工具及测试目标的编译，未运行 XCTest、主 App 或设备测试。尚未确认的音质、蓝牙时钟、空间模式和可听切换性能不标为通过。

| 已执行检查 | 结果 |
| --- | --- |
| `git diff --check` 与新增文件空白检查 | 通过 |
| `./scripts/check-ui-consistency.sh --strict-copy` | 通过，检查 4 个 UI 文件 |
| `plutil -lint kmgccc_player.xcodeproj/project.pbxproj` | 通过 |
| DSP 自动化方法与分发的静态对应检查 | 16 个方法均有 handler 和 IPC 分发 |
| DSP 工程文件引用检查 | 引用路径均存在 |

上表为静态检查。另完成以下编译与产物检查：

| 编译或产物检查 | 结果与记录 |
| --- | --- |
| 主 App Debug／arm64，`CODE_SIGNING_ALLOWED=NO` | `BUILD SUCCEEDED`；`build/logs/dsp-compile-retry-20261008.log` |
| 主 App `build-for-testing` | `TEST BUILD SUCCEEDED`；`build/logs/dsp-test-compile-final-20261008.log` |
| `PlayerAutomation` 的 `player-automation` product | 通过；`build/logs/dsp-automation-compile-20261008.log` |
| `PlayerAutomation` 的 `swift build --build-tests` | 通过；`build/logs/dsp-automation-tests-compile-20261008.log` |
| 本地 MelismaKit 编译输入 | 首轮完整编译日志通过依赖检查；增量编译沿用同一 DerivedData |
| `check-app-bundle.sh` | 必需组件存在检查通过，不代表功能验收 |

本次修正 CLI 多行帮助文本缩进、DSP 审计分类变量作用域、三个音频测试文件的 App 模块名，以及 renderer 测试的局部变量重名。均衡器 Binding 回调明确 MainActor／Sendable；删除非可选错误描述上的无效 `??`，明确忽略预设选择返回值。维护者已经修正的 CoreAudio bitmap、LFE 标签与预设选择属性继续保留。

测试代码已编译但未执行，主 App 尚未启动验收。CPU、内存和可听切换延迟尚无实测数据；Debug 无签名构建也不代表发布签名或 Release 验收。


## 源码组成与审查记录

- `Services/Audio/DSP/AudioDSPModels.swift`：完整配置、稳定节点身份、递归 JSON、格式、版本预设和可听状态。
- `AudioDSPProcessor.swift`／`DSPParametricEQMath.swift`：九段 RBJ biquad、Double 历史、恒等段跳过、逐声道路由、共同响应算法、静态余量和 30 ms 互补余弦过渡。
- `RendererPlaybackPipeline.swift`：8192-frame 解码、2048-frame 输出、raw/output 账本、源 frame 回读及 cursor 恢复、未来部分 flush、重处理、latest-wins 和分析 PCM 替换。
- `AudioDSPController.swift`／`DSPPresetStore.swift`：App-wide owner、35 ms 编辑合并、草稿持久化、原子预设文件和版本冲突检查。覆盖及删除使用同一 store 串行事务；工作草稿不会覆盖显式已保存预设。保存到 App Application Support 的 `kmgccc_player/AudioDSP`。
- `AppSessionHost`／`LibrarySession`／`AVAudioPlaybackService`：随活动资料库绑定同一控制器；旧 request ID 过滤，外部来源标记停用，返回本地来源重新应用当前期望声音。
- `Views/Settings/AudioDSP`：预设操作、链顺序、九列 EQ、曲线拖动、输入输出增益、余量、格式与错误。设置 detail 的导航栈随分类切换重置。
- `AutomationDSPHandler`、共享 `AutomationDSPToolCatalog`、CLI 与 MCP：16 个正式方法，原子配置／操作、完整预设、revision／dry-run、请求等待、两个可订阅资源。错误不变成隐式启用或重试。

审查修正包括：零增益 bell/shelf 真旁路；峰值估计预先缓存系数；跨 segment 回读的 ArraySlice 索引；部分 flush 使用原 sample-buffer 精确 PTS；重读恢复 provider cursor；格式解析指针不逃出安全访问区间；启动草稿恢复不覆盖用户新编辑；内置平直节点身份固定；预设复制／选择按实际版本核对；诊断列表按稳定 ID 去重。

收尾审查还修正了 JSON 数值序列化后误报“已修改”、快速切换时旧输出分支的身份判定、恢复事件误用队尾格式以及重缓冲丢失原始 CMTime 精度。请求状态保留最近 64 条，MCP 等待查询实际历史；未知请求明确报错。启用 EQ 中的未知参数可保存为未兼容预设，选择时报告诊断；停用节点与停用段的未知参数保留原文。

原始与已处理 PCM 账本上限为 32 MiB，预热预算为 16 MiB，替换候选预算为 64 MiB，未来队列预算为 24 MiB；回读与分配前估算字节数，按源格式缩短缓存时域。静态余量按各声道的实际滤波路径及完整源频谱估算；它不构成瞬时峰值保证，削波、音质与资源使用仍需下面的人工验收。

源格式以实际 `AVAudioFormat` 布局为准。Apple SDK 明确 nil Mono/Stereo layout 与标准标签等价，因此仅对该平台约定构建 1/2 声道身份；更多声道不能按数量猜测。原始布局声明继续传给 renderer，DSP 不认识声道身份时按节点策略报告旁路。Apple 空间化仍位于自定义 DSP 之后。

## 维护者验收

静态门禁与源码审查不能确认可听切换、音质、CPU 或蓝牙/空间模式兼容性。建议维护者依次验证：

1. 构建主 App 与 `PlayerAutomation`；运行 `RendererPipelineTests`、`AudioDSPProcessorTests`、`AudioDSPControllerTests` 及 automation protocol 测试。音频测试统一通过 `@testable import kmgccc_player` 检查 App 实现，避免重复编译音频模型产生两套类型身份。
2. 默认关闭、启用且平直、boost/cut、六类滤波器、输入输出 gain、自动余量与手动关闭；检查样本、响应、峰值、状态重置和噪声。
3. 保存／覆盖／另存／复制／重命名／删除、导入预览、unknown disabled 参数、重复名称、启动恢复、切库，以及外部来源返回本地。
4. 播放／暂停下切换、快速反复编辑、seek/stop/切库打断、尾段、不同格式及同格式 gapless 边界，检查一次 EOF 与一次曲目提交。
5. 部分 flush false、迟到 completion、源回读失败、设备恢复；检查报错、可恢复性、实际中断标记和租约释放。
6. 有线、内置及蓝牙输出、180 ms 可视化设置、Apple 空间模式；测请求至可听 p50/p95、恒等旁路 CPU、九段 EQ CPU、缓存上限与内存回落。
7. MCP 全参数 patch／dryRun／revision 冲突／重试幂等、预设切换、资源更新、等待超时、错误读取清除与 audio scope 拒绝。P3–P6 能力不能在 P1–P2 的成功响应中冒充已执行。
