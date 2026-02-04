# Liquid Glass（液态玻璃）用于 Bar / 导航层：硬约束清单

将以下规则视为“写 SwiftUI（macOS）UI 的硬约束”。核心原则：**Glass = controls/navigation；Content = content。**

## 1) 定位：只做导航层，不侵入内容层

- 将 Liquid Glass 主要用在“漂浮在内容之上的导航/控制层”：toolbar、sidebar、tab bar、menus 等。
- 避免把内容区（content layer）做成玻璃（例如列表/表格主体、主要卡片面板）。否则层级会糊、主次不清。

## 2) 禁止玻璃叠玻璃（glass-on-glass）

- 永远避免玻璃叠玻璃：一个 Liquid Glass 放在另一个 Liquid Glass 上，或在玻璃上再做玻璃卡片。
- 如果必须在玻璃上放东西：用普通 fill / 透明度 / vibrancy 做“薄覆盖层”，不要再套一层玻璃材质。

## 3) 变体：Regular vs Clear（不混用；Clear 必须加压暗层）

- 两种变体：Regular 与 Clear，**不要混用**。
- **默认 Regular**：更通用，系统会更积极地保证可读性。
- **只有在愿意加压暗层时才用 Clear**：Clear 更透明，但可读性更脆弱；必须加 dimming layer（压暗层 / scrim）压住背后内容。

硬规则：
- “默认 Regular；只有在满足 Clear 使用条件且你愿意加压暗层时才用 Clear；两者绝不混。”

## 4) Toolbar 组织：必须按任务分组

用分组让 glass 看起来干净、层级清晰：

- 主操作一组（播放/暂停/确认等）
- 次操作一组（搜索/添加/管理等）
- 视图/布局一组（切换侧边栏、排序/筛选、布局切换等）

避免一排“杂烩按钮”。

## 5) 滚动与分离：Bar 始终浮在内容上

- 目标是在尽量透出内容的同时，动态确保分离与可读性。
- 当内容（文字/图片）滚到下面时，Bar 需要仍保持清晰层级与阅读稳定性（阴影/调色/对比的自动变化是合理的）。

## 6) 可读性与无障碍：系统设置会改变玻璃

必须确保在下列情境下文字/图标仍清楚可见：

- Light / Dark
- 花哨背景（高对比图/专辑封面）
- Reduced Transparency
- Increased Contrast
- Reduced Motion

注意：用户可能看到的是更“雾/更不透明/更 tinted”的玻璃版本；设计要默认接受这种变化，并保持层级清晰。

## 7) 实现策略（非常关键）

- 尽量用系统提供的 bar / 控件（系统 toolbar、sidebar、NavigationSplitView 等）来“自动吃到”最新玻璃外观与动态适配。
- 避免为了“玻璃感”而在内容层手写一堆自定义毛玻璃背景。
