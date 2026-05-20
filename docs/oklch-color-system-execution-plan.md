# OKLCH 颜色系统重构 — 总执行计划

> 本文档是 `docs/oklch-migration-color-system-investigation.md`（R1–R4 最终调查报告）的施工面落地版本。\
> 报告负责"为什么"和"现状如何"；本文件只负责"按什么顺序施工 / 每一步的边界 / 验收标准"。\
> 真实改动日志请记到 `docs/oklch-color-system-migration-log.md`。

---

## 1. 总体目标

调查阶段（R1–R4）已经把当前基于 HSL/RGB 的颜色系统逆向建模清楚。这一轮颜色系统升级要在不一次性 OKLCH 大迁移的前提下逐步推进，原则如下：

1. **先清理历史遗留与死字段。** 把没有消费者的契约删干净；把已经被新算法替代但还留有读路径的字段一次性收掉。**这一步本身不引入新算法、不变 UI 行为**。
2. **再建立颜色规则的 token 化基础与 OKLCH 公共数学层。** 这一步是迁移的"语言层"——所有后续阶段都依赖一个统一的颜色 token / 颜色空间转换层。
3. **再升级艺术取色决策引擎到 2.0。** 把当前散落在 `SemanticPaletteFactory` 中的 5+ 个 OR 分支重新拆成正交维度（Ultra Dark / Near Monochrome 等），并新增小面积高显著色 / 多色 palette 的结构化输出。
4. **再把装饰色与真正多色分发铺出去。** Home Shapes / BKArt / Spectrum 真正利用 artwork 多色，而不是单一 accent 渐变。
5. **再做交互可读性语义色。** MiniPlayer 控件色彻底语义化；Artwork Readability Profile 统一对外。
6. **再收敛歌词颜色体系。** Swift 侧颜色决策集中、不同 fullscreen skin 分策略、glow / layer 层级整理。
7. **最后做 Tone Ladder 与 LED / 歌词层级深化、清理旧 HSL 分叉、文档收尾与回归验证。**

每一阶段都要做到：

- 不为下一阶段"提前埋头"，保持每一步可以独立合并；
- 不在阶段边界以外重排 UI 视觉口径；
- 每一阶段完成后更新 `docs/oklch-color-system-migration-log.md`。

---

## 2. 阶段划分

### Phase 0 — 前置清理与迁移基础设施 ← **本轮**

目标：把"无消费的契约"和"潜在 B 类小 bug"一次性清掉。**不改算法、不改主视觉口径**。本阶段详情见 §3。

### Phase 1 — 颜色规则 token 化 / OKLCH 公共数学层

目标：

- 建立 OKLCH ↔ RGB / HSL 之间的公共数学层（`ColorMath` 的对偶层），按报告 K.3 / Appendix B 的方向铺路。
- 把分散在各处的"颜色 magic number"（accent 明度下限、近黑白阈值、对比目标等）整理成 token 化常量，集中在一处。
- **本阶段不切换任何 UI 颜色输出**：实现层加入 OKLCH 数学能力，但仍由现有 HSL 路径产生最终颜色。

退出条件：所有现有颜色决策都能以"等价 OKLCH 表达"被复述，并通过单元级数学对照（HSL 与 OKLCH 之间的等价转换）。

### Phase 2 — 艺术取色决策引擎 2.0

目标（对应报告 J / K 部分）：

- **Ultra Dark 与 Near Monochrome 分离**：把"明度低"和"色相不可信"作为两个正交维度独立判定（R4 J.2.d / K.2）。
- **小面积高显著色结构化输出**：在 `ArtworkColorAnalysis` 中新增 salient highlight palette（R4 J.1）。
- **多色 artwork palette 的基础能力**：把 topPalette / richPalette 重新组织成可被 UI 直接消费的多色 token。
- 收敛 `isEffectivelyMonochrome` 5 个 OR 分支，明确每条分支的物理含义；移除分支 4 的明度耦合（R4 J.2.c L#2b）。

退出条件：相同 artwork 输入下，旧引擎与新引擎的输出在"主流封面"上视觉一致；关键边界用例（极暗有色、近灰阶、纯黑、霓虹）行为符合 K.2 的四象限决策表。

