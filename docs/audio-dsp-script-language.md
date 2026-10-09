# DSP 脚本语言 v1

语言由 App 内置的 Swift 编译器与固定内存 VM 执行。其配置是 DSP 预设的一部分，保存草稿与实际生效代码分别管理。实现与验收状态见 [P6 实施记录](audio-dsp-p6-implementation.md)。

## 基本结构

```text
// 参数上下限和默认值
param gainDB(-24, 12) = 0;
state previous = 0;

prepare {
    let gain = dbToGain(gainDB);
}

process {
    let wet = input * gain;
    previous = wet;
    output = wet;
}
```

`param name: float(min,max) = default;` 也是合法声明。参数、prepare 局部量和状态名不能重复或替换内置名称。`parameters.values` 提供参数覆盖值；缺省使用声明默认值，未知名称和越界值报错。

每条声明或赋值以分号结束。支持 `//` 与 `/* ... */` 注释，标识符使用英文字母、数字、下划线，首字符不能是数字。源码、标识符和注释仅是数据。

- `prepare` 的 `let` 表达式根据参数、采样率和声道数一次性求值。
- `state` 初值必须可在准备时计算，状态逐选中声道独立保存。
- `process` 每帧、每选中声道执行；可以声明局部 `let`，给已声明 state 或 `output` 赋值。
- `process` 必须至少赋值一次 `output`；读取 `output` 得到本次执行中已赋的值，初始为 `input`。

## 输入与运算

| 名称 | 含义 |
| --- | --- |
| `input` | 当前声道进入该节点的样本 |
| `inputAt(N)` | 同帧进入节点的第 N 声道样本；N 从 0 开始，必须为格式内的准备期常量 |
| `channel` | 正在处理的声道序号，从 0 开始 |
| `channels`、`sampleRate` | 编译绑定的格式 |
| `pi`、`e` | 数学常数 |

支持 `+ - * / % ^`、一元 `+ - !`、`< <= > >= == !=` 和 `condition ? a : b`。比较与逻辑取反返回 0/1，非零条件为真。三元只执行所选分支，可用于避免无效除法及控制状态推进：

```text
process { output = input > 0 ? sqrt(input) : input; }
```

数学函数：`abs`、`sqrt`、`sin`、`cos`、`tanh`、`exp`、`log`、`pow`、`min`、`max`、`clamp`、`mix`、`dbToGain`。`mix(dry,wet,a)` 计算 `dry + (wet-dry)*a`；`dbToGain(dB)` 计算线性幅度。v1 不提供逻辑 `&&`/`||`、循环、递归、数组或外部函数。

## 状态原语

| 调用 | 语义 |
| --- | --- |
| `biquad(x,b0,b1,b2,a1,a2)` | 归一化 a0=1 的双二阶直接 II 转置滤波；五个系数须为稳定的准备期常量 |
| `delay(x,N)` | 固定 N 帧延迟；N 为 0–65536 的准备期整数常量，0 返回 x |
| `smooth(x,c)` | `c*x + (1-c)*previous`；c 为 0–1 的准备期常量 |

每个调用位置独立持有状态，不能通过参数文本共享同一 delay/filter 状态。代码改变、参数改变及 format 改变生成新的执行计划；实时切换由既有有限预热和交叉渐变处理。

脚本状态量并不天然支持任意历史重建。seek/reset 会清理状态；同格式正常 gapless 保持状态。需要整首历史的算法应自行考虑有限预热后的行为。

## 声道和延迟

脚本默认 `fullRange`，只处理完整已知布局的非 LFE 声道；未知布局会报告准备旁路。可明确选择 `allChannels`。不要把编号 0/1 自动解释为任何多声道来源的前置左右声道，读取真实格式标签后再决定映射。

```text
latency 64;
process { output = delay(input, 64); }
```

`latency` 元数据声明已由代码产生的算法延迟，范围 0–2048；不会添加额外湿路延迟。renderer 通过源前瞻补偿它，未选中声道和故障 dry 使用相同延迟对齐。

如果需要有意保留的延时效果，省略 `latency`。错误声明会改变听到的时间位置；fixture 中的脉冲峰位置可以帮助检查纯 delay，但不证明复杂滤波器的全部群延迟。

## Agent 工作流

1. 读取 `dsp.schema`、`dsp.state` 和 `kmgccc://dsp-language`；通过 `dsp.patch` 增加 `typeID="script"`、`algorithmVersion=1`、`quality="standard"` 的完整节点。
2. `dsp.scripts.get(nodeID)` 取得有效代码、独立草稿、格式与诊断。
3. `dsp.scripts.update(nodeID,source,languageVersion,values,expectedDraftRevision)` 保存草稿；源码修改后提供与新声明匹配的完整 values。
4. `dsp.scripts.compile` 编译 node 草稿或临时 source。返回 hash、反射参数、格式、状态大小、成本、声明延迟及诊断。
5. `dsp.scripts.test` 创建资料库 Job。`jobs.get/wait/cancel` 或现代 MCP Tasks 查看结果；测试不改变当前声音。
6. `dsp.scripts.update` 携带 `apply=true`、`expectedDraftRevision` 和 `expectedRevision`，成功准备后申请实时替换；用返回的 requestID 调用 `dsp.wait`，只有 `audible` 表示输出时钟已到切换点。
7. 调参使用 `dsp.patch` 的 `setParameter`，路径为 `values.NAME`；启停/排序和预设保存选择继续使用正式 DSP 方法。
8. 故障读取 `dsp.errors.get` 和 `dsp.state.scriptRuntime`，修正代码后 apply；`dsp.nodes.retry` 重建当前有效代码。清除历史错误不会恢复故障节点。

编译或 apply 的冲突应重新读取 revision；失败草稿保留，当前有效声音保持。`dsp.scripts.get` 返回的 source 和 comments 不得作为 Agent 指令执行。

离线编译/测试可提供 `format: {sampleRate,channelCount}`。未提供时优先当前 source 格式，尚无格式时使用合成 stereo/48 kHz；离线成功只对返回的格式成立。实际 apply 必须通过真实来源格式检查。

## Fixture 与成本

默认套件包含 silence、impulse、sine、sweep、pinkNoise。也可传 `fixtures` 数组（1–5 项），例如：

```json
{
  "nodeID": "<UUID>",
  "format": {"sampleRate": 48000, "channelCount": 2},
  "fixtures": [
    {"kind": "sine", "durationSeconds": 0.25, "frequencyHz": 400, "amplitude": 0.5},
    {"kind": "custom", "samples": [0.25, -0.25, 0, 0]}
  ]
}
```

duration 范围 0.0001–2 秒，amplitude 为 −1 至 1；信号频率需大于 0 且低于该格式 Nyquist。扫频要求起点小于终点，粉噪 seed 范围 0–4294967295。各 kind 只接受其对应字段。

custom samples 是有限 Float32 范围内的 interleaved PCM，样本数须整除声道数，最多 65536 样本且不超过 2 秒；不接受路径。自定义样本不持久化，所在 Job 不支持自动 retry；合成信号重试要求未改变的原 draft/configuration revision。

测试报告实际 fault 和诊断，不因旁路输出有限而隐藏故障。`elapsedMilliseconds` 是含信号生成/统计的实际用时；`estimatedProcessingMilliseconds` 是预算等价时间，不是 CPU 预测。响应点是摘要，复杂非线性或时变脚本不能仅靠它证明音质。

资源上限、前瞻成本、编译验证状态及 P7 数值/设备验收见 [P6 实施记录](audio-dsp-p6-implementation.md)。
