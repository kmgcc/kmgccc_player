# Automation 计划实现审计（2026-10-03）

本次按当前 Tool Catalog、CLI、App handler 和领域 owner 核对，工具数量不作为完成标准。
计划入口为 [AI Agent Automation 实施计划](ai-agent-automation-plan.md)，最早现存提交版本
`6ef0b942` 已包含 Library import、跨控制面共享业务、非阻塞 Jobs 和完整用户路径验收。
该版本标注的“Phase A–K 基础能力已落地”不能解释为需求全集完成。

## 本次发现与修复

此前 `playlist.addTracks` 仅接受已有 Track，`source.create/refresh` 仅允许 referenced。
因此 managed 资料库无法通过正式 API 导入外部音频；原计划中的 import 确实遗漏。
NCM 转换和在线补全已有 App 实现，问题在于自动化入口没有接入这些服务。
实测又定位并修复了共享导入中的两处问题：managed NCM 转换失败此前未进入批次失败
结果；其来源记录此前指向临时解密产物，重复导入缺少稳定身份。新增导入保留真实 NCM
来源及 fingerprint。旧曲目缺失的来源信息不能凭相似元数据静默合并。
自动化完成步骤还复用了 UI 的可见状态同步与首批歌单封面生成；补全结束时再次同步。

新增 `library.import(filePaths, targetPlaylistID?, dryRun?)`，CLI 为 `library import`。
路径经 App 授权后进入同一 LibrarySession 的 FileImportService，与 UI 共用身份解析、
复制／原位定位、NCM 转换、嵌入信息读取、歌单提交和在线补全。无需独立解密工具或
Storage fallback。它是一项复合业务操作；逐文件部分成功仍会报告，不宣称整批原子回滚。

Job 立即返回；导入后的 Track IDs、计数、逐文件失败和后台补全结束状态持久化到历史。
网络无匹配属于补全提示，不能保证每首都能补齐或固定耗时。取消保留已提交内容，并取消
本批新增 Track 尚未结束的后台补全。重启后可用 `jobs.retry` 重试导入，目标 Playlist ID
随 Job 恢复；调用方需重新提供文件并重新取得系统授权，retry spec 不保存输入路径或
security-scoped bookmark。逐文件失败结果仍可能包含失败文件路径。既有 identity 去重继续生效。

## 逐领域对照

