# OKLCH Color System Migration Log

本日志用于记录颜色系统重构与 OKLCH 迁移过程中的实际改动、验证结果、决策与后续接力点。\
设计文档：`docs/oklch-migration-color-system-investigation.md`（R1–R4 调查报告）。\
施工计划：`docs/oklch-color-system-execution-plan.md`。

每条记录至少给出：本阶段目标、改动文件清单、决策点、验证结果、对后续阶段的"接力提示"。

---

## Phase 0 — Pre-migration cleanup

**完成日期**：2026-05-19。

### 本阶段目标

把"无消费的契约"和"潜在 B 类 bug"一次性清掉，给 Phase 1（颜色 token 化 / OKLCH 数学层）让出干净的起点。**本阶段不引入新算法、不修改主视觉口径**。

详细执行表见 `oklch-color-system-execution-plan.md` §3。

### 0.1 ArtworkAssetStore 缓存版本号

**结果**：已修复。

**改动**：

- `Utilities/ArtworkColorExtractor.swift`：新增 `public nonisolated static let cacheVersion: String = "semantic-near-mono-v2"`，作为颜色提取算法版本的单一来源。
- `Models/ArtworkAssetSnapshot.swift`：实例 `cacheKey` getter 改为委派给新 `static func cacheKey(trackID:artworkChecksum:)`；后者在 key 前缀加入 `ArtworkColorExtractor.cacheVersion`。
- `Services/Artwork/ArtworkAssetStore.swift`：`get(trackID:artworkChecksum:)` 与 `getOrCreate` 内联 key 构造换成 `ArtworkAssetSnapshot.cacheKey(trackID:artworkChecksum:)`，保证两条读写路径走同一 key 模板。
- `Services/Theme/ThemeStore.swift`：删除私有实例常量 `colorExtractionCacheVersion`；`makeCacheKey` 直接读 `ArtworkColorExtractor.cacheVersion`。

**决策**：

- 选择"key 前缀方案"而非"snapshot 内嵌 cacheVersion 字段"路线。理由：内嵌字段需要每个读者主动校验、容易漏；前缀方案是单点修改，老 entry 在算法版本变更后自动落选，新 entry 在同版本下仍能正常 cache / hit。
- 把版本字符串落在 `ArtworkColorExtractor` 而不是 `ArtworkAssetSnapshot`：因为它语义上属于"提取算法版本"，对其它后续可能加入的提取派生 cache 也是同一个源头。

**风险评估**：

- 不引入新的 race。snapshot in-progress 合并仍按 key 字符串去重，前缀只是把 namespace 拓宽。
- `ThemeStore.dominantColorCache` 仍走自己已经版本化的 key 模板（identity-based，与 ArtworkAssetStore 的 trackID-based 不同 namespace），与本次改动正交。

### 0.2 歌词 Swift → Web 死字段清理

**结果**：已修复（端到端）。

**改动**：

- `Services/Theme/ThemeStore.swift`：从 `ThemePalette` 结构体删除 `accent: String` 与 `shadow: String` 字段；`refreshPalette` 不再计算 `accent` / `shadow` 两个本地 CSS 字符串；palette 签名不再包含它们；`Log.trace` "refreshPalette details" 日志去掉 `accent=` 字段。
- `Services/Lyrics/LyricsWebViewStore.swift`：`applyEffectiveTheme` 的 config 字典移除 `"shadowColor"` 键；CSS 注入 IIFE 删除 `--amll-bg` / `--amll-accent` / `--amll-shadow` 三条 setProperty。保留 `--amll-text` / `--amll-active` / `--amll-inactive`（仍是 live 契约）。
- `ViewModels/LyricsViewModel.swift`：surface config 字典移除 `"shadowColor": "rgba(0,0,0,0)"`（即使值是透明，作为字段名仍属同一死契约）。
- `Views/Fullscreen/FullscreenPlayerView.swift`：两个 `ThemePalette(...)` 构造点（`makeLyricsPalette` / `makeCoverBlurLyricsPalette`）删去 `accent` 与 `shadow` 参数。
- `Resources/AMLL/index.html`：删除 `if (hasOwn("shadowColor"))` 善后分支（在 Swift 不再发送该字段后永远不触发，注释已说明 A/B 1 测试结论）。

**端到端验证**（grep 残留）：

```
grep palette.accent | palette.shadow | palette?.accent | palette?.shadow
  → 无结果

grep var(--amll-shadow | var(--amll-bg | var(--amll-accent
  → 无结果

grep setProperty.*amll-shadow | setProperty.*amll-bg | setProperty.*amll-accent
  → 无结果

grep "shadowColor" 在 Swift / HTML / JS / CSS 活动资源
  → 仅剩 LyricsWebViewStore.swift 注释中说明本次清理的 "--amll-shadow"，以及
     BKArtBackgroundView.swift 一处 CALayer.shadowColor（CALayer 的属性名，与歌词死字段无关）
```

