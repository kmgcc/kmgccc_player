import SwiftUI

/// The settings surface uses these two rows everywhere instead of mixing
/// native list rows with custom controls. Keeping the visual grammar in one
/// place makes long paths, dark mode, and narrow settings windows predictable.
struct MusicLibrarySettingsRow: View {
    let name: String
    let path: String
    let mode: MusicLibraryMode
    let isActive: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(themeStore.accentColor)
                        .frame(width: 38, height: 38)
                        .background(
                            themeStore.accentColor.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(name)
                            .font(.body.weight(.medium))
                            .foregroundStyle(isActive ? themeStore.accentColor : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        HStack(spacing: 6) {
                            Text(path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path)
                            Text(shortModeTitle)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(isActive ? themeStore.accentColor : .secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    (isActive ? themeStore.accentColor : Color.primary).opacity(0.07),
                                    in: Capsule(style: .continuous)
                                )
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button("在访达中显示", action: onReveal)
                Divider()
                Button("移到废纸篓…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .help("资料库操作")
            .accessibilityLabel("资料库操作")
        }
        .padding(14)
        .background(
            (isActive ? themeStore.accentColor : Color.primary).opacity(isActive ? 0.09 : 0.035),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
    }

    private var shortModeTitle: String {
        switch mode {
        case .managed: return "收集"
        case .referenced: return "原位"
        }
    }
}

struct MusicSourceSettingsRow: View {
    let name: String
    let path: String
    let mode: ReferencedSourceMode
    let status: ReferencedSourceStatus
    let isScanning: Bool
    let scanFailed: Bool
    let onRescan: () -> Void
    let onReconnect: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(spacing: 12) {
            sourceIcon

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("正在扫描")
            } else if let statusLabel {
                Text(statusLabel)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(statusColor.opacity(0.11), in: Capsule(style: .continuous))
            }

            Menu {
                Button("重新扫描", action: onRescan)
                if status != .available || scanFailed {
                    Button("重新连接…", action: onReconnect)
                }
                Divider()
                Button("移除来源…", role: .destructive, action: onRemove)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .foregroundStyle(.secondary)
            .help("来源操作")
            .accessibilityLabel("来源操作")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var sourceIcon: some View {
        if mode == .directory {
            Image(systemName: "folder.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 32, height: 32)
                .background(
                    themeStore.accentColor.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
        } else {
            Image(systemName: "music.note")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(themeStore.accentColor)
                .frame(width: 32, height: 32)
        }
    }

    private var statusLabel: String? {
        if scanFailed { return "扫描失败" }
        switch status {
        case .available: return nil
        case .stale: return "需授权"
        case .permissionDenied: return "无权限"
        case .offline: return "离线"
        }
    }

    private var statusColor: Color {
        if scanFailed { return .orange }
        switch status {
        case .available: return .secondary
        case .stale, .permissionDenied: return .orange
        case .offline: return .secondary
        }
    }
}