| 原计划领域 | 当前实现 | 缺口或边界 |
| --- | --- | --- |
| 共享协议／控制面 | CLI、MCP stdio、AF_UNIX IPC，共享 DTO/catalog，业务由 App 执行 | UI 逐步共享服务；未来 Built-in Agent 未实现且原计划明确暂缓 |
| Library | list/get、生命周期 create/open/switch/rename/relocate/remove、tracks/stats/report/import、`library.bundle.export`、selection snapshots | bundle 用 cancellable Job 导出 path-free metadata、Playlist membership、可用音频/Artwork/Lyrics 与 SHA-256 manifest；包含外部引用媒体的真实大库拷贝仍需运行验收 |
| Source | list/get/config.export/config.import/create/rename/refresh/bindPlaylist/setExcludedPath/setMonitorPolicy/remove | 限 referenced；版本化配置包可迁移已存在 Source 的显示名、监听策略和排除路径；原始 bookmark/path、扫描状态及 Playlist 绑定由 App 本地授权与业务流程维护 |
| Playlist | list/get/create/rename/delete/add/remove/replace/reorder/diff/import/export | M3U8 导入只匹配活动库已有曲目；路径型导出需 files.read，默认使用稳定 Track URI |
| Query／Selection | all/any/not、metadata／技术／membership／播放偏好条件、排序、分页、revision；`library.selection.list/create/get/delete` 与 `playlist.addSelection` | 播放计数、手动 like 状态、完成／跳过和最近播放过滤／排序及统计投影均受 `history.read` 保护；有序 Track ID 或 predicate snapshot 可跨重启复用，最多 100 个、每个最多解析 10,000 首、30 天过期；动态 predicate 在读取／加入歌单时重算 |
| Lyrics | get/search/candidates/compare/apply/clean/refresh、批量 Job、重试 | provider 的匹配与质量需要实际内容验收；不存在固定成功率保证 |
| Metadata | Track/Artist/Album/Playlist get/patch；Track search/applyCandidate/export/import；embedded tag live get 与 MP3 patch；QQMusic + MusicBrainz 候选聚合 | 文件标签读写与 App metadata 分开；MP3 ID3v2.3/v2.4 原子写入，其他容器只读；Track 文档每页 100 首，跨库显式映射 |
| Artwork | Track/Artist/Album search，四类实体 get/apply；`artwork.applyCandidate` 可直接按候选 ID 预览/应用 | 候选 ID 绑定资料库、目标和封面 revision，内存保留 15 分钟；跨 provider `matchQuality` 结合匹配字段、像素尺寸和方形裁切适配度，provider `confidence` 保持独立；大图审阅 payload 是受限尺寸预览 |
| Playback | state/play/playPlaylist/toggle/pause/next/previous/seek/setVolume/setMode | 复用 PlaybackCoordinator；`audio.get` 列出可用 Core Audio 输出设备，`audio.patch` 持久选择 App 输出路由，不修改系统默认设备 |
| Queue | get/replace/enqueue/enqueueNext/remove/reorder/clear/upcoming、revision | Queue mutation 仍直接传 Track IDs；持久 selection 通过 `library.selection.*` 和 `playlist.addSelection` 复用 |
| History | list、文本/Track/Artist/Album 筛选、时间范围、limit/offset、revision；stats（Track/Artist/Album）、clear | 清空需要 App 前台确认；无额外隐私导出接口；最多读取 History owner 保留的当前记录 |
| Settings／Audio | settings.schema/get/patch/validate/reset；audio.get/patch | Settings 覆盖当前有明确持久合同的导入时序、外观、Dock、封面 tint 和 referenced 删除策略；Audio 读写 gapless scheduling/AAC trim 和 App 输出设备选择，并读取当前系统／App 输出的名称、采样率、报告延迟和蓝牙状态 |
| Jobs | list/get/cancel/retry、进度、失败、持久历史、重启中断报告；现代 MCP Tasks get/update/cancel 与 `notifications/tasks` 映射 App Job；Resources 订阅 Jobs 快照；stdio `notifications/cancelled` 贯通 AF_UNIX 到 App handler | Lyrics/Source 可由持久输入重建；导入 retry 需要调用方重新提供文件路径并授权，retry spec 不保存输入路径；失败结果可能包含诊断路径；task handle 绑定原 Library，切库时须切回查询；已返回的持久 Job 仍需显式取消 |
| Files | inspect/reveal/export/rename/move/delete；引用文件使用 Source 授权；导出由 App picker 授权目标目录 | copy 目前作为 export 的 picker 操作；多项 rename/move/delete 有预览／确认，delete 保留高风险授权 |
| Import／Export | Playlist M3U8；Library report 与含媒体 `library.bundle.export`；Source 配置文档；Track Metadata 文档 import/export | Metadata 文档和 Library bundle 均不包含 Source bookmark/原始路径；bundle 由 App picker 授权，后台 Job 可取消并报告逐项失败 |
| Diagnostics／Storage | health 机器报告、inspect/validate/orphans/backup/diff/reload/repair | health 额外报告缺 Lyrics、Artwork 和关键 Metadata 字段的覆盖数；repair 仅补脚手架，`storage.backup` 仍是 metadata-only；任意 JSON write 不作为普通 Tool |
| MCP／CLI UX | catalog/schema、JSON、help、Resources、Prompts、scope/Job/Task annotations；modern `server/discover` 宣告 Tasks；现代 stdio `subscriptions/listen` 推送 Jobs 资源与 Task 状态 | legacy handshake 仍需 initialized notification；HTTP/XPC/远程授权属于后续评估，不在 stdio/本机 IPC 实现承诺内 |
| 完整验收／发布 | 已有分日期 Debug／协议／临时库验收记录 | 不能从历史记录推导当前所有工具、权限拒绝、GUI、真实 provider、签名／sandbox 发布均已验收 |

### 路线图词项的组合映射

下列名称没有各自重复成独立 Tool，因为已有同一 owner 的组合 API 覆盖其语义：

