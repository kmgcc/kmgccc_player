import SwiftUI

/// Small, persistent companion to the transient import-progress panel. It is
/// intentionally read-only: the user can see the failing item and retry from
/// the source or import action without losing the diagnostic.
struct LibraryImportStatusDialogView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var themeStore: ThemeStore

    let reports: [LibraryImportFailureReport]
    let tasks: [LibraryOperationTaskDescriptor]
    let onClear: () -> Void

    private var failures: [ImportInputFailure] {
        var seen = Set<String>()
        return reports
            .flatMap(\.failures)
            .filter { failure in
                let key = "\(LibraryImportSourceEntry.canonicalPath(failure.url))|\(failure.message)"
                return seen.insert(key).inserted
            }
    }

    var body: some View {
        AppDialogFrame(
            header: {
                AppDialogHeader(
                    title: "导入状态",
                    systemImage: "arrow.down.circle",
                    iconColor: themeStore.accentColor
                )
                .padding(.horizontal, AppDialogTokens.headerHorizontalPadding)
                .padding(.top, 14)
                .padding(.bottom, 12)
            },
            content: {
                content
            },
            footer: {
                AppDialogFooter {
                    HStack {
                        if !failures.isEmpty {
                            Button("清除记录", action: onClear)
                                .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
                        }
                        Spacer()
                        Button("完成", action: dismiss.callAsFunction)
                            .keyboardShortcut(.defaultAction)
                            .buttonStyle(AppDialogGlassButtonStyle(kind: .primary))
                    }
                }
            }
        )
        .frame(width: 560, height: 460)
    }

    @ViewBuilder
    private var content: some View {
        if tasks.isEmpty && failures.isEmpty {
            ContentUnavailableView(
                "没有导入记录",
                systemImage: "checkmark.circle",
                description: Text("导入正常")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if !tasks.isEmpty {
                        sectionTitle("进行中")
                        ForEach(tasks) { task in
                            taskRow(task)
                        }
                    }

                    if !failures.isEmpty {
                        sectionTitle("失败")
                        ForEach(Array(failures.enumerated()), id: \.offset) { _, failure in
                            failureRow(failure)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func taskRow(_ task: LibraryOperationTaskDescriptor) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 3) {
                Text(taskTitle(task.kind))
                    .font(.callout.weight(.medium))
                if let checkpoint = task.lastCheckpointLabel, !checkpoint.isEmpty {
                    Text(checkpoint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func failureRow(_ failure: ImportInputFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(for: failure.url))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(Color.red.opacity(0.06), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func displayName(for url: URL) -> String {
        if !url.path.hasPrefix("/"), url.path.contains("/") {
            return url.path
        }
        let name = url.lastPathComponent
        return name.isEmpty ? url.path : name
    }

    private func taskTitle(_ kind: LibraryTaskKind) -> String {
        switch kind {
        case .importFiles: return "正在导入歌曲"
        case .sourceScan: return "正在扫描来源"
        case .ncmConversion: return "正在转换歌曲"
        case .enrichment: return "正在补全信息"
        case .indexUpdate: return "正在更新资料库"
        case .other: return "正在处理资料库"
        }
    }
}
