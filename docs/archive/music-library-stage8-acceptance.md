# 阶段 8：本地增强与验收记录

本文记录阶段 8 已落地的可维护基础、明确没有伪造的能力，以及当前环境下尚未完成的真实验收。阶段 8 继续遵守本地优先边界：不引入 MCP、Navidrome、云端 catalog 或远程同步。

## 本阶段落地

### 1. 可重建的资料库诊断投影

`LibraryDiagnosticsAnalyzer` 只接收不可变的歌曲快照，不拥有 Track，也不写入权威 sidecar。它提供：

- 总歌曲数、可播放数、总时长；
- 文件丢失、来源离线、权限失效和检查中的分组；
- 格式数量统计；
- 相同物理文件候选和歌曲信息高度相同候选。

`LibraryViewModel` 在歌曲快照变化后取消旧计算，把诊断计算放到 utility 任务，并用加载 generation 防止旧资料库结果写进新 Session。设置中的重复审查是只读的，只提供 Finder 定位，不自动删除 Track 或外部文件。

重复判断分层：稳定文件系统身份优先；没有稳定身份时只产生保守的路径级 fingerprint 候选；标题、艺人、专辑和时长只作为“可能重复”提示，不能直接合并或删除。

### 2. 原位来源的排除目录

原位目录来源 schema 从 2 升为 3，新增 `excludedRelativePaths`。旧 schema 1/2 读取时保留原绑定并原子升级；非法相对路径会明确失败，不静默吞掉。

排除目录的职责链是：

```text
文件夹视图
  → AppSessionHost
  → LibrarySession
  → ReferencedSourceReconciler
  → ReferencedSourceStore（持久化策略）
  → ReferencedSourceScanner（扫描过滤）
  → immutable diff / reconcile
```

排除是非破坏性策略：外部文件不删除，Track 身份和历史不被直接清除；扫描会移除该来源对位置的声明，使无其他位置的歌曲进入 `missing` 状态；取消排除后，物理身份复用原 Track 并恢复可播放状态。已排除的空目录仍在文件夹视图显示，便于恢复。

### 3. 搜索字段与排序边界

搜索索引新增可组合字段和排序 API：

- 标题、艺人/参与艺人、Album Artist、专辑、路径、格式和歌词；
- relevance、标题、艺人、专辑和最新更新排序；
- 继续保留 FTS5、n-gram 候选召回和现有歌词时间信息。

SQLite 使用增量 `ALTER TABLE` 迁移，旧索引下次资料库 reload 会由 repository 重新建立，不要求用户手动删除资料库。字段过滤和排序属于 `LibrarySearchIndex`/`LibraryViewModel` 查询边界，页面可以逐步接入，不在 UI 中复制第二套搜索逻辑。

### 4. 批量编辑写回状态

批量编辑仍复用现有 `LibraryViewModel → LibraryRepositoryProtocol → LocalLibraryService` 写回链路。本阶段修复其生命周期语义：只有 repository 返回成功后才标记歌曲为已保存；写盘期间禁止切换同一编辑任务；失败会保留未完成状态并提示重试；写回失败不再发出“辅助数据已改变”的假通知。

## 代表性行为

### 重复候选

- 同一个 referenced 文件因路径或来源重复出现：如果有稳定文件身份，显示“同一个文件被重复记录”；
- 两个不同录音拥有相同标题、艺人、专辑和近似时长：显示“歌曲信息高度相同”，但不自动合并；
- 无稳定文件身份且只有相同大小/时间：只按保守路径候选展示，用户仍可在 Finder 中核对。

### 排除与恢复

- 在原位文件夹视图中对 `Live` 执行“排除此文件夹”：`Live` 下文件停止进入自动扫描结果，外部文件不移动、不删除；
- 若歌曲只有这个来源位置，歌曲进入设置中的文件丢失/失效状态，而不是被静默删除；
- 对 `Live` 执行“取消排除文件夹”并重新扫描：原物理文件复用原 Track UUID，恢复可播放和来源关系；
- 删除一个播放列表不会删除来源排除策略，也不会在下一次扫描中重建播放列表。

### 搜索

- 查询 `flac` 且字段为“格式”：只匹配格式字段，不因歌曲标题或歌词包含同样文字而命中；
- 查询 `Second Song.mp3` 且字段为“路径”：匹配原始路径字段；
- 同一搜索结果切换“最新”排序时只改变查询投影顺序，不改变播放列表持久顺序。

### 批量编辑

- 修改歌曲后点击保存：窗口显示保存中，repository 成功后才显示已保存；
- sidecar/资源写入失败：歌曲仍是未完成状态，显示失败并允许重试；
- 保存期间点击下一首或切换队列项：操作被阻止，不会让后一个编辑覆盖前一个尚未完成的写入。

## 明确留口

以下内容没有用假按钮或临时 JSON 代替真实架构，留给后续阶段：

- 智能集合的持久化规则、查询 DSL 和 UI；
- 真正的音频标签字节级写回器，以及写回前预览、逐文件权限确认和撤销策略；
- 10 万真实歌曲的全链路压力矩阵、真实音频播放子集和文件系统事件风暴；
- 设置中把搜索字段/排序完整接入每个浏览页面；当前查询边界已经具备，页面继续使用默认 relevance 兼容现状；
- 托管旧资料库的完整版本兼容矩阵，以及真实 APP 中切库、退出、重启、NCM 和窗口面板的人工验收。

## 验证记录

- `swiftc -parse $(rg --files kmgccc_player kmgccc_playerTests | rg '\.swift$' | sort)`：通过；
- `git diff --check`：通过；
- 新增搜索 SQLite 字段/排序运行测试、来源排除恢复测试、来源 schema 迁移测试和诊断投影测试；定向 `xcodebuild test` 已通过，共 37 项测试通过（`MusicSettingsStateTests`、`ReferencedSourceStoreTests`、`ReferencedSourceReconcilerTests`）。
- 测试使用独立的 `/tmp/myPlayer2-multi-library-stage8` derived data；此前一次编译阶段无输出的挂起已通过补齐测试目标的共享依赖后恢复，不能把那次环境问题当成业务结论。
- 真实 UI、播放、10 万级性能、文件系统事件风暴、NCM 人工回归和托管资料库完整兼容矩阵仍不能宣称通过；这些仍需在隔离资料库和真实 APP 中验收。

后续接手 Agent 应先在独立 derived data 目录完成上述定向 XCTest，再补真实 APP 验收；如果测试再次无输出，应先检查 Xcode/SourceKit/derived data 环境，而不是修改业务逻辑来迎合挂起。
