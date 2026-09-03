# 代码重构计划

> 状态：**规划中，未开工**（2026-09-03 制定）。执行后请在文末进度表记录。
> 总原则：**先跑通，再加固**——每个阶段结束时 App 必须完整可用；所有拆分都是"纯移动 + 保持对外签名"，不引入新抽象框架，不为形式整洁重构。

## 1. 背景与目标

主源码约 428 个 Swift 文件 / 20.8 万行。整体健康状况良好：无 `try!`/`as!`、TODO 仅 5 处、Services 目录职责清晰、测试双轨完整（XCTest + 轻量脚本回归）。债务集中在**少数超大文件**和**一处规范违反**（裸 print）。

目标（按优先级）：

1. 消除规范违反：临时 print、疑似死代码（零功能风险，先做）
2. 为纯逻辑补测试保险网
3. 拆分两个重度上帝文件：`FullscreenPlayerView`（5788 行）、`LibraryViewModel`（3682 行）
4. 建立行数与分区约定，遏制再增长

非目标：

- 不重写主题/频谱/AMLL 适配层（有专门维护边界）
- 不做形式化分层（改目录名、换前缀之类）
- 不动自动生成数据文件
- 不改变任何运行时行为

## 2. 现状基线（2026-09-03）

| 指标 | 数值 |
| --- | --- |
| Swift 文件 | 428（Services 199 / Views 114 / Utilities 38 / Models 33 / Skins 16 / AppKit 8 / ViewModels 7 / Rendering 5 / Repositories 4） |
| 总行数 | ~208,000 |
| >1500 行文件 | 25 个 |
| 裸 `print(` | 116 处（其中 3 处属于 `Utilities/Log.swift` 日志封装本身，实际待清理 ~113 处） |
| TODO/FIXME/HACK | 5 处，全部在 `Services/Import/ImportMetadataExtractor.swift` |
| 强制解包 `)!`/`]!` | ~95 处（Top：ColorSystemSelfCheck 10、LRCConverterService 5、AMLLDBClient 3） |
| `try!` / `as!` | 0 |

行数 >2000 的源文件（SpectrumFrames 为自动生成数据，非代码债务）：

| 文件 | 行数 | 判定 |
| --- | --- | --- |
| `Models/SpectrumFrames.swift` | 9665 | 自动生成频谱数据，**不动** |
| `Views/Fullscreen/FullscreenPlayerView.swift` | 5788 | **重度上帝视图（P0）** |
| `Utilities/ColorSystemSelfCheck.swift` | 5286 | 自检诊断工具，仅分区不拆 |
| `Views/NowPlaying/BKArtBackgroundView.swift` | 4412 | 大型视图，按需分区 |
| `Views/NowPlaying/BKColorEngine.swift` | 3703 | 主题渲染链路，按需分区 |
| `ViewModels/LibraryViewModel.swift` | 3682 | **上帝 ViewModel（P0）** |
| `Services/ExternalPlayback/SystemNowPlayingProvider.swift` | 3654 | 次级，按需 |
| `Services/Lyrics/LyricsWebViewStore.swift` | 2811 | 次级，按需 |
| `Utilities/SemanticPalette.swift` | 2684 | 次级，按需 |
| `Services/Audio/AVAudioPlaybackService.swift` | 2515 | 次级，按需 |
| `Services/Library/LocalLibraryService.swift` | 2480 | 次级，按需 |
| `Repositories/SwiftDataLibraryRepository.swift` | 2282 | 次级，按需 |
| `Services/Import/ImportEnrichmentService.swift` | 2225 | 次级，按需 |
| `Views/Library/PlaylistPageController.swift` | 2196 | 次级，按需 |

## 3. 明确不动清单（执行任何阶段前先读）

- **`Models/SpectrumFrames.swift`**：自动生成数据（头部有 Auto-generated 标注），0 方法 0 状态，永远不拆。
- **`Utilities/ColorSystemSelfCheck.swift`**：自检诊断工具，只在诊断场景运行；最多补 MARK 分区，不做结构拆分。
- **主题/皮肤**：只经 `ThemeStore` / `SemanticPalette`；`BKColorEngine`、`BKArtBackgroundView` 只允许分区整理，不改行为。
- **AMLL**：适配层 → timing 预处理 → 公共 API 的顺序约束不变；`Resources/AMLL/` 生成文件不手改。
- **三条全屏路径**（系统全屏 / 窗口模拟全屏 / 主窗口内嵌）保持独立，拆分时不合并。
- **状态 owner 唯一**：队列 `PlayerViewModel`、颜色 `ThemeStore`、频谱 `LEDMeterServiceProvider` / `AudioAnalysisHub`、歌词 `LyricsSurfaceManager`——拆分不得产生第二 owner。
- **不恢复**：view-owned WebView、旧 `LyricsBridge.swift`、旧 exiting-line suppress、离散 highlight 系统。
- 工程是 Xcode 文件夹同步组：新文件放进对应目录即自动入 target，不改 project.pbxproj。

