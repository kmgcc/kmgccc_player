# 本地音乐资料库阶段 0-1 入口审计

本文记录阶段 0-1 已收敛的用户入口和生命周期边界。它不是新的运行时配置；后续阶段修改导入、来源或领域模型时，应先更新这里的 command/service 链路，再改 UI。

## 入口审计

| 用户入口 | command / owner | service 与持久化边界 | 预期 UI 结果 |
| --- | --- | --- | --- |
| 设置 → 新建资料库 | `LibrarySetupFlow.createLibrary` | `AppSessionHost.createMusicLibrary` → `LibraryCreationService` → manifest、scoped settings、registry、`LibrarySessionController` | 位置未明确选择时按钮不可用；创建完成后向导关闭，资料库立即成为当前资料库 |
| 设置 → 打开资料库 | `MusicSettingsView.openLibraryPanel` | `AppSessionHost.openMusicLibrary` → `LibraryOpenService` → registry + session activation | 成功关闭向导；原位来源不可达时进入真实的来源重连流程 |
| 选择位置后发现已有资料库 | `LibrarySetupFlow.setupContent` | `LibraryCreationService.inspect`，不覆盖已有 manifest | 显示已有资料库的完整路径；可打开，或重新选择其他位置 |
| 选择位置后发现未知内容 | `LibrarySetupFlow.creationFailureMessage` | `LibraryCreationService.destinationContainsUnknownItems`，不删除未知内容 | 显示具体冲突路径，要求换位置或清理后重试 |
| 资料库行 → 打开 | `MusicSettingsView.open` | `activateRegisteredLibrary` → `LibraryStartupContextResolver` → session switch | 切换期间旧任务被 quiesce；目标不可达时进入真实重连流程 |
| 资料库行 → 移到废纸篓 | `MusicSettingsView.removePendingLibrary` | `LibraryRemovalService` → repair intent、registry、session successor/default policy | 优先切到其他可达资料库；没有可达资料库时保证创建并激活默认空库 |
| 原位来源 → 重新扫描 | `MusicSettingsView.refreshSources` | 当前 `LibrarySession.refreshReferencedSources` → source reconciler / change monitor | 只扫描当前原位来源集合，不伪装成资料库 UI reload |
| 数据 → 清除索引缓存 | `LibraryViewModel.clearIndexCacheAndRebuild` | repository index cache → `refresh()` | 清缓存后重建索引并刷新歌曲、艺人、专辑列表，不删除文件或播放列表 |
| 失效歌曲 | `MusicSettingsView.missingTracksSection` | 只读 `Track.availability` 展示 | 缺失、离线、权限失效保留在资料库中；不再提供混合删除入口 |

## 生命周期协议

- setup panel 的窗口关闭由 `LibrarySetupPanelController` 统一完成；`windowShouldClose`、按钮关闭和 SwiftUI 消失路径都落到幂等的 `finishClosing`。
- `LibrarySetupViewModel` 用 operation generation 使关闭/重新展示后的旧异步回调失效；旧回调不能把失败状态写回新向导。
- 创建资料库只等待短生命周期事务；向导使用 `.background` 初始导入策略。每个 `LibrarySession` 自己持有 `LibraryOperationCoordinator`，初始导入、用户导入、来源扫描/重连与其安全范围都由它登记，切换 session 前先取消并等待该资料库的任务。
- `LibrarySession.quiesce()` 统一停止监听、串行任务、补全和播放侧工作；不得再从 UI 直接创建绕过 session owner 的资料库写任务。
- 正常空资料库由 HomeView 显示“没有歌曲待导入”；“正在准备音乐资料库”只用于启动恢复尚未完成的短暂状态。

## 阶段 0-1 验收基线

手动验收必须使用临时父目录，不使用用户真实资料库。每轮开始前保存 registry、父目录内容和当前 branch/HEAD；结束后删除临时目录。

| 场景 | 最低证据 |
| --- | --- |
| 托管库基线 | 创建、打开、导入一首可播放歌曲、删除后文件/registry 结果符合既有行为 |
| 原位库基线 | 创建、打开、来源扫描、播放列表来源、NCM 混合目录的现有结果被记录，不把本阶段误标为 NCM 修复 |
| 生命周期 | 创建后立即关闭向导；关闭/取消时无残留 panel；切库时旧资料库任务不改变新资料库 |
| 兜底 | 删除唯一可达库、启动时 active 指向失效库、默认目录不存在或被未知内容占用，最终均有可激活的空资料库或明确的恢复动作 |
| 入口 | 设置中不存在“更改位置”、资料库级假“重新扫描”、混删离线/权限歌曲和无行为的重连按钮 |

当前可复现的自动化覆盖包括 `MusicSettingsStateTests`、`LibraryLifecycleTransactionTests` 和 `LibraryInitialImportIntegrationTests`；真正的 Finder/Dock/面板视觉行为仍需在隔离临时目录中由维护者手动确认。
