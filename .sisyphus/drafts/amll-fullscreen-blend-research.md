# AMLL Fullscreen Cover Blur Blend Mode Research

## 任务目标
只在 fullscreen 模式下、且当前 skin 是 fullscreen 封面模糊皮肤（cover blur / coverGradientBlur）时，让 AMLL 真正使用 plus-lighter / darker 混合模式。

---

## Phase 1: 当前生效链路检查 ✅

### 1.1 Swift 侧状态条件

**Skin 类型检测** (`FullscreenPlayerView.swift:93-96`):
```swift
let selectedSkinID = settings.selectedFullscreenSkinID
let selectedSkin = SkinRegistry.fullscreenSkin(for: selectedSkinID)
let usesCustomBg = selectedSkinID == "fullscreen.coverGradientBlur"
```
- 没有通用的 `isCoverSkin` 属性
- 直接通过字符串比较判定：`selectedSkinID == "fullscreen.coverGradientBlur"`

**配置传递** (`FullscreenPlayerView.swift:995-1027`):
```swift
let config: [String: Any] = [
    // ... other config ...
    "mixBlendMode": "normal",  // ❌ 硬编码 normal
    "blendOpacity": 1.0,
    "fullscreenLyricDodgeMode": true,
    // ❌ 缺少: fullscreenBlendProfile
    // ❌ 缺少: fullscreenMainBlendMode
    // ❌ 缺少: fullscreenHighlightBlendMode
    // ❌ 缺少: fullscreenGlowBlendMode
]
```

**关键发现**: Swift **从未发送** `fullscreenBlendProfile` 到 WebView！

### 1.2 WebView/JS 配置链路

**JavaScript 接收逻辑** (`index.html:2129-2166`):
```javascript
if (hasOwn("fullscreenBlendProfile")) {
    const profile = config.fullscreenBlendProfile;
    if (profile === "lighter" || profile === "darker") {
        playerElement.setAttribute("data-amll-blend-profile", profile);
        // 设置 CSS 变量...
    }
}
```

**状态**: JavaScript 已经完全准备好接收和应用 blend profile，但 Swift 从未发送！

### 1.3 DOM/CSS 最终层级

**默认 fullscreen CSS** (`index.html:78-91`):
```css
.amll-lyric-player.amll-surface-fullscreen:not([data-amll-blend-profile]),
.amll-lyric-player.amll-surface-fullscreen:not([data-amll-blend-profile]) * {
    mix-blend-mode: normal !important;  /* ❌ 强制 normal */
    background-blend-mode: normal !important;
}
```

**Blend Profile CSS** (`index.html:93-197`):
- **"lighter" profile**: 对所有歌词元素应用 `plus-lighter`
- **"darker" profile**: 对所有歌词元素应用 `color-burn`，但高亮部分用 `normal`

**关键发现**: CSS 规则已经完善，只需要设置 `data-amll-blend-profile` 属性即可激活！

### 1.4 覆盖点总表

| 覆盖点 | 位置 | 当前值 | 影响 |
|--------|------|--------|------|
| **Swift config 中缺少 fullscreenBlendProfile** | `FullscreenPlayerView.swift:995-1027` | 未设置 | ❌ JS 无法设置 data-amll-blend-profile |
| **CSS 默认规则强制 normal** | `index.html:78-91` | `mix-blend-mode: normal !important` | ❌ 没有属性选择器时强制 normal |
| **CSS * 选择器** | `index.html:79` | 所有子元素 `*` | ✅ 被 `[data-amll-blend-profile]` 选择器覆盖 |

---

## Phase 2: 对比 Original 版本 ✅

### 2.1 Original 实现方式

**CSS 类名**: `fs-color-dodge`

**CSS 规则**:
```css
.amll-lyric-player.fs-color-dodge [class*="_lyricMainLine_"],
.amll-lyric-player.fs-color-dodge [class*="_lyricMainLine_"] *,
.amll-lyric-player.fs-color-dodge [class*="_romanWord_"],
.amll-lyric-player.fs-color-dodge [class*="_interludeDots_"] {
    mix-blend-mode: plus-lighter !important;
}
```

**特点**:
- ✅ 使用 `plus-lighter` 混合模式
- ✅ 选择性地应用到歌词行元素
- ✅ 容器保持 `normal`，子元素使用 `plus-lighter`

### 2.2 当前实现方式

**CSS 类名**: `amll-surface-fullscreen`