**决策**：

- 不动 `--amll-text` CSS 变量。`grep` 显示 `index.html` 没有 `var(--amll-text, ...)` 读者；但用户明确清理列表未含 `--amll-text`，且 `palette.text` 字段在 Swift 侧仍是活的（`ThemeStore.textColor` 给 SwiftUI 用、AMLL config 用 `palette.text` 作 `textColor`/`--amll-lp-color` 上游）。本轮严格按用户列表执行，避免误删。
- 不动 `palette.background` Swift 字段。`ThemeStore.backgroundColor` getter 仍被 `LyricsPanelView` 消费，是 live 字段。仅清掉 web 侧 `--amll-bg` 注入（无消费者）。
- 不动 `index.html` 中 `--amll-active` / `--amll-inactive` / `--amll-lp-color` 回退链（仍是渲染契约）。

**风险评估**：

- AMLL fork TypeScript 没有任何对死字段的硬依赖（事先 `grep amll-shadow|amll-bg|amll-accent` 命中数为 0）。`index.html` 的 `hasOwn("shadowColor")` 分支是 App adapter 层的善后代码，删除后行为不变（textShadow 在其它任何路径都未被设置过非 none 值）。
- 归回顾：本次符合 `docs/amll-custom-behavior-and-patch-registry.md` 推荐的"先尝试外层 / App adapter / CSS"修改优先级——本次只动 App adapter (`index.html`) 与 App 端 Swift，未触及 fork core。

### 0.3 MiniPlayerSpectrumView fallback 统一

**结果**：已修复。

**改动**：

- `Views/Fullscreen/MiniPlayerSpectrumView.swift`：`resolveStaticAccent` 改为 `@MainActor` 静态函数；fallback 来源切换为 `AppSettings.shared.accentColor`（默认 `#E6C799`，与 `accentColorHex` / `ThemeStore.defaultBlueNS` 同口径）。`NSColor(white: 0.7, alpha: 1.0)` 硬编码已删除。

**决策**：

- 显式传入 accent 的调用路径行为不变（`color` 非 nil 时优先使用传入色）。
- 没有新增 module-level 常量；复用 `AppSettings.shared.accentColor` 作为单一默认 accent 来源。
- 不复用 `ThemeStore.shared.defaultBlue`：`AppSettings.shared.accentColor` 是用户可调主题色的源头，`ThemeStore.defaultBlueNS` 是 ThemeStore 启动时拷贝的 fallback；两者初始值一致，但 `AppSettings.shared.accentColor` 跟随用户偏好。

### 0.4 ClassicLEDSkin 阴影深浅自适应

**结果**：已修复。

**改动**：

- `Skins/NowPlaying/ClassicLEDSkin.swift`：`ClassicCoverArtworkView.body` 内新增 `shadowOpacity` 局部变量，从 `context.theme.colorScheme` 派生（深色 0.35 保留原始厚重感；浅色降到 0.18）。`shadow(color: .black.opacity(0.35), ...)` 改为 `.black.opacity(shadowOpacity)`。

**决策**：

- 用 `context.theme.colorScheme` 而不是新增 `@Environment(\.colorScheme)`：与同文件 `PillSpectrumView` 不同，`ClassicCoverArtworkView` 已经持有 `SkinContext`，复用既有路径不引入第二条 colorScheme 来源。
- radius / x / y 一律保持原值，本轮**只**调 opacity。

### 0.5 FullscreenCoverGradientBlurSkin 占位 icon 自适应

**结果**：已修复。

**改动**：

- `Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift`：`CoverGradientBlurArtwork` 新增 `@Environment(\.colorScheme) private var colorScheme`；占位 `music.note` icon 的 `foregroundStyle` 从硬编码 `.white.opacity(0.5)` 改为新计算属性 `placeholderIconColor`（深色 `.white.opacity(0.5)`、浅色 `.primary.opacity(0.45)`）。

**决策**：

- 报告 C.4 将这一项写作 "FullscreenCoverGradient 箭头"，实际对应的是 placeholder 上的 `music.note` SF Symbol（无 artwork 时显示）。本轮**只**修这一处；用户标注的"箭头"含义即此处。
- 没有为这一处单独造可读性判定，沿用 SwiftUI 语义色 `.primary` 由系统决定前景。
- 不删除 `CoverGradientBlurArtwork` 私有视图。它是 dead code（`makeArtwork` 返回 `EmptyView()`），但 Phase 0 不做范围扩张；登记在"接力提示"里，留给 Phase 7 清理。