### Phase 3 — 装饰色与真实多色分发

- Home Shapes：使用 artwork 多色而非单 accent 渐变。
- BKArt：保留 Ultra Dark 保护，但启用真正多色背景。
- Spectrum：使用 artwork 两色或多色填充，而不是 fallback 灰。

退出条件：在监听同一封面时，Home Shapes / BKArt / Spectrum 三处的颜色分布肉眼一致且能反映 artwork 多色性。

### Phase 4 — 交互与可读性语义色

- **MiniPlayer 控件色语义化**：去掉对 `themeStore.accentColor` 的硬读，改读 `controlPrimaryColor` / `controlSecondaryColor` 等显式角色。
- **Artwork Readability Profile**：把"在 artwork 上叠字"的可读性策略（`readableTextOnArtwork` / `usesDarkForeground`）统一到一处。
- **【接力自 Phase 3 回修】近黑白 artwork 下 Fullscreen MiniPlayer UI 不应出现淡蓝 / 淡黄 / 可感知伪 hue**。当前 `FullscreenMiniPlayerView.controlPrimaryNSColor` / `shouldUseDarkArtworkForeground` 仍从原 SemanticPalette accent / averageColor 推导，未走 nearMono 中性化通道。Phase 4 新增的 `MiniPlayerControlPalette` 必须在 `analysis.isNearMonochrome == true` 时强制把 UI 主色归到 OKLCH 中性轴（chroma ≈ 0），仅靠 L 区分。**验收**：纯灰封面下 UI 颜色 `chroma < 0.005` 且 `circularHueDistance < 0.01`（或直接降级到 system label color）。参见 `oklch-color-system-migration-log.md` §3.12 Issue A。

退出条件：同一 artwork 下，Home Hero / Library Header / Fullscreen Cover Gradient 三处的可读性策略一致；且近黑白封面下 Fullscreen MiniPlayer UI 不再出现伪 hue。

### Phase 5 — 歌词颜色体系收敛

- **Swift 侧歌词颜色决策集中**：把 `windowLyricActive` / `windowLyricInactive` / `fullscreenLyricBase` / `fullscreenLyricInactiveBase` 的决策路径正式整合到 `SemanticPalette`，减少 ThemeStore 与 LyricsWebViewStore 双写。
- **不同 fullscreen skin 分策略**：cover gradient blur 与其他 skin 在歌词色策略上的差异显式化。
- **glow / layer 策略整理**：halo / shadow / mix-blend-mode 这些 layer 从混杂的 CSS var 改为明确的语义层。
- **【接力自 Phase 3 回修】近黑白 artwork 下窗口 / 全屏歌词不应偏粉**。Phase 5 集中决策时，**near-mono 中性化作为显式规则**进入统一函数：`analysis.isNearMonochrome == true` → 歌词所有可见色 OKLCH `chroma ≤ 0.005`，仅靠 L 与 alpha 体现层级。**两端同步验收**：窗口歌词与全屏歌词必须同一决策函数生效，避免单端修复造成视觉割裂。参见 `oklch-color-system-migration-log.md` §3.12 Issue B。

退出条件：歌词颜色完全由 Swift 决策，CSS 层只剩"渲染"角色，无颜色决策残留；且近黑白封面下窗口 / 全屏歌词都不再偏粉。

### Phase 6 — Tone Ladder 与 LED / 艺术歌词层级深化

- Tone Ladder 正式作为系统级颜色派生方法。
- LED Meter 不再"按 brightness levels 切分"而是按 Tone Ladder 取等距点。
- 艺术歌词分层（前景 / 高光 / 阴影）按 Tone Ladder 重排。

退出条件：LED / 歌词的明度层级在 OKLCH 空间下是等距的，而不是当前 HSB 下肉眼接近等距的近似。

### Phase 7 — 清理旧 HSL 分叉、文档收尾、回归验证

- 删除 HSL 分叉路径；保留 `ColorMath` 但只剩 OKLCH。
- 关闭所有 fallback / 兼容 shim。
- 对照报告 J / K / Appendix A 的"原始事实快照"做一次最终回归。

