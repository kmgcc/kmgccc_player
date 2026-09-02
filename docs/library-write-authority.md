# 资料库持久写入 authority matrix

这张表是 multi-library-storage Phase 0 的写入边界。`LibrarySession` 为一套资料库组合唯一的 owner；可改变权威数据的短操作必须从 `LibraryMutationCoordinator` 进入。扫描、解析、网络搜索和音频解码属于长任务，完成后才进入短提交。派生缓存可以丢弃并重建，但不得伪装成权威写入。

| 领域 / 函数入口 | 权威存储 | 写入 owner 与顺序 | 失败/取消语义 | 维护例外 |
| --- | --- | --- | --- | --- |
| Track 导入：`FileImportService.commitImportEffects`、`SwiftDataLibraryRepository.commitImportedTracks` | `Tracks/<id>/meta.json`、托管音频或 referenced locator、SwiftData 索引 | `LibraryMutationCoordinator(.importCommit)`；预分配 Track ID，先完成 track/source，再提交 playlist membership，最后发布 live/index | typed persistence result；失败补偿 staging、reused locator 和 provisional source；取消不提交 playlist | NCM 转换目录由 NCM registry/转换服务自有事务管理 |
| Track metadata：`LocalLibraryService.writeMetaOnly*`、`SwiftDataLibraryRepository.persistTrackMetaOnly` | Track sidecar | session-owned service；同步写返回 `Bool`/result，后台写捕获不可变 `LibraryPaths`，由 session quiesce 等待 | 写失败不发布成功的持久状态；后台 best-effort 记录错误，关闭前等待已捕获任务 | 播放统计/喜欢状态是低风险辅助写，仍禁止跨 session 路径 |
| Playlist：`SwiftDataLibraryRepository.create/update/add/remove/replace/deletePlaylist` | `Playlists/<id>/meta.json`、`items.json` | `LibraryMutationCoordinator(.userLibraryMutation)`；先原子 sidecar 写，成功后更新对象图 | sidecar 失败不改变内存；删除 playlist 通过 backend 的 deletion transaction 同时清 source binding/membership | 生成封面是派生资产，不能阻塞 playlist 权威提交 |
| Playlist 与 referenced source membership：`ReferencedLocalBackend.commit*Playlist*` | `PlaylistMemberships.json`、source descriptor 的 binding | backend 在 coordinator 短事务中 snapshot → 写 membership/binding → 调用 playlist commit；失败恢复 snapshot | 恢复失败会保留并报告原错误，不静默吞掉；取消只发生在事务边界外 | 启动迁移只把旧 playlist sidecar 转换为 membership projection |
| Artist / Album：`SwiftDataLibraryRepository.update/apply/delete*`、`LibraryMetadataSync` | `Artists/<id>/meta.json`、`Albums/<id>/meta.json` | sidecar writer `throws`；磁盘成功后才更新 live entries；enrichment 通过 `.enrichmentCommit` | typed `LibraryMetadataPersistenceError`；同步失败保留上一次 coherent projection；删除清理失败返回 `LibraryTrackDeletionError` | reload/maintenance 可修复重复或孤立 sidecar，但缺失项按幂等删除处理 |
| Import enrichment：`ImportEnrichmentService`、`ImportImmediateEnrichmentEngine` | Artist/Album/Track sidecar | 解析/网络在 coordinator 外；每个 metadata commit 进入 `.enrichmentCommit` | 任一 sidecar 失败返回 false，保留旧 live projection | suggestions 只在 Track sidecar 中持久化，不回写原文件 |
| Referenced Source descriptors：`ReferencedLocalBackend.prepare/commitPreparedSources` | `Sources/<id>/descriptor.json` | prepare 只生成稳定 ID、bookmark 和 in-memory descriptor；最终 commit 才写 descriptor | 取消不落盘；部分写入按 ID 删除补偿；无法补偿时记录错误并阻止假成功 | session start 的 bookmark hydration 可更新 status/bookmark，属于授权维护写 |
| Source manifests：`ReferencedSourceReconciler.finalize` | `Sources/<id>/manifest.json` | reconcile intent → `.sourceReconcileCommit` → authority sidecars → manifest → playlist sync | intent 保留 committed IDs；恢复先 reload authority，再按 intent 继续/报告 | 只读 scan 不写 manifest |
| Source monitor/reconcile | Track locator、source status、playlist membership | `ReferencedSourceReconciler.drivePrepared`；扫描和 import 在 coordinator 外，`commitPrepared` 在 coordinator 内 | per-source failure 不阻塞其他 source；pending intent 可重放 | unavailable/authorization status 是 source lifecycle maintenance |
| Ignored items：`IgnoredReferencedItemsStore` | `ignored-items.json` | source deletion/retry service owns writes；manual retry 是明确的 preflight mutation，不由 planner 隐式写 playlist/source | add/remove 原子写；补偿失败记录错误 | scanner 只读查询，查询失败保守跳过 |
| NCM registry/output | `NCMConversionRegistry`、外部 source 下的转换目录与 marker | `ReferencedNCMConversionService` / registry state machine；output publish 后才标记 ready/committed | reservation 保留到可 adjudicate；删除失败保留 ignored record，避免下次扫描重复导入 | 生成 output 永不被自身 scanner 当作新输入 |
| Playback history / preference stats | history store、Track preference stats | `PlaybackHistoryStore` / `PreferenceStatsService`；统计 sidecar 写经 `LocalLibraryService`，不改变 Track identity | 历史写失败不回滚播放，但要记录错误；reset 使用 captured library paths | 可重建 index/cache 不属于权威 |
| Settings / registry | per-library settings、global registry | 发起时捕获 `libraryID + sessionGeneration + paths`；变更经 session owner/coordinator | 切换或关闭后拒绝旧 generation 写入 | 全局 UI 偏好不写入 Library root |
| Search/track index | FTS/index cache、TrackIndex SQLite | repository 发布成功后异步更新；任务捕获 immutable source snapshot | index 失败可从 sidecar/SQLite 重建，不阻塞权威数据 | `clearIndexCacheAndRebuild` 是显式 maintenance |
| Managed / referenced 文件删除 | managed `Tracks/<id>`；referenced 外部文件 | deletion service 先判定 authority，再写 playlist/metadata；referenced 只删除 metadata/ignored record，不删除用户外部音频 | disk full/read-only 返回 typed failure；managed folder 删除失败不伪装清理完成 | 缓存、临时 staging、转换 debris 可在 maintenance 中幂等清理 |

## 生命周期合同

关闭或切换按以下顺序执行：停止接收新的长任务 → 停止/取消 monitor 和 operation producers → `LibraryMutationCoordinator` drain 当前短提交 → flush/recover mutation journal → 释放 repository、playback、source scope 等 runtime owner → 最后释放 `LibraryWriterLease`。旧 session 的任务不能在 await 后重新读取 active library，也不能重新创建旧路径。

## 代码审查规则

新增持久写入时，先在本表增加一行，再选择 owner。`try?` 只能用于临时文件、派生缓存或幂等清理；权威 sidecar、membership、source descriptor、manifest、history、stats 和 registry 写不得静默吞错。任何跨 JSON/SQLite/索引的操作都必须声明提交顺序和补偿边界，不得宣称不存在的跨存储 ACID。