## 4. 诊断清单

### P0 上帝文件（必须拆）

**1. `Views/Fullscreen/FullscreenPlayerView.swift` — 5788 行**

| 区段 | 行范围 | 规模 | 内容 |
| --- | --- | --- | --- |
| 主 View `FullscreenPlayerView` | 18–5213 | ~5200 行 | 单个 SwiftUI View 独占全文 90% |
| `FullscreenMiniPlayerOcclusionRegion` | 5214–5326 | ~113 行 | MiniPlayer 遮挡区域计算 |
| `FullscreenTTMLTimingExtractor` | 5327–5417 | ~91 行 | TTML 时序提取 |
| `PanoramicArtworkVolumeScrollArea` | 5422–5675 | ~254 行 | NSViewRepresentable 滚动区 |
| Preview | 5676–5707 | ~32 行 | 预览 |
| AMLL layer-volatility 诊断 | 5708–5788 | ~81 行 | 诊断段 |

**2. `ViewModels/LibraryViewModel.swift` — 3682 行**

| 区段 | 行范围 | 规模 | 内容 |
| --- | --- | --- | --- |
| 文件头值类型 | 14–258 | ~245 行 | 8 个枚举（排序键/排序序/加载状态/选区）+ `LibrarySelection` extension |
| `LibraryViewModel` 主类 | 259 起 | — | @Observable，79 个方法 |
| ├ Published State | 265–536 | ~270 行 | 状态声明 |
| ├ Dependencies | 537–613 | ~77 行 | 依赖注入 |
| ├ Loading Task Management | 614–905 | ~290 行 | 加载任务生命周期 |
| ├ Computed Properties | 906–1125 | ~219 行 | 计算属性 |
| ├ Loading / Import | 1126–1476 | ~350 行 | 加载与导入 |
| ├ Playlist / Track Operations | 1477–1780 | ~304 行 | 播放列表与曲目操作 |
| ├ Artist/Album Entry Saves | 1809–2535 | ~726 行 | 条目写入（弱 UI 耦合，**最适合下沉**） |
| └ Sorting Helpers | 2646–3645 | ~1000 行 | 排序纯逻辑（**最适合下沉 + 补测试**） |

### P1 规范违反（先做，零风险）

- ~113 处裸 `print`（Top：`Services/Audio/SmartPlaybackController.swift` 31、`BatchTrackEditSheet.swift` 18、`FullscreenCoverGradientBlurSkin.swift` 13、`SpectrumRecorder.swift` 7、`PreferenceScorerV2Samples.swift` 6）→ 全部改用现有 `Log` 分类或删除
- `Services/Audio/PreferenceScorerV2Samples.swift`：全仓库唯一引用是自身，疑似死代码 → 确认后删除
- `ImportMetadataExtractor.swift` 的 5 处 TODO → 逐条处置（能修就修；暂不修的移入 issue 或 docs/PITFALLS.md，不在代码里过夜）

### P2 次级大文件（记录在案，不主动拆）

§2 表中"次级，按需"的文件：只在触碰其功能的任务里顺带做 MARK 分区核对，不单独立项。

### P3 目录与约定

- Services 一级目录已健康（最大 Audio 27 文件），**无需重排**。
- 缺一条行数约定：>300 行须 MARK 分区、>1500 行须有拆分评估（见 Phase 6）。

## 5. 分阶段执行

### Phase 0 · 基线（约半小时）

1. `git status` 确认 main 干净（本仓库常有并行会话，动手前必须确认没人干活）。
2. 增量 Debug Build + `kmgccc_playerTests` 全量，把结果记进文末进度表作为回归基线。

**验收**：基线数据可查。**风险**：无。

### Phase 1 · 零风险清理（一次提交）

1. 全局 grep 确认 `PreferenceScorerV2Samples.swift` 无外部引用后删除。
2. print → Log，按文件分批：SmartPlaybackController（31 处）→ BatchTrackEditSheet（18）→ FullscreenCoverGradientBlurSkin（13）→ SpectrumRecorder（7）→ 其余零散。用文件所属域的既有 Log category；纯调试输出直接删，有信息量的转 os_log。
3. 5 处 TODO 逐条处置。

**验收**：Debug Build 通过；`kmgccc_player/` 下 `print(` 仅剩 Log.swift 内部 3 处。
**风险**：极低。注意 UI 类文件里的 print 可能是调试状态展示，转 Log 时保留同等信息量。

### Phase 2 · 纯逻辑下沉 + 测试保险网（一次提交）

1. 从 LibraryViewModel.swift 文件头提取值类型（**纯移动，不改名**）：
   - `ViewModels/LibrarySorting.swift`：`TrackSortKey` / `TrackSortOrder` / `AlbumSortKey` / `ArtistSortKey` / `PlaylistSortKey` / `TrackEditPersistenceMode`
   - `ViewModels/LibrarySelection.swift`：`LibraryLoadState` / `LibraryLoadingPhase` / `LibrarySelection` + 其 extension