**CSS 规则**:
```css
.amll-lyric-player.amll-surface-fullscreen:not([data-amll-blend-profile]),
.amll-lyric-player.amll-surface-fullscreen:not([data-amll-blend-profile]) * {
    mix-blend-mode: normal !important;
}
```

**特点**:
- ❌ 默认强制 `normal` 到所有元素
- ✅ **但有例外**: 当存在 `[data-amll-blend-profile]` 属性时，使用 profile 专用规则

### 2.3 关键差异

| 方面 | Original | 当前 |
|------|----------|------|
| CSS 类名 | `fs-color-dodge` | `amll-surface-fullscreen` |
| 默认 blend mode | `plus-lighter` | `normal` (无属性时) |
| Profile 系统 | 无 | ✅ 有 (lighter/darker) |
| 触发方式 | 添加 CSS 类 | 设置 data 属性 |
| Swift 发送配置 | 未知 | ❌ 未发送 fullscreenBlendProfile |

### 2.4 为什么当前退回 normal

**根因**: Swift 代码从未发送 `fullscreenBlendProfile` 配置项！

数据流断裂：
```
Swift: applyFullscreenLyricsTheme() 
  → config 字典中缺少 fullscreenBlendProfile ❌
  → setConfigJSON() 发送不完整配置
  → JavaScript setConfig() 收到无 fullscreenBlendProfile 的 config
  → 不设置 data-amll-blend-profile 属性
  → CSS 规则 `.amll-surface-fullscreen:not([data-amll-blend-profile])` 生效
  → 强制所有元素 `mix-blend-mode: normal`
```

---

## Phase 3: 最小安全修改面 ✅

### 3.1 修改范围收口

**只修改**:
- ✅ `FullscreenPlayerView.swift` - 添加 fullscreenBlendProfile 配置逻辑

**不修改**:
- ❌ `Resources/AMLL/index.html` - CSS 已经完善
- ❌ `Resources/AMLL/style.css` - 不需要改动
- ❌ 其他 fullscreen 皮肤 - 不受影响
- ❌ 非 fullscreen 模式 - 不受影响

### 3.2 Swift 条件收口

```swift
// 只有 fullscreen + coverGradientBlur skin 才设置 blend profile
if selectedSkinID == "fullscreen.coverGradientBlur" {
    // 计算 blend profile: "lighter" 或 "darker"
    // 添加到 config
}
```

### 3.3 CSS 选择器收口

CSS 已经通过 attribute selector 完美收口：
```css
[data-amll-blend-profile="lighter"] { /* 仅 lighter profile */ }
[data-amll-blend-profile="darker"] { /* 仅 darker profile */ }
```

### 3.4 不影响其他场景

| 场景 | 是否受影响 | 原因 |
|------|-----------|------|
| fullscreen + coverGradientBlur | ✅ 受影响 | Swift 发送 blend profile |
| fullscreen + 其他皮肤 | ❌ 不受影响 | Swift 不发送 blend profile，保持 normal |
| 普通 Now Playing 模式 | ❌ 不受影响 | 不使用 fullscreen surface |
| 已有的 darker 高亮 normal 例外 | ❌ 不受影响 | CSS 已有规则保护 |

---

## Phase 4: 详细修改方案 ✅

### A. 当前根因总结

**覆盖点在阻挡 cover blur skin 下 AMLL 进入 plus-lighter/darker**:
1. **Swift 侧未发送 fullscreenBlendProfile** - 这是最关键的缺失
2. **CSS 默认规则强制 normal** - 但这被 data-attribute 选择器正确覆盖

**哪些规则写了但没命中最终可见层**:
- 无。CSS 规则本身正确，只是缺少触发条件（data-amll-blend-profile 属性）

### B. Original 对比结论

**值得参考的部分**:
- Original 直接使用 `plus-lighter` 的思路正确
- 当前代码已有更完善的 blend profile 系统，不需要照搬 original

**关键差异**:
- Original: 通过 CSS 类名触发
- 当前: 通过 data-attribute 触发（更灵活）

**为什么当前版本退回 normal**:
- Swift 没有发送 `fullscreenBlendProfile` 配置

### C. 最小修改面方案

#### 1. Swift 侧修改

**文件**: `FullscreenPlayerView.swift`

**函数**: `applyFullscreenLyricsTheme()` (约 line 960)