退出条件：搜索"`.usingColorSpace(.deviceRGB)` + 手算 HSL"应只剩调试 / 日志路径；UI 路径全部通过 OKLCH token。

---

## 3. Phase 0 详细执行表

本阶段的边界规则（**全部都要遵守**）：

- 不开始 OKLCH 主迁移；
- 不调整 `SemanticPaletteFactory` 的审美 magic numbers；
- 不修改 Ultra Dark / Near Monochrome 判定逻辑；
- 不实现 salient highlight palette；
- 不改 Home Shapes / BKArt / Spectrum 的真实多色方案；
- 不改 MiniPlayer 控件色语义化；
- 不改歌词颜色策略；
- 不改 Header 路径瘦身；
- 不做 Tone Ladder。

只做：**文档准备 + 前置清理 + 已确认遗留修复**。

### 0.1 修复 `ArtworkAssetStore` 缓存版本号漏洞

| 字段       | 内容                                                                                                                                                                                                                                                                                                                                                            |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题       | `ArtworkAssetStore` 的 in-memory snapshot 缓存 key 是 `"\(trackID.uuidString)-\(artworkChecksum)"`，**不包含颜色提取算法版本号**。`ThemeStore` 自己的 `dominantColorCache` 已经按 `colorExtractionCacheVersion` 命名，但走 `ArtworkAssetStore` 的路径绕过了这道防线。当颜色算法升级时（比如这次 R4 之后任何一次对 `analyze` 的修改），旧 snapshot 中的 `accentColor` / `dominantColor` / `palette` / `averageColor` 仍会被新逻辑读取。 |
| 根因       | `ArtworkAssetSnapshot.cacheKey`（`Models/ArtworkAssetSnapshot.swift:24`）以及 `ArtworkAssetStore.get(trackID:artworkChecksum:)` 的 key 都没把算法版本绑进 key 域。                                                                                                                                                                                                            |
| 修复目标     | 让 `colorExtractionCacheVersion` 成为 snapshot 缓存命中条件的一部分。算法版本一变，旧 snapshot 自动失效，**新 snapshot 仍能写入并复用**。                                                                                                                                                                                                                                                       |
| 预计涉及文件   | `myPlayer2/Models/ArtworkAssetSnapshot.swift`、`myPlayer2/Services/Artwork/ArtworkAssetStore.swift`、`myPlayer2/Services/Theme/ThemeStore.swift`（共享版本号常量）。                                                                                                                                                                                                       |
| 非目标      | 不重构 `ArtworkAssetStore` 的 actor 结构；不引入持久化缓存；不动 `LibraryDetailHeaderView` / `HomeHero` 各自的本地缓存键。                                                                                                                                                                                                                                                            |
| 验收标准     | (1) 算法版本字符串变更后，`get(trackID:artworkChecksum:)` 无法命中旧 entry；(2) 同版本下新 entry 仍能正常 cache / hit；(3) 不引入额外的 race（in-progress 合并仍工作）；(4) 不破坏现有异步取色 / hydration 路径。                                                                                                                                                                                            |
| 实现选择（备注） | 把 `colorExtractionCacheVersion` 抽到一个 module-level 静态常量（或 `ArtworkColorExtractor` 的 nonisolated static），然后在 `ArtworkAssetSnapshot.cacheKey` 上拼接前缀。理由：单点修改、所有 cache 自动跟随、零额外字段开销。**不**选"snapshot 内嵌 cacheVersion 字段"路线，那个方案要求每个 reader 主动校验，容易漏。                                                                                                            |

### 0.2 清理歌词 Swift → Web 颜色死字段