2. Sorting Helpers（~1000 行）提取为无状态纯函数集 `LibrarySortEngine`（命名执行时定）：输入输出全是值类型，不碰 @Observable 状态。
3. 为 `LibrarySortEngine` 补 XCTest：排序稳定性、多键组合、本地化/大小写行为、空集合边界。

**验收**：Build + 新增测试通过；`LibraryViewModel` 对外 API 零变化。
**风险**：低——纯移动 + 纯函数。这一步是 Phase 3 拆分的保险网。

### Phase 3 · LibraryViewModel 拆分（2–4 个提交）

目标结构（`LibraryViewModel` 仍是唯一状态 owner，符合架构约束）：

```
ViewModels/
├── LibraryViewModel.swift          # @Observable 状态 + 依赖注入 + 对外 facade（目标 <1000 行）
├── LibrarySorting.swift            # Phase 2 已出
├── LibrarySelection.swift          # Phase 2 已出
├── LibraryLoadCoordinator.swift    # Loading Task Management + Loading（~440 行）
├── LibraryEntryStore.swift         # Artist/Album Entry Saves（~726 行）
└── LibrarySortEngine.swift         # Phase 2 已出
```

迁移方法（每步独立可构建、单独提交）：

1. 先移 Loading Task Management → `LibraryLoadCoordinator`：`LibraryViewModel` 内改为委托调用，**对外方法签名不变**。
2. 再移 Artist/Album Entry Saves → `LibraryEntryStore`。
3. Display/Private Helpers 就近内联或留在 facade，不强求搬空。
4. Playlist / Track Operations 保留在 facade（与状态耦合最紧）。

**红线**：禁止把 @Observable 状态拆到多个类再手动同步；只下沉无状态逻辑与可整体移交的任务域。

**验收**：每步 Debug Build + XCTest 全量；人工 smoke 资料库真实路径（导入、播放列表增删、排序切换、批量编辑）。
**风险**：中——加载任务与状态互引较多，必须小步走；出现行为差异立即回退该步。

### Phase 4 · FullscreenPlayerView 拆分（3–5 个提交）

第一步先把无依赖的尾部类型移出（纯移动）：

```
Views/Fullscreen/
├── FullscreenPlayerView.swift              # 主 View（目标 <1500 行）
├── FullscreenMiniPlayerOcclusion.swift     # OcclusionRegion（~113 行）
├── FullscreenTTMLTimingExtractor.swift     # TTML 时序提取（~91 行）
├── PanoramicArtworkVolumeScrollArea.swift  # NSViewRepresentable（~254 行）
└── FullscreenLayerDiagnostics.swift        # AMLL layer-volatility 诊断（~81 行）
```

第二步处理主 View 内部（~5200 行）：先盘点现有 MARK/子区域（控制条、歌词层、封面区、过渡协调等），按子区域抽成同文件 private 子 View（编译稳定后再挪文件）；**每抽一个子区域提交一次**。

**红线**：歌词层只搬视图代码，不碰 `LyricsSurfaceManager` 的 surface 状态管理；三条全屏路径不合并；不顺手"优化"任何动画时序。

**验收**：每步 Debug Build；全屏人工 smoke（进出系统全屏、窗口模拟全屏、歌词切换、MiniPlayer 遮挡联动）；UI 交付附改动前后截图/录屏对比。
**风险**：中高——大 View 的 body 依赖大量 @Observable 状态，抽子 View 时逐个核对状态传递；纯移动优先。

### Phase 5 · 次级大文件（按需，不排期）

只在触碰某文件的功能任务时顺带做 MARK 分区核对；不单独立项、不主动发起。主题链路文件（BKArtBackgroundView、BKColorEngine）改动列入人工检查路径。

### Phase 6 · 约定固化（文档提交）

- 「>300 行须 MARK 分区；>1500 行须给出拆分评估」写入 AGENTS.md / CONTRIBUTING.md。
- `docs/README.md` 保持本计划链接；每完成一个 Phase 更新文末进度表。

## 6. 执行规则

- **每阶段（或每迁移步）一个提交**；提交前 `git status` 确认没有并行会话的未提交改动混入。
- 动手前重读 §3「明确不动清单」。
- 验证 = 与改动匹配的增量 Debug Build + 相关 XCTest；**不默认跑 Release/全量 smoke**。
- 涉及全屏/歌词/主题/播放来源的阶段，交付时列出已验证、未验证和建议人工检查的路径。
- 任何一步出现行为差异：回退该步，定位根因后再动，不带病前进。
- 不新建长期分支（防并行改动落错分支）；先跑通，再加固——加固永远服务于功能。

## 7. 进度记录

| 日期 | 阶段 | 结果 |
| --- | --- | --- |
| 2026-09-03 | — | 计划制定（基于当月代码健康抽查），未开工 |