**修改内容**:
```swift
// 在 config 字典构建之前，添加 blend profile 逻辑
let fullscreenBlendProfile: String? = {
    guard settings.selectedFullscreenSkinID == "fullscreen.coverGradientBlur" else { return nil }
    
    // 根据封面主色调亮度决定 profile
    guard let avgColor = artworkSnapshot?.averageColor else { return "lighter" }
    
    // 计算亮度
    var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
    avgColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
    let lightness = (red + green + blue) / 3.0
    
    // lightness <= 0.9 → lighter (plus-lighter)
    // lightness > 0.9 → darker (color-burn)
    return lightness <= 0.9 ? "lighter" : "darker"
}()

// 在 config 字典中添加
var config: [String: Any] = [
    // ... existing config ...
    "mixBlendMode": "normal",
    "blendOpacity": 1.0,
    "fullscreenLyricDodgeMode": true,
]

// 仅当 coverGradientBlur skin 时添加 blend profile
if let profile = fullscreenBlendProfile {
    config["fullscreenBlendProfile"] = profile
    config["fullscreenMainBlendMode"] = profile == "lighter" ? "plus-lighter" : "color-burn"
    config["fullscreenHighlightBlendMode"] = profile == "lighter" ? "plus-lighter" : "normal"
    config["fullscreenGlowBlendMode"] = profile == "lighter" ? "plus-lighter" : "color-burn"
}
```

#### 2. JS 侧修改

**无需修改** - JavaScript 已经准备好接收和应用 blend profile

#### 3. WebView root 标记

**无需修改** - JS 会自动设置 `data-amll-blend-profile` 属性

#### 4. CSS 修改

**无需修改** - CSS 规则已经完善

#### 5. 哪些旧规则必须排除/绕开/延后

**无需要排除的旧规则** - 当前 CSS 架构正确，通过 attribute selector 自然覆盖

#### 6. darker 模式下高亮层 normal 例外如何保留

**已保留** - CSS 规则 (index.html:176-179) 已有：
```css
.amll-lyric-player.amll-surface-fullscreen[data-amll-blend-profile="darker"] .amll-fs-word-active,
.amll-lyric-player.amll-surface-fullscreen[data-amll-blend-profile="darker"] .amll-fs-char-active {
    mix-blend-mode: normal !important;  /* 例外：高亮用 normal 保持对比度 */
}
```

### D. 具体修改清单

| 文件路径 | 函数/配置 | 修改内容 | 为什么改 | 风险点 |
|---------|----------|---------|---------|--------|
| `FullscreenPlayerView.swift:960-1027` | `applyFullscreenLyricsTheme()` | 添加 fullscreenBlendProfile 计算和发送逻辑 | Swift 从未发送该配置，导致 JS 无法设置 data 属性 | 低 - 仅影响 coverGradientBlur skin |
| `FullscreenPlayerView.swift:95` | `body()` | 确保 `selectedSkinID` 变量在 `applyFullscreenLyricsTheme()` 中可访问 | 需要在 config 构建时检测 skin 类型 | 无 - 变量已定义 |

### E. 验证计划

#### 验证矩阵

**1. fullscreen + coverGradientBlur skin**
| 元素 | lighter profile | darker profile |
|------|----------------|----------------|
| 主歌词非高亮部分 computed mix-blend-mode | `plus-lighter` | `color-burn` |
| 非当前行 | `plus-lighter` | `color-burn` |
| 翻译 | `plus-lighter` | `color-burn` |
| 背景歌词 | `plus-lighter` | `color-burn` |
| 间奏点 | `plus-lighter` | `color-burn` |
| glow 层 | `plus-lighter` | `color-burn` |
| 高亮层 | `plus-lighter` | `normal` (例外) |

**2. fullscreen + 非 cover skin**
| 元素 | computed mix-blend-mode |
|------|------------------------|
| 所有歌词层 | `normal` |

**3. 普通模式**
| 元素 | computed mix-blend-mode |
|------|------------------------|
| 所有歌词层 | `plus-lighter` (默认 AMLL 行为) |

#### 验证命令

```bash
# 在 Safari 开发者工具中检查
document.querySelector('.amll-lyric-player').getAttribute('data-amll-blend-profile')
# 应返回 "lighter" 或 "darker" (仅 coverGradientBlur skin)

getComputedStyle(document.querySelector('[class*="_lyricLine_"]')).mixBlendMode
# 应返回 "plus-lighter" 或 "color-burn"
```

---

## 实施优先级

1. **高优先级**: 修改 `FullscreenPlayerView.applyFullscreenLyricsTheme()` 添加 blend profile 发送
2. **中优先级**: 测试验证不同皮肤和亮度条件下的 blend mode
3. **低优先级**: 考虑添加 UI 设置让用户手动选择 blend profile（可选）