| 字段     | 内容                                                                                                                                                                                                                                                                                                                                |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | 报告 R3 J.1 / R4 J.1.c 已确认：CSS 变量 `--amll-bg` / `--amll-accent` / `--amll-shadow` 在 `index.html`、`style.css`、`amll-core.js`、`amll-lyric.js`、`lyrics-renderer.js` 里**全部 0 消费**。`config.shadowColor` JSON 字段是经 A/B 测试明确弃用（`index.html:5383-5392` 只剩 `textShadow = "none"` 的善后分支）。`ThemePalette.shadow` 与 `ThemePalette.accent` 字段在 Swift 侧除"把它写给 web"以外无任何消费者。 |
| 根因     | 历史上歌词 web 层还有完整的"主题色"契约；新版 AMLL 渲染器改用 `--amll-active` / `--amll-inactive` / `--amll-lp-color` 后，旧契约一直没清。                                                                                                                                                                                                                          |
| 修复目标   | 把"无人消费 / 已弃用"字段彻底从类型 → 序列化 → JS 注入三层移除：① `ThemePalette.shadow` 字段；② `ThemePalette.accent` 字段；③ `applyEffectiveTheme` 中的 `--amll-bg` / `--amll-accent` / `--amll-shadow` CSS 注入；④ `config.shadowColor` JSON 字段；⑤ `index.html` 中 `hasOwn("shadowColor")` 善后分支（在 4 完成后永远不会触发）。                                                          |
| 预计涉及文件 | `myPlayer2/Services/Theme/ThemeStore.swift`、`myPlayer2/Services/Lyrics/LyricsWebViewStore.swift`、`myPlayer2/Resources/AMLL/index.html`。                                                                                                                                                                                            |
| 非目标    | 不动 `--amll-active` / `--amll-inactive` / `--amll-lp-color`（仍是 live 契约）；不动 `--amll-text` CSS 变量（虽然当前 0 消费，但不在用户明确清理列表里，留给后续阶段评估）；不动 `palette.background` Swift 字段（被 `ThemeStore.backgroundColor` → `LyricsPanelView` 消费）；不改歌词实际视觉。                                                                                                  |
| 验收标准   | (1) 项目内搜索 `ThemePalette.shadow` / `palette.shadow` / `palette.accent` / `palette?.accent` / `palette?.shadow` 应无残留；(2) 项目内搜索 `--amll-shadow` / `--amll-bg` / `--amll-accent` 应无残留（除已注释的死代码或.bak2 备份）；(3) `index.html` 内 `hasOwn("shadowColor")` 分支已移除；(4) 构建通过；(5) 歌词主面板与全屏歌词的 active / inactive 颜色保持不变。                          |

### 0.3 统一 `MiniPlayerSpectrumView` fallback

| 字段     | 内容                                                                                                                                                                                                                                                                                                              |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | `MiniPlayerSpectrumView.resolveStaticAccent` 在 `accentColor == nil` 或无法转 RGB 时降到 `NSColor(white: 0.7, alpha: 1.0)`，与全局默认 accent `#E6C799`（`AppSettings.shared.accentColorHex` / `ThemeStore.defaultBlueNS`）口径不一致。                                                                                            |
| 根因     | 局部硬编码，没复用项目已有的默认 accent。                                                                                                                                                                                                                                                                                       |
| 修复目标   | fallback 改读项目级默认 accent（来源优先级 `ThemeStore.shared.defaultBlue` → `AppSettings.shared.accentColor`），避免再造第三套常量。                                                                                                                                                                                                  |
| 预计涉及文件 | `myPlayer2/Views/Fullscreen/MiniPlayerSpectrumView.swift`。                                                                                                                                                                                                                                                      |
| 非目标    | 不改 `resolveArtworkFaithfulColors` 内部的 tuning；不改 `adjustedSpectrumBase` 的 saturation / brightness 曲线；不改正常路径下从父视图传入 accent 的行为。                                                                                                                                                                                   |
| 验收标准   | (1) 显式传入 accent 的路径保持原本行为；(2) 不传 accent / accent 无法转 RGB 时，spectrum 颜色基线为 `#E6C799` 而非中性灰；(3) 不引入新的 module-level 常量。                                                                                                                                                                                            |

### 0.4 修复 `ClassicLEDSkin` 固定黑阴影

