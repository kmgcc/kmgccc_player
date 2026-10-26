# 设置辅助描述文案清单与精修表

本清单整理了当前播放器全部 **45 处** 设置项辅助小字文案，按功能模块归类，并标明了当前的展示形式（**行内直显** 或 **Popover 弹窗**）以及对应的代码文件。

你可以直接在此文档上修改文案或留下意见，修改完成后告知，我将统一同步进代码。

---

## 文案编写规范参考

- **朴实自然**：使用书面、自然、具有适度人文质感的表达，避免口语、生硬机械语或纯黑话。
- **正面陈述**：直接说明事实、状态或操作，避免反向解释（如“不是”、“不会”、“无需”、“不要”等）。
- **极简明确**：每个字承担明确信息，省略显而易见或重复的说明。

---

## 目录
1. [常规与外观](#一-常规与外观) (4 项)
2. [播放中与全屏](#二-播放中与全屏) (3 项)
3. [歌词时间轴](#三-歌词时间轴) (4 项)
4. [音频全局与母带](#四-音频全局与母带) (7 项)
5. [DSP 原生音效节点](#五-dsp-原生音效节点) (16 项)
6. [数据管理与曲库](#六-数据管理与曲库) (8 项)
7. [存储与自动化](#七-存储与自动化) (3 项)

---

## 一、 常规与外观

| 序号 | 设置项 | 控件类型 | 当前呈现方式 | 当前文案 | 精修建议 / 预留修改 | 源码位置 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **1** | 自动更新 | 开关 | **Popover 弹窗** | 自动检查并在后台下载更新；退出 App 或点击侧边栏“重启更新”时安装。 | | [GeneralSettingsView.swift](../kmgccc_player/Views/Settings/General/GeneralSettingsView.swift) |
| **2** | HDR 效果 | 开关 | **Popover 弹窗** | 开启后部分视觉元素会使用 HDR 来增强可读性与视觉效果。需要支持的显示器。 | | [AppearanceSettingsView.swift](../kmgccc_player/Views/Settings/Appearance/AppearanceSettingsView.swift#L92) |
| **3** | 主页板块顺序 | 排序列表 | **行内直显** | 拖动调整主页中各个板块的显示顺序 | | [AppearanceSettingsView.swift](../kmgccc_player/Views/Settings/Appearance/AppearanceSettingsView.swift#L310) |
| **4** | 动态取色 | 胶囊选择器 | **Popover 弹窗** | 简洁使用默认色，动态跟随播放封面，丰富为列表歌曲分别取色。 | | [AppearanceSettingsView.swift](../kmgccc_player/Views/Settings/Appearance/AppearanceSettingsView.swift#L160) |

---

## 二、 播放中与全屏

| 序号 | 设置项 | 控件类型 | 当前呈现方式 | 当前文案 | 精修建议 / 预留修改 | 源码位置 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **5** | 启用艺术背景 | 开关 | **无 (已移除)** | (已按精修要求移除说明) | | [NowPlayingGeneralTabView.swift](../kmgccc_player/Views/Settings/NowPlaying/NowPlayingGeneralTabView.swift#L31) |
| **6** | 减弱高亮 | 开关 | **Popover 弹窗** | 开启后歌词逐字亮起而不是扫光。 |  | [NowPlayingLyricsTabView.swift](../kmgccc_player/Views/Settings/NowPlaying/NowPlayingLyricsTabView.swift#L72) |
| **7** | 减弱高亮 | 开关 | **Popover 弹窗** | 开启后歌词逐字亮起而不是扫光。 |  | [FullscreenLyricsTabView.swift](../kmgccc_player/Views/Settings/Fullscreen/FullscreenLyricsTabView.swift#L92) |

---

## 三、 歌词时间轴

| 序号 | 设置项 | 控件类型 | 当前呈现方式 | 当前文案 | 精修建议 / 预留修改 | 源码位置 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **8** | 时间控制参数 | 区域顶部 | **行内直显** | 参数仅供调试，日常聆听保持默认即可。 | | [LyricsTimingConfigSection.swift](../kmgccc_player/Views/Settings/Shared/LyricsTimingConfigSection.swift#L33) |
| **9** | 提前量 | 滑块 | **行内直显** | 调整歌词行首和行尾单词的出现时机。 | | [LyricsTimingConfigSection.swift](../kmgccc_player/Views/Settings/Shared/LyricsTimingConfigSection.swift#L84) |
| **10** | 紧邻切行阈值 | 滑块 | **行内直显** | 当下一句开始时间与当前句结束时间间隔小于该值时，会在“提前量”剩余时提前切到下一句，并让当前句快速隐退。 | | [LyricsTimingConfigSection.swift](../kmgccc_player/Views/Settings/Shared/LyricsTimingConfigSection.swift#L108) |
| **11** | 歌词整体提前量 | 滑块 | **行内直显** | 全曲歌词统一提前显示：正值更早，负值更晚，与单曲时间偏移叠加生效。 | | [LyricsTimingConfigSection.swift](../kmgccc_player/Views/Settings/Shared/LyricsTimingConfigSection.swift#L126) |

---

## 四、 音频全局与母带

| 序号 | 设置项 | 控件类型 | 当前呈现方式 | 当前文案 | 精修建议 / 预留修改 | 源码位置 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **12** | 音频延迟补偿 | 开关 | **行内直显** | 延迟音频输出以对齐频谱与可视化动效。 | | [AudioSettingsView.swift](../kmgccc_player/Views/Settings/AudioSettingsView.swift#L67) |
| **13** | 音量均衡 | 开关 | **Popover 弹窗** | 测量歌曲的响度并整体调整电平，使歌曲之间响度一致，曲中的强弱起伏完全保留。 | | [AudioProcessingGlobalsSettingsView.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioProcessingGlobalsSettingsView.swift#L36) |
| **14** | 目标响度 | 滑块 | **Popover 弹窗** | 均衡后每首歌的平均响度。推荐值 −14 LUFS，与多数流媒体平台相当。 | | [AudioProcessingGlobalsSettingsView.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioProcessingGlobalsSettingsView.swift#L351) |
| **15** | 余量保护 | 开关 | **Popover 弹窗** | 效果提升电平时，相应自动降低输入，为峰值留出余地。 | | [AudioDSPLinearNodeRack.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPLinearNodeRack.swift#L199) |
| **16** | 余量保护最大衰减 | 滑块 | **Popover 弹窗** | 余量保护降低的电平上限，超出部分由安全限幅处理。 | | [AudioDSPLinearNodeRack.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPLinearNodeRack.swift#L208) |
| **17** | 安全限幅上限 | 滑块 | **Popover 弹窗** | 输出峰值始终保持在此电平以下。 | | [AudioDSPLinearNodeRack.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPLinearNodeRack.swift#L284) |
| **18** | 等响度补偿强度 | 滑块 | **Popover 弹窗** | 补偿曲线的施加比例，1.00 为完整补偿。 | | [AudioDSPLinearNodeRack.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPLinearNodeRack.swift#L738) |

---

## 五、 DSP 原生音效节点

| 序号 | 音效节点 / 参数项 | 控件类型 | 当前呈现方式 | 当前文案 | 精修建议 / 预留修改 | 源码位置 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **19** | 低音截止频率 (虚拟/混成) | 滑块 | **Popover 弹窗** | 此频率以下的低音由谐波重新呈现。设备的低频越弱，可以设得越高。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L89) |
| **20** | 经典低音冲击 | 滑块 | **Popover 弹窗** | 高次谐波的衰减程度。数值越高，泛音越丰富，低音轮廓越清晰，但可能引入杂讯。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L122) |
| **21** | 混成低音冲击 | 滑块 | **Popover 弹窗** | 生成谐波时的驱动力度。数值越高，低音越饱满有力，但可能引入杂讯。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L160) |
| **22** | 保留物理低音 | 开关 | **Popover 弹窗** | 关闭后，截止频率以下的原声会被滤去，只由谐波呈现低音，适合难以重放低频的小扬声器。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L748) |
| **23** | 调校目标设备 (耳机/扬声器) | 胶囊选择器 | **Popover 弹窗** | 按照你正在使用的设备选择，并重新调整到合适的参数。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L190) |
| **24** | 声场宽度 | 滑块 | **Popover 弹窗** | 1.00× 为原始声场，低于此值收窄，高于此值展宽。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L204) |
| **25** | 互馈强度 (Crossfeed) | 胶囊选择器 | **Popover 弹窗** | 让两个声道产生一些混合，模拟音箱听感。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L230) |
| **26** | 空间声源 (虚拟音箱/脉冲) | 胶囊选择器 | **Popover 弹窗** | 虚拟音箱在耳机中模拟面前的一对音箱；脉冲响应可导入实测空间的音频文件。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L252) |
| **27** | 空间音箱角度 | 滑块 | **Popover 弹窗** | 每只音箱偏离正前方的角度。角度越大，声场越开阔。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L280) |
| **28** | 效果混合比例 (Mix) | 滑块 | **Popover 弹窗** | 处理后的声音与原声的比例。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L88) |
| **29** | 混响大小 | 滑块 | **Popover 弹窗** | 空间越大，混响越悠长。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L394) |
| **30** | 混响明暗 | 滑块 | **Popover 弹窗** | 调节混响中高频的比例。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L398) |
| **31** | 电子管饱和模式 | 胶囊选择器 | **Popover 弹窗** | 经典让整段声音一同饱和，色彩浓郁；高保真只在原声之上叠加少量谐波，原声保持完整。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L412) |
| **32** | 经典电子管驱动 | 滑块 | **Popover 弹窗** | 送入电子管的电平。数值越高，饱和越明显。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L436) |
| **33** | 经典电子管不对称 (偏置) | 滑块 | **Popover 弹窗** | 偏离零点越远，偶次谐波越多，声音越温暖。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L440) |
| **34** | 多频段压缩预设风格 | 胶囊选择器 | **Popover 弹窗** | 轻柔使整体动态更平稳；夜间更明显地收住响亮的段落，适合低音量聆听细节。调整任一数值即转为自定义。 | | [AudioDSPNativeEffectEditors.swift](../kmgccc_player/Views/Settings/AudioDSP/AudioDSPNativeEffectEditors.swift#L490) |

---

## 六、 数据管理与曲库

| 序号 | 设置项 | 控件类型 | 当前呈现方式 | 当前文案 | 精修建议 / 预留修改 | 源码位置 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **35** | 空闲时提前准备 | 开关 | **行内直显** | 接通电源且空闲时提前分析响度、整理封面与歌词；使用电池时，仅准备即将播放的歌曲。 | | [BackgroundTasksSettingsView.swift](../kmgccc_player/Views/Settings/DataManagement/BackgroundTasksSettingsView.swift#L36) |
| **36** | 后台调度节奏 | 胶囊选择器 | **Popover 弹窗** | 轻缓计算更放松，且每项工作之间稍作停歇，电脑更安静、更凉爽。 | | [BackgroundTasksSettingsView.swift](../kmgccc_player/Views/Settings/DataManagement/BackgroundTasksSettingsView.swift#L46) |
| **37** | 导入时延后补全信息 | 开关 | **Popover 弹窗** | 导入时先完成文件复制，在后台补全歌词和封面。 | | [DataManagementSettingsView.swift](../kmgccc_player/Views/Settings/DataManagement/DataManagementSettingsView.swift#L63) |
| **38** | 补全所有歌曲信息 | 按钮 | **行内直显** | 在此处批量联网补全所有本地曲库中缺失的歌曲信息、封面和歌词。 | | [DataManagementSettingsView.swift](../kmgccc_player/Views/Settings/DataManagement/DataManagementSettingsView.swift#L80) |
| **39** | 重置应用设置与状态 | 按钮 | **行内直显** | 清除 App 设置项，恢复默认值。 | | [DataManagementSettingsView.swift](../kmgccc_player/Views/Settings/DataManagement/DataManagementSettingsView.swift#L95) |
| **40** | 重置播放统计数据 | 按钮 | **行内直显** | 清除音乐播放记录，包括歌曲聆听计数、播放时长等。 | | [DataManagementSettingsView.swift](../kmgccc_player/Views/Settings/DataManagement/DataManagementSettingsView.swift#L190) |
| **41** | 受信任的音频目录 | 区域说明 | **行内直显** | 受信任目录内的自动化和文件操作可直接执行。 | | [AutomationSettingsView.swift](../kmgccc_player/Views/Settings/AutomationSettingsView.swift) |
| **42** | 清理外部播放匹配与媒体缓存 | 按钮 | **行内直显** | 清除自动匹配结果、自动封面和自动歌词缓存；保留手动匹配、手动歌词和播放源规则。 | | [ExternalPlaybackSettingsView.swift](../kmgccc_player/Views/Settings/ExternalPlaybackSettingsView.swift#L144) |

---

## 七、 存储与自动化

| 序号 | 设置项 | 控件类型 | 当前呈现方式 | 当前文案 | 精修建议 / 预留修改 | 源码位置 |
| :---: | :--- | :--- | :---: | :--- | :--- | :--- |
| **43** | 清理全部缓存 | 按钮 | **行内直显** | App 会在空闲时也会整理缓存，让它们保持在各自的上限以内；清理后，需要的内容会在使用时重新生成。 | | [StorageSettingsView.swift](../kmgccc_player/Views/Settings/Storage/StorageSettingsView.swift#L68) |
| **44** | 启用本机自动化 | 开关 | **行内直显** | 让本机上的 MCP、CLI 和脚本访问播放器。 | | [AutomationSettingsView.swift](../kmgccc_player/Views/Settings/AutomationSettingsView.swift#L34) |
| **45** | 复制 MCP 配置 | 命令行/按钮 | **行内直显** | 配置可直接粘贴到 agent 工具的配置文件。 | | [AutomationSettingsView.swift](../kmgccc_player/Views/Settings/AutomationSettingsView.swift#L48) |