| 路线图词项 | 当前组合入口 | 语义边界 |
| --- | --- | --- |
| Library `missing` / `rescan` | `library.tracks` 的 `missing` predicate；Referenced 用 `source.refresh`；`storage.reload` 只重读受控的 App-owned storage change | `storage.reload` 不是任意媒体文件扫描；Managed 新音频必须走 `library.import` |
| Source `enable/disable` | `source.setMonitorPolicy` 的 `on/off`；需要时仍可单独 `source.refresh` | 监听开关不阻止用户明确发起的刷新 |
| Playlist `union/intersection` | `playlist.diff` 的 `union` / `intersection` operation | 继承首个 Playlist 的稳定次序并支持分页 |
| Settings `preview` | `settings.validate` | 只校验 patch 与当前 revision，不持久写入 |
| File `copy` | `files.export` | 通过 App picker 授权目标目录，复制且保留原件 |
| Metadata / Artwork batch | `metadata.patch`、`artwork.apply` 的多 Track 输入与批量确认策略；候选搜索／应用保持逐目标 revision 校验 | 不为相同 patch 或封面写入制造 N 次同步调用；高风险写入仍受前台确认与 revision 保护 |

## 文档漂移

计划顶部的旧工作树、分支和基线描述原实施环境，现已明确标为历史基线。
各 checkpoint 是当时的证据，不应覆盖后来的新增能力。当前 artwork search/applyCandidate
已提供短期候选句柄、revision 检查和统一 `matchQuality` 排序；真实 provider 质量校准仍需网络验收。早期 Phase 1 说明也是
历史只读探针，当前入口以公开文档为准。

本轮更新了共享 MCP Resource guide、CLI help、Capability Reference、Agent Guide、
CLI/IPC/MCP 文档和可加载 Skill，让新歌导入明确走正式 API。

### 2026-10-03 扩展 checkpoint

本轮继续按路线图补齐原先遗漏的 MCP Tasks、Metadata 候选和文件访问路径：

- MCP Tasks 按 2026-07-28 extension 协议仅在客户端逐请求声明 Tasks 能力时返回，支持 `tasks/get`、
  `tasks/update`、`tasks/cancel`。Task handle 编入来源 Library ID 与 App Job ID；Job 在返回 Task
  前必须能通过 `jobs.get` 读回，确保不会发出不可查询的句柄。后台失败以 completed + tool error
  result 表达，区分 JSON-RPC execution failure；取消复用 App 的协作式 Job 取消。
- Metadata 新增 `metadata.search` 与 `metadata.applyCandidate`，直接复用 bundled QQMusic helper 和
  LibraryViewModel 的 metadata detail service；预览返回字段差异，默认只填空字段，覆盖已有值需
  `overwriteExistingFields=true`，并以 Track revision 防止异步搜索期间覆盖并发编辑。
- Files 新增 `files.reveal` 与 `files.export`。Finder 定位仅使用活动授权的 referenced file 或
  活动 managed Library 中已存在的音频；导出通过 App folder picker 获得目标授权，拷贝时为重名文件
  生成新名称，保留 Library 原件，并拒绝写入活动 Library 根目录。
- 已存在的 Prompts/Resources 加入 Import workflow 引导。源码检查确认 `metadata.get/patch`、
  `diagnostics.health` 的机器报告、Queue/History/Settings/Audio 和 M3U8 exchange 已有 owner；
  本轮把审计表更新为当前代码状态。
- Settings patch/schema/validate/reset 扩展到 App 当前已有持久设置：导入补全时序、外观、
  artwork tint、可视化 HDR 和 Dock 进度。所有 patch 先做类型/枚举校验并参与 revision；
  referenced 文件删除策略仅适用于 referenced Library，危险值仍需 App 前台确认。
- Artwork search 结果增加稳定、library/target/revision 绑定的 `candidateID`；新增
  `artwork.applyCandidate`，可在短期 cache 有效时直接 dry-run 或通过现有 App artwork owner 写回，
  并拒绝过期、切库和并发 revision 冲突。

本轮验证范围为 PlayerAutomation Debug build、MCP stdio 的 modern discovery/缺少 Tasks capability
错误烟测、MelismaKit 本地依赖 preflight 和 App Debug build；没有启动主 App，也没有测试真实 QQMusic
provider、Finder picker、sandbox 权限或物理导出目录。仍待实现的明确计划缺口包括原音频 embedded tag
写入、跨 provider Metadata quality pipeline 和完整 Library bundle export。
本次补入动态 Selection predicate 与分页 machine-readable Library report。HTTP/XPC/远程授权在原计划中是按真实需求评估，
不属于当前 stdio 阶段承诺。