| 字段     | 内容                                                                                                                                                                                                                                                                  |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | 报告 C.4 "B 类潜在 bug"：`ClassicLEDSkin` 的封面阴影固定 `Color.black.opacity(0.35)`，浅色模式下偏重。                                                                                                                                                                                       |
| 根因     | `.shadow(color: .black.opacity(0.35), radius: 20, x: 0, y: 10)`（`ClassicLEDSkin.swift:92`）不分支深浅模式。                                                                                                                                                                    |
| 修复目标   | 阴影 opacity 按 `colorScheme` 分支：暗色保留 0.35（原始厚重感），浅色下沉到 0.18，避免在浅色封面下压抑过头。                                                                                                                                                                                                |
| 预计涉及文件 | `myPlayer2/Skins/NowPlaying/ClassicLEDSkin.swift`。                                                                                                                                                                                                                    |
| 非目标    | 不扩展成 LED 整体视觉重设；不动 radius / offset / 内部 `PillSpectrumView`；不引入按 artwork 派生的阴影色。                                                                                                                                                                                        |
| 验收标准   | (1) 暗色模式阴影视觉与现状一致；(2) 浅色模式阴影明显减弱；(3) 仅修改阴影 opacity，不改其它参数。                                                                                                                                                                                                              |

### 0.5 修复 `FullscreenCoverGradientBlurSkin` 占位 icon 固定白色

| 字段     | 内容                                                                                                                                                                                                                                                                                                                                                                                |
| ------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | 报告 C.4 "B 类潜在 bug" 标注 "FullscreenCoverGradient 箭头 `Color.white.opacity(0.5)`"。实际实现位于 `FullscreenCoverGradientBlurSkin.swift:186` 的 `CoverGradientBlurArtwork` 私有占位视图：当 `context.track?.artworkImage` 为 nil 时，绘制一个 `music.note` 占位 icon，固定 `.white.opacity(0.5)`。在浅色背景或亮 cover 下可读性不稳。 |
| 根因     | 固定白色，不响应当前 `colorScheme` 或 artwork 可读性判定。                                                                                                                                                                                                                                                                                                                                          |
| 修复目标   | icon 颜色改为跟随 `@Environment(\.colorScheme)`：暗色下保留白半透明，浅色下用 `.primary.opacity(0.45)`。复用 SwiftUI 现成的语义色，不为这一处单独造一个可读性判定。                                                                                                                                                                                                                                                              |
| 预计涉及文件 | `myPlayer2/Skins/NowPlaying/FullscreenCoverGradientBlurSkin.swift`。                                                                                                                                                                                                                                                                                                               |
| 非目标    | 不改 `CoverGradientBlurArtwork` 的 placeholder gradient / shadow / overlay 描边；不动 `makeArtwork` 返回 `EmptyView()` 的事实（这意味着 `CoverGradientBlurArtwork` 当前其实是 dead code，但该结论应交给后续 Phase 7 清理时再处理，本轮不删活路径之外的"似死非死"代码）。                                                                                                                                                                       |
| 验收标准   | (1) 暗色模式占位 icon 视觉与现状一致；(2) 浅色模式占位 icon 不再是高对比白；(3) 编译通过。                                                                                                                                                                                                                                                                                                                            |

### 0.6 评估但**不**强制扩大：`MiniPlayerSpectrumView` 与 `LedMeterView` 的 colorScheme 响应方式

| 字段     | 内容                                                                                                                                                                                                                                  |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 问题     | `LedMeterView` 直接 `@Environment(\.colorScheme)`；`MiniPlayerSpectrumView` 走父视图传 `usesDarkForeground: Bool`。两条路径风格不一致。                                                                                                                |
| 评估目标   | 判断是否有真实刷新遗漏。如果没有 → 本轮**不动**，只在 migration log 中登记为"后续架构一致性项"。                                                                                                                                                                       |
| 验收     | 在 migration log 中给出结论。如果决定本轮改，仍要尊重边界（不破坏调用方传 accent 的路径）。                                                                                                                                                                          |

---

## 4. 退出 Phase 0 的条件

- 上述 0.1–0.5 全部完成；0.6 已经给出书面结论。
- `xcodebuild -project kmgccc_player.xcodeproj -scheme kmgccc_player -configuration Debug build` 通过。
- 项目内不再有死字段引用（0.2 验收项 1–3）。
- `docs/oklch-color-system-migration-log.md` 已写入 Phase 0 的完整记录。
- 工作树没有计划外的修改散落。

下一步：进入 Phase 1（颜色规则 token 化 + OKLCH 公共数学层）。
