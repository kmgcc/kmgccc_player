# Liquid Glass (液态玻璃) 设计规范 - kmgccc_player

本文件定义了 `kmgccc_player` 应用中 “Liquid Glass” UI 的统一规范。所有后续 Agent 必须遵守此规范，以确保应用视觉的一致性和 Apple 设计语言的严谨性。

## 核心原则 (Core Principles)

1.  **Glass = Controls/Navigation**: 玻璃材质仅用于导航栏、侧边栏、浮动控制条等“控制层”。
2.  **Content = Content**: 列表、表格和内容展示区禁止使用玻璃材质，应保持背景稳重、可读性高。
3.  **No Glass-on-Glass**: 禁止玻璃叠玻璃。如果必须在玻璃上叠加，请使用普通填充或微调透明度，而非再次应用 `.glassEffect`。
4.  **Standard Material**: 全局统一使用 `.clear` 变体配合自定义 Tint Overlay，以获得最高级的液态透明感。

## 统一工具 (Standardized Tools)

所有的玻璃效果必须使用 `GlassPillView.swift` 中定义的扩展，严禁直接手写 `.glassEffect` 及其相关的 Overlay。

### 1. 基础修飾符 (modifiers)

- `liquidGlass(in: shape, ...)`: 基础工具，自动应用玻璃效果、发丝缝边 (Hairline Border)、自适应压暗背景 (Dark Neutral Overlay) 以及主题色填充 (Tint Overlay)。
- `liquidGlassPill(...)`: 针对胶囊形（Pill）的快捷工具。
- `liquidGlassRect(...)`: 针对圆角矩形的快捷工具。
- `liquidGlassCircle(...)`: 针对圆形的快捷工具。

### 2. 设计令牌 (Design Tokens)

所有样式参数由 `GlassStyleTokens.swift` 统一管理：

- **发丝缝边**: `hairlineWidth` (0.5), `glassBorderColor` (白色透明度自适应)。
- **压暗背板**: `darkNeutralOverlay(for:)` (暗色模式下的 18% 黑色压暗)。
- **主题着色 (Tinting)**:
    - `Prominence.standard`: 默认强度 (约 2.4% - 2.6%)，用于次要或常规控件。
    - `Prominence.prominent`: 高强度 (约 3% - 4.5%)，用于主控制台 (MiniPlayer)。
- **阴影**: `subtleFloatingShadow()` 用于浮动元素。

## 实施指导 (Implementation Guide)

### 示例：创建一个新控件

```swift
// ❌ 错误做法：手写逻辑
Circle()
    .glassEffect(.clear, in: .circle)
    .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    .background(Circle().fill(Color.blue.opacity(0.02)))

// ✅ 正确做法：使用规范扩展
Circle()
    .liquidGlassCircle(
        colorScheme: colorScheme,
        accentColor: themeStore.accentColor,
        prominence: .standard
    )
```

### 组件高度规范

- **Header Bar**: 60pt
- **Header Control**: 36pt (Button, Search Field)
- **Mini Player**: 60pt

### 分层优先级

- 侧边栏/主导航层：使用 `Regular` 材质或标准 `liquidGlass`。
- 浮动控件：开启 `isFloating: true` 以获得阴影支持。
- 标题栏背景：避免玻璃叠加，使用 Scrim (渐变压制) 处理。

---

*注：本规范随应用设计迭代。修改本规范前请先咨询 Agent 核心架构视图。*