### 2026-10-03 Source 配置交换补齐

新增 `source.config.export/import` 版本化 JSON 合同及 CLI `source config-export/config-import`。
配置文档只包含 Source ID、显示名、监听策略和排除路径；跨库需显式映射至目标库已有 Source，
导入支持 dry-run、expected revision 与 App 前台确认。路径、bookmark、扫描状态和 Playlist binding
仍由本机 App 授权与 Source/Playlist owner 管理。PlayerAutomation 21 项测试、CLI build、Zsh
completion 语法和 MelismaKit 本地依赖 preflight 已通过；App Debug build 与本次 handler 编译
已通过，未启动主 App 做授权／持久化运行验收。

`metadata.get`、`library.tracks` 和 `library.report` 的 Track 摘要现一并返回可选的
`embeddedMetadataSnapshot`：仅映射资料库保存的导入时标签快照，不额外读取音频文件，也不写入文件。
协议兼容测试覆盖旧响应缺字段及新快照往返。

Source 配置交换与跨 provider Metadata 搜索／质量排序不再列为待实现。后续已实现 Track Metadata 文档交换、
Artwork `matchQuality`、Library bundle 与诊断覆盖率；剩余代码缺口收窄为 embedded tag 写入和没有
持久 owner 的复杂全局 Settings。远程 transport 按原计划在实际需求出现后评估。

本轮 Metadata 候选搜索加入 MusicBrainz recording search，并与 QQMusic 候选统一按可用字段计算
标题／艺人／专辑／时长匹配分数；provider confidence 保持 provider-local。结果分别报告 provider
故障。候选应用会重新搜索确认 ID，再查询 MusicBrainz recording detail；两类候选都沿用 Track
revision、默认只填空字段、dry-run 和 App-owned Metadata persistence。MusicBrainz API 请求使用动态
App 版本 User-Agent，并在 provider actor 中按每秒一个请求排队。协议层 22 项测试、CLI build、
MelismaKit 本地依赖来源和 App Debug build 通过；未做真实网络 provider／候选质量运行验收。

## 验收矩阵与记录

| 路径 | 验收要求 | 本轮状态 |
| --- | --- | --- |
| 协议／目录 | schema、scope、Job annotation、结果序列化、旧 Job 解码 | 20 项 SwiftPM 测试通过；覆盖动态 Selection schema、旧快照解码和 report 双分页目录 |
| 动态 Selection／report | predicate 重新求值、revision conflict、Track 与 Playlist 双分页 | 本轮完成 App 编译及协议合同测试；未启动主 App 做磁盘持久化／实际歌单变更验收 |
| 主 App 编译 | Debug 构建、确认本地 MelismaKit 实际编译输入 | 本轮增量 Debug build 与本地 MelismaKit source check；主 App 未启动 |
| Embedded tags | 读取当前文件；MP3 ID3 写入不改音频帧；失败不改原件 | MP3 单测校验 UTF-8、ID3 标签读回、MPEG 音频帧字节一致和不支持格式原件保持；主 App 文件授权／确认仍待运行验收 |
| managed 文件／目录 | 新 Track、副本、目标歌单、重复复用 | 主 App 临时库通过：首次新增 2 首，歌单新增 2 项；再次新增 0、复用 2 |
| referenced 导入 | 外部定位、Source、目标歌单、重复复用 | 主 App 临时库通过：首次新增 2 首，歌单新增 2 项；再次新增 0、复用 2 |
| NCM | App 内部转换、元数据／嵌入封面、失败隔离 | 合成加密 NCM 在两种模式转换通过，标题／艺人／专辑／嵌入封面正确；损坏 NCM 单独报告；定向 XCTest 1 项通过 |
| 补全 | 与 UI 同一配置／服务，入库和补全状态分开，sidecar flush 完成 | 同一服务实测完成；Track／Artist／Album 补全执行，TTML 歌词与图片持久化；无匹配提示保留 |
| 安全／生命周期 | dry-run 无写入、无效输入、取消、持久 Job 结果、切库隔离 | preview 前后 manifest／Job 历史 hash 不变；无效路径／歌单与旧资料库请求被拒；入库后取消保留 Track；两种模式 Job result 重启后保留，取消状态及补全文件保留 |
| 发布与权限 | 签名／sandbox、系统授权拒绝、真实 provider 匹配质量 | 本轮不宣称已验证 |

