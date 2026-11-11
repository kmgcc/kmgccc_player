import PopupKit
import SwiftUI

/// Read-only diagnosis for a library that cannot open, plus an explicit
/// quarantine action for the records the inspector can name. The sheet is
/// also reachable while a library is open so unsettled journal records can be
/// verified without restarting the App.
struct LibraryRepairSheet: View {
    @ObservedObject var appSession: AppSessionHost
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AppPopupFrame(
            title: "资料库检查",
            systemImage: "stethoscope",
            onClose: { dismiss() },
            showsFooter: false
        ) {
            AppPopupScrollRegion {
                content
            } actions: {
                actions
            }
        } footer: {
            EmptyView()
        }
        .frame(width: 620, height: 540)
        .task {
            await appSession.refreshLibraryRepairReport()
        }
    }

    @ViewBuilder
    private var content: some View {
        if appSession.isInspectingLibraryRepair, appSession.libraryRepairReport == nil {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在检查资料库")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let report = appSession.libraryRepairReport {
            VStack(alignment: .leading, spacing: 16) {
                summary(report)
                if report.issues.isEmpty, report.unresolvedTransactions.isEmpty {
                    Text("没有发现需要处理的记录")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    if !report.issues.isEmpty {
                        sectionTitle("无法读取的记录")
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(report.issues.prefix(8))) { issue in
                                issueRow(issue)
                            }
                            if report.issues.count > 8 {
                                Text("另有 \(report.issues.count - 8) 个记录")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !report.unresolvedTransactions.isEmpty {
                        sectionTitle("未完成的操作")
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(report.unresolvedTransactions) { transaction in
                                transactionRow(transaction)
                            }
                        }
                    }
                }
                Text("检查只读取文件。隔离会把记录移到资料库内的恢复文件夹，可随时取回。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView(
                "没有可检查的资料库",
                systemImage: "externaldrive.badge.questionmark",
                description: Text("打开或创建一个资料库后再检查。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func summary(_ report: LibraryRepairReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(report.displayName ?? "未命名资料库")
                .font(.callout.weight(.medium))
            Text(report.rootURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
            Text("歌曲 \(report.trackCount)，歌曲文件夹 \(report.trackFolderCount)，来源 \(report.sourceNames.count)，未完成操作 \(report.unresolvedTransactions.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !report.sourceNames.isEmpty {
                Text("来源：\(report.sourceNames.prefix(4).joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !report.sampleTracks.isEmpty {
                Text("可读取的歌曲：\(report.sampleTracks.prefix(3).joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func issueRow(_ issue: LibraryRepairIssue) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: issue.blocksOpen ? "exclamationmark.circle.fill" : "info.circle")
                .foregroundStyle(issue.blocksOpen ? Color.orange : Color.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(kindTitle(issue.kind))：\(issue.path.lastPathComponent)")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(issue.path.deletingLastPathComponent().path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Text(issue.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }

    private func transactionRow(_ transaction: LibraryMutationIntentSummary) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(kindTitle(transaction.kind))
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
                Text(transaction.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !transaction.pendingSteps.isEmpty {
                Text("未完成步骤：\(transaction.pendingSteps.joined(separator: "、"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let hint = transaction.recoveryHint {
                Text("可以核对：\(hint)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(11)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
    }

    private var actions: some View {
        AppPopupActionGroup {
            Button("重新检查") {
                Task { await appSession.refreshLibraryRepairReport() }
            }
            .buttonStyle(AppDialogGlassButtonStyle())
            .disabled(appSession.isInspectingLibraryRepair || appSession.isRepairingLibrary)

            if appSession.canQuarantineLibraryRepairIssues {
                Button(appSession.isRepairingLibrary ? "正在隔离" : "隔离损坏记录") {
                    Task { await appSession.quarantineLibraryRepairIssues() }
                }
                .buttonStyle(AppDialogGlassButtonStyle(kind: .primary))
                .disabled(appSession.isRepairingLibrary || appSession.isInspectingLibraryRepair || appSession.isRetryingLibraryStartup)
            }

            if let report = appSession.libraryRepairReport {
                Button("显示恢复文件夹") {
                    let recovery = LibraryPaths(rootURL: report.rootURL).recoveryRootURL
                    if !FinderRevealHelper.reveal(path: recovery.path) {
                        appSession.uiState.showSidebarNotice("恢复文件夹暂时无法访问", style: .warning)
                    }
                }
                .buttonStyle(AppDialogGlassButtonStyle())

                if !report.unresolvedTransactions.isEmpty {
                    Button("归档未完成记录") {
                        Task { await appSession.archiveUnresolvedLibraryMutations() }
                    }
                    .buttonStyle(AppDialogGlassButtonStyle())
                }
            }

            Button("完成") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(AppDialogGlassButtonStyle(kind: .primary))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func kindTitle(_ kind: LibraryRepairIssueKind) -> String {
        switch kind {
        case .manifest: return "资料库清单"
        case .source: return "来源描述"
        case .transaction: return "操作记录"
        case .track: return "歌曲记录"
        case .playlist: return "播放列表"
        case .settings: return "资料库设置"
        case .ncm: return "转换记录"
        }
    }

    private func kindTitle(_ kind: LibraryMutationKind) -> String {
        switch kind {
        case .userLibraryMutation: return "资料库修改"
        case .importCommit: return "歌曲导入"
        case .enrichmentCommit: return "信息补全"
        case .sourceReconcileCommit: return "来源同步"
        case .settingsUpdate: return "设置更新"
        case .maintenance: return "资料库维护"
        case .automation: return "自动化任务"
        }
    }
}