### 0.6 colorScheme 响应方式评估

**结果**：本轮**不动**，仅登记。

**结论**：`LedMeterView` 与 `MiniPlayerSpectrumView` 的 colorScheme 响应方式差异**是设计意图，不是 bug**。

- `LedMeterView` 直接 `@Environment(\.colorScheme)`：宿主视图（NowPlaying / 各 Skin）的背景是系统材质，颜色需要随系统 appearance 切换刷新——直接读 env 是正确选择。
- `MiniPlayerSpectrumView` 走父视图传 `usesDarkForeground: Bool`：在 fullscreen Clear miniPlayer 场景下，spectrum 落在 artwork blur 上方，正确的对比由 **artwork luma**（`themeStore.semanticPalette.analysis`）决定，而**不是**由系统 appearance 决定。父级 `FullscreenMiniPlayerView.usesDarkArtworkForegroundForClear` 正是这样计算的（不读 colorScheme，只读 analysis）。如果改成 `@Environment(\.colorScheme)`，反而会破坏"封面亮 → 用暗色频谱""封面暗 → 用亮色频谱"的现有判定。

因此两条路径**不应**强制统一。登记为后续架构一致性项，**不在本轮改动**。

**后续 Phase 4（"交互与可读性语义色"）的关注点**：当 Artwork Readability Profile 统一对外时，`MiniPlayerSpectrumView` 的 `usesDarkForeground: Bool` 参数应被替换成一个语义化的 `readabilityProfile` 输入；届时再统一两条路径的描述方式。

### 构建验证

```
xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player \
  -configuration Debug -destination 'platform=macOS' build
→ ** BUILD SUCCEEDED **
```

**死字段残留 grep**：全部 0 命中（仅剩本次清理的说明性注释）。

**视觉验证**：本轮**只完成代码级修复**。0.4 / 0.5 的视觉对比需在浅色 / 深色 / 多种 artwork luma 下手测确认；尚未做。

### 改动文件清单

```
docs/oklch-color-system-execution-plan.md                          (新增)
docs/oklch-color-system-migration-log.md                            (新增 — 本文件)

myPlayer2/Utilities/ArtworkColorExtractor.swift                     (0.1)
myPlayer2/Models/ArtworkAssetSnapshot.swift                         (0.1)
myPlayer2/Services/Artwork/ArtworkAssetStore.swift                  (0.1)

myPlayer2/Services/Theme/ThemeStore.swift                           (0.1 + 0.2)
myPlayer2/Services/Lyrics/LyricsWebViewStore.swift                  (0.2)
myPlayer2/ViewModels/LyricsViewModel.swift                          (0.2)
myPlayer2/Views/Fullscreen/FullscreenPlayerView.swift               (0.2)
myPlayer2/Resources/AMLL/index.html                                 (0.2)

myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift             (0.3)
myPlayer2/Skins/NowPlaying/ClassicLEDSkin.swift                     (0.4)
myPlayer2/Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift    (0.5)
```

### 接力提示（→ Phase 1）

1. **`ArtworkColorExtractor.cacheVersion` 命名约束**：未来任何对 `analyze` 或 palette 派生算法的非语义修改（例如重命名 helper、Unicode 标准化）**不**需要 bump 版本；只在算法输出**可能**变化时 bump。请在 Phase 2 升级决策引擎时同步 bump 这个常量。
2. **`CoverGradientBlurArtwork`（`FullscreenCoverGradientBlurSkin.swift`）目前是 dead code**（`makeArtwork` 返回 `EmptyView()`）。Phase 7 旧分叉清理时统一删除，本轮不动。
3. **`palette.text` 在歌词侧实际只剩 `textColor` JSON 路径在用**。Phase 5（"歌词颜色体系收敛"）建议进一步评估：是否把这条路径也下沉到 SemanticPalette 的歌词角色，让 LyricsWebViewStore 不再直接读 `ThemePalette`。
4. **`ThemeStore.backgroundColor` 仍由 `LyricsPanelView` 消费**：Phase 5 评估歌词面板背景策略时，可以一起考虑把 `palette.background` 也下沉。
5. **0.6 登记结论**：Phase 4 引入 Artwork Readability Profile 时，`MiniPlayerSpectrumView` 的 `usesDarkForeground` 应替换为语义化输入；那时再统一与 `LedMeterView` 的描述方式。

下一步：进入 Phase 1（颜色规则 token 化 + OKLCH 公共数学层）。