本轮以主 App 的 Debug 构建与合成音频进行验收。已恢复原 Music 资料库，并清理测试库登记。导入请求约 18–24 毫秒返回 Job，
后台补全本次约 27–33 秒，不能作为固定性能承诺。歌曲数、来源定位、歌单成员与
生成封面、重复复用、逐文件失败及补全提示均检查实际结果，界面一致性检查通过。
使用了独立测试库，未向用户 Music 资料库导入测试歌曲。当前安装发行版未替换，
客户端需连接新构建的 App／adapter 并重新建立 MCP 会话才能发现新增工具。

历史优先级注记：新歌导入、Metadata 候选、M3U8 歌单交换、持久设置扩展、MCP Tasks 和可重新求值的
持久筛选已于本轮实现。Source 配置交换和跨 provider Metadata 搜索已补齐；尚未完成的范围是原音频
embedded tag 写回、Metadata 文档交换、Artwork 质量校准、完整 Library bundle export 和 Diagnostics
深化。HTTP/XPC 与远程授权仍按原计划评估。

### 2026-10-03 embedded tags 与 bundle export checkpoint

此前 checkpoint 中“embedded tag 写入仍未开放”和“完整 Library bundle 未实现”是历史记录。当前已新增
`metadata.embedded.get/patch` 与 `library.bundle.export`：MP3 ID3v2.3/v2.4 支持实时读写，其他格式由
AVFoundation 读取可用信息但当前不写；写入要求 Track revision、dry-run、`confirm=true` 和 App 前台确认，
采用每文件暂存验证与原子替换，批次状态持久记录为 Job。Library bundle 使用 App picker 授权目标并由
cancellable Job 复制 metadata、playlist membership、可用媒体和 artwork/lyrics。Diagnostics 现在报告
lyrics、artwork 和关键 metadata 覆盖率。

MP3 writer 是基于 ID3 frame 的 lossless 容器编辑，不触碰 MPEG 音频帧；未知 frame 会保留。当前拒绝
带 unsynchronization、extended header、experimental/footer flags、损坏 frame 或其他不能按当前规则保留的
标签。MP3、WAV、M4A 的系统 `AudioFile` property writeability 探测均为只读，因此没有把该 API 伪装成通用
writer。非 MP3 写回、复杂全局 Settings 和用户选择／持久化输出路由仍需各自 owner；HTTP/XPC/远程授权按原路线图
基于需求评估，内置 Agent/runtime 仍明确暂缓。

本轮回归验证：PlayerAutomation SwiftPM 26/26、MP3 writer 与 Library bundle 定向 XCTest 4/4、App
ARM64 Debug build、MelismaKit 本地源码编译输入检查、UI strict-copy 门禁和 `git diff --check` 均通过。
测试覆盖协议与传输契约、ID3 字段与原音频帧保留、bundle manifest；没有启动主 App，也未验证真实 picker/
sandbox 授权、线上 provider 响应和发行签名环境中的文件替换。

### 2026-10-03 播放偏好查询与导入重试 checkpoint

`library.tracks`、动态 Selection 与 `library.report` 增加持久播放偏好筛选、排序和可选统计投影；
嵌套 predicate 和使用偏好字段的排序／投影会按实际读取检查 `history.read`。旧 Track 响应仍可解码。
导入 Job 新增安全重试规格，保存目标 Playlist ID，但不保存输入路径或书签；跨重启后调用方重新提交
`filePaths`，App 重新检查并取得需要的访问授权，再走同一 managed/referenced、NCM、去重和补全流程。
重试会重新排入复用曲目仍缺失的补全项，并等待本 Job 的补全终态；逐文件失败结果可能包含诊断路径。

