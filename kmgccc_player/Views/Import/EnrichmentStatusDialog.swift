//
//  EnrichmentStatusDialog.swift
//  myPlayer2
//
//  kmgccc_player - 后台补全状态对话框
//  点击 sidebar 的补全进度通知弹出，逐首显示补全状态。
//  视觉模式复用 BatchImportProgressDialog（浮动面板 + 逐行列表）。
//

import AppKit
import SwiftUI

@MainActor
final class EnrichmentStatusDialogPresenter: NSObject, NSWindowDelegate {
    private var panel: NSPanel?

    private static var activePresenter: EnrichmentStatusDialogPresenter?

    static func present(service: ImportEnrichmentService) {
        if let activePresenter, let panel = activePresenter.panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let presenter = EnrichmentStatusDialogPresenter()
        Self.activePresenter = presenter

        let windowSize = NSSize(width: 560, height: 520)
        let (panel, visualEffect) = AppDialogTokens.makePanel(
            width: windowSize.width,
            height: windowSize.height
        )
        panel.delegate = presenter
        presenter.panel = panel

        let rootView = EnrichmentStatusDialogView(service: service) { [weak presenter] in
            presenter?.panel?.close()
        }
        .environmentObject(ThemeStore.shared)
        .frame(width: windowSize.width, height: windowSize.height)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        AppDialogTokens.presentWithFade(panel)
    }

    static func close() {
        activePresenter?.panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        Self.activePresenter = nil
    }
}

private struct EnrichmentStatusDialogView: View {
    let service: ImportEnrichmentService
    let onClose: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    private var progress: ImportEnrichmentProgressSnapshot { service.progress }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider().opacity(0.45)

            if service.enrichmentRows.isEmpty {
                emptyView
            } else {
                rowList
            }

            Divider().opacity(0.35)

            footerView
        }
    }

    private var headerView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("正在补全导入内容")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)

                Spacer(minLength: 0)

                Text("已补全 \(progress.completedCount)/\(progress.totalEnqueued)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)

                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 20, height: 20)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                .help("关闭")
            }

            if progress.totalEnqueued > 0 {
                ProgressView(value: Double(progress.completedCount) / Double(progress.totalEnqueued))
                    .progressViewStyle(.linear)
                    .controlSize(.small)
                    .tint(themeStore.accentColor)
            }

            if progress.failedCount > 0 {
                Text("失败 \(progress.failedCount) 首")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var emptyView: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("暂无补全任务")
                .font(.callout)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rowList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(service.enrichmentRows) { row in
                    EnrichmentStatusRowView(row: row)
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerView: some View {
        HStack {
            Text("补全在后台进行，可关闭此窗口")
                .font(.caption)
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)

            Spacer(minLength: 0)

            Button("关闭", action: onClose)
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(themeStore.accentColor)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(themeStore.accentColor.opacity(0.14))
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct EnrichmentStatusRowView: View {
    let row: ImportEnrichmentRowSnapshot

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        HStack(spacing: 10) {
            statusIcon
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title.isEmpty ? "未知歌曲" : row.title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .lineLimit(1)

                if row.artist.isEmpty == false {
                    Text(row.artist)
                        .font(.caption)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(1)
                }

                if row.status == .running, row.activePartLabels.isEmpty == false {
                    Text("正在补全：\(row.activePartLabels.joined(separator: "・"))")
                        .font(.caption)
                        .foregroundStyle(themeStore.accentColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if row.status == .failed, row.failedPartLabels.isEmpty == false {
                    Text(row.failedPartLabels.joined(separator: "·"))
                        .font(.caption)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(1)
                }
                Text(row.status.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.status {
        case .waiting:
            Image(systemName: "clock")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
        case .running:
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.7)
        case .flushPending:
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(themeStore.accentColor)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.orange)
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .waiting:
            return themeStore.appForegroundPalette.secondaryColor
        case .running, .flushPending:
            return themeStore.accentColor
        case .completed:
            return themeStore.appForegroundPalette.secondaryColor
        case .failed:
            return Color.orange
        }
    }
}
