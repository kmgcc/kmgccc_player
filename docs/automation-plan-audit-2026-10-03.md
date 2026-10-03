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
本批新增 Track 尚未结束的后台补全。外部授权路径没有持久 retry 规格，跨重启重试应
重新调用 import 并使用新 idempotency key；既有 identity 去重继续生效。

## 逐领域对照

| 原计划领域 | 当前实现 | 缺口或边界 |
| --- | --- | --- |
| 共享协议／控制面 | CLI、MCP stdio、AF_UNIX IPC，共享 DTO/catalog，业务由 App 执行 | UI 逐步共享服务；未来 Built-in Agent 未实现且原计划明确暂缓 |
| Library | list、生命周期 create/open/switch/rename/relocate/remove、tracks；本轮补 import | get/stats/missing 可从查询与 health 获取部分信息；独立统计、通用 rescan／batch 未完整开放 |
| Source | list/create/refresh/bindPlaylist/setExcludedPath/setMonitorPolicy/remove | 限 referenced；独立 rename、通用 update、完整 scan policy 合同未开放；这不再限制 managed import |
| Playlist | list/get/create/rename/delete/add/remove/replace/reorder | diff/union/intersection 可由 Agent 组合查询；独立工具、播放列表文件导入／导出未开放 |
| Query／Selection | all/any/not、metadata／技术／membership 条件、排序、分页、revision | 没有可持久复用的独立 selection 实体；不要把 offset 查询称为完整 selection 平台 |
| Lyrics | get/search/candidates/compare/apply/clean/refresh、批量 Job、重试 | provider 的匹配与质量需要实际内容验收；不存在固定成功率保证 |
| Metadata | Track/Artist/Album/Playlist get/patch，批量、revision、dry-run；导入自动补全 | 独立候选检索／质量评分／preview diff／candidate apply 未完整开放；embedded tag 写入暂未开放 |
| Artwork | Track/Artist/Album search，四类实体 get/apply，图片候选可读取并应用 | “candidate mutation 未实现”旧结论已过时；仍缺稳定候选 ID、独立质量评分和自动替换策略合同 |
| Playback | state/play/pause/next/previous/seek/setVolume/setMode | 复用 PlaybackCoordinator；toggle、Playlist 播放可组合已有工具，不是全部独立工具 |
| Queue | get/replace/enqueue/enqueueNext/clear、revision | remove/reorder/upcoming 没有独立工具；客户端替换队列须保留 revision 并处理冲突 |
| History | list、时间范围、clear | 专门统计与 Artist/Album 聚合未开放 |
| Settings／Audio | settings.get/patch 只覆盖 referenced 删除策略 | 完整设置 schema/reset/preview 及 EQ／输出／设备等 Audio 控制面未开放；audio scope 的存在不是工具实现证据 |
| Jobs | list/get/cancel/retry、进度、失败、持久历史、重启中断报告；本轮补通用 result | 安全 retry 只覆盖 Lyrics/Source；不会自动恢复外部路径授权或继续中断导入；MCP Tasks 未映射 |
| Files | inspect/rename/move/delete，Source 授权、预览、危险操作确认 | reveal/copy/export 未开放；已有文件变更受 referenced 范围约束 |
| Diagnostics／Storage | health、inspect/validate/orphans/backup/diff/reload/repair | repair 仅补脚手架，backup 仅元数据；细分 report/export、任意 JSON write 未开放 |
| MCP／CLI UX | catalog/schema、JSON、help、Resources、scope 与 Job annotations | 当前只支持实现中声明的两种握手路径；旧版必须完成 initialized notification；HTTP/XPC/远程授权、Prompts、协议级 Tasks／取消仍属后续范围 |
| 完整验收／发布 | 已有分日期 Debug／协议／临时库验收记录 | 不能从历史记录推导当前所有工具、权限拒绝、GUI、真实 provider、签名／sandbox 发布均已验收 |

## 文档漂移

计划顶部的旧工作树、分支和基线描述原实施环境，现已明确标为历史基线。
各 checkpoint 是当时的证据，不应覆盖后来的新增能力。旧的“Artwork candidate mutation
未开放”与后续 search/apply、实体 artwork 扩展并存；本次将其区分为图片应用已实现、
候选身份与质量合同仍缺失。早期 Phase 1 说明也是历史只读探针，当前入口以公开文档为准。

本轮更新了共享 MCP Resource guide、CLI help、Capability Reference、Agent Guide、
CLI/IPC/MCP 文档和可加载 Skill，让新歌导入明确走正式 API。

## 验收矩阵与记录

| 路径 | 验收要求 | 本轮状态 |
| --- | --- | --- |
| 协议／目录 | schema、scope、Job annotation、结果序列化、旧 Job 解码 | 19 项 SwiftPM 测试通过；MCP 两种现有握手、目录与 import 合同 smoke 通过 |
| 主 App 编译 | Debug 构建、确认本地 MelismaKit 实际编译输入 | 独立 DerivedData Debug 构建／主 App 运行通过；日志确认本地 MelismaKit 编译输入 |
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

优先级：本轮完成新歌导入闭环；后续高价值补项为 Metadata 候选／质量工作流、歌单
导入导出和更广的持久设置控制面。HTTP、Built-in Agent 和 MCP Tasks 保持原计划的后续范围。