本 checkpoint 验证了 PlayerAutomation SwiftPM 27/27、Query／ID3／Library bundle／Job recovery 定向
XCTest 8/8、CLI 无启动参数解析、MelismaKit 本地依赖 preflight 和 `git diff --check`。XCTest 通过
App Debug 构建验证最终源码，但没有启动主 App；实际文件 picker／系统授权、线上元数据 provider 和
物理音频设备仍未在本轮做运行验收。通用 MCP 在途 request cancellation、transport-close 到 App Job 的取消传播、远程 HTTP/XPC
与内置 Agent/runtime 仍按实施计划所述属于后续设计边界，而非当前本地 stdio 阶段的已验收能力。

### 2026-10-03 历史查询分页补齐

`history.list` 新增文本、Track ID、艺人片段和专辑片段筛选，支持 offset 分页并返回总数与下一页 offset；
`expectedRevision` 用于发现前后页之间新增的播放记录。CLI 去除原先对 `history list --offset` 的拒绝，
并透传 query、Track ID、revision 与扩展参数。依赖现有最多 10,000 条的 PlaybackHistoryStore 保留窗口，
不增加第二份存储或把读取扩大到历史 owner 之外。当前只做源码、协议 schema 与文档一致性复核；按用户要求，
本轮不再编译、启动 App 或做第三方 Agent 实测，因此这一增量的编译和运行状态未验证。

### 2026-10-04 音频输出状态读取

`audio.get` 现在附带 `AudioOutputLatencyMonitor` 当前快照：系统输出设备名称、采样率、报告延迟和蓝牙状态，
设备 UID 不对外暴露；仍通过既有 `audio.read` scope 读取。`audio.patch` 保持 gapless scheduling/AAC trim 的
现有写入范围，系统路由的用户选择与持久化还没有 App owner。本增量只完成源码与文档核对；遵照用户要求，
未运行构建、测试或真实 App／第三方 Agent 验收。

### 2026-10-04 App 输出路由控制

`audio.get` 现在列出可用输出设备的稳定 opaque ID、名称、采样率、蓝牙与系统默认状态，并区分系统默认
输出和 App 实际输出；设备 UID 不进入 automation response。`audio.patch.values.outputDeviceID` 可选择
这些设备之一，传 `null` 恢复跟随系统默认。选择保存在 AppSettings，并经既有 RendererPlaybackPipeline
设置 App 播放路由，不改变系统默认设备；输出选择加入 revision 和 dry-run 校验。EQ／ReplayGain 仍未开放，
因为当前 App 没有对应的 DSP owner。只做源码与文档复核，未运行构建、测试或真实音频设备验收。

### 2026-10-04 MCP Jobs 资源订阅

新增 `kmgccc://jobs` Resource，并为现代 stdio MCP 实现 `subscriptions/listen`。客户端可订阅 Job
资源变化，或在逐请求声明 Tasks 扩展后订阅 `taskIds` 并接收完整 `notifications/tasks` 状态／进度。
服务端确认过滤器后，后台约每 2 秒读取当前资料库的 `jobs.list` 快照；客户端收到资源变更通知后重新读取。
所有通知带关联订阅 ID，取消订阅会返回 listen 请求的优雅关闭结果；轮询不会启动 App。通用在途工具请求取消、
transport-close 到 App Job 的取消传播，以及所有真实 App／第三方 Agent 行为仍未验证或实现。

遵照用户要求，本增量只完成源码和文档复核与 `git diff --check`，未运行构建、测试、主 App 或 Agent 实测。

### 2026-10-04 MCP 在途请求取消

stdio 现在将有 request ID 的操作并发执行，使输入循环能及时读取取消通知。`notifications/cancelled` 会
关闭请求拥有的 IPC socket；AF_UNIX listener 观察到断连后取消 handler 并传递 cancellation token。
若取消中的请求刚返回新建 Job，且没有同幂等键的其他等待者，AutomationIPCServer 会请求取消该 Job。
已经返回的 Job/Task 是持久工作，继续由 `jobs.cancel`/`tasks.cancel` 管理。IPC 请求重试和 stdin 关闭都会
识别已取消状态，不再发送迟到的 JSON-RPC 响应。

源码审阅、PlayerAutomation SwiftPM build、App ARM64 Debug build、依赖 preflight 与 `git diff --check` 通过；
没有启动主 App，也没有第三方 Agent 实测。取消目前覆盖本地 stdio + AF_UNIX，
不覆盖尚未实现的 HTTP/XPC，也不保证能同步关闭 AppKit sheet 或外部 provider 内部的阻塞操作。
