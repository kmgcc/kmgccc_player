//
//  AlbumOrderingFailureViews.swift
//  myPlayer2
//
//  Bottom-right notice and consolidated failure list for online album ordering.
//  Both surfaces reuse the shared popup components (PopupKit / AppPopupFrame).
//

import AppKit
import PopupKit
import SwiftUI

@MainActor
final class AlbumOrderingFailureDialogPresenter: NSObject, NSWindowDelegate {
    private static var activePresenter: AlbumOrderingFailureDialogPresenter?
    private var panel: NSPanel?

    static func present(uiState: UIStateViewModel, appSession: AppSessionHost) {
        if let activePresenter, let panel = activePresenter.panel {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let presenter = AlbumOrderingFailureDialogPresenter()
        Self.activePresenter = presenter

        let size = NSSize(width: 560, height: 460)
        let (panel, surface) = AppDialogTokens.makeInsetPanel(contentSize: size)
        panel.delegate = presenter
        presenter.panel = panel

        let rootView = AlbumOrderingFailureDialogView(
            uiState: uiState,
            appSession: appSession,
            onClose: { [weak presenter] in presenter?.panel?.close() }
        )
        .environmentObject(ThemeStore.shared)
        .frame(width: size.width, height: size.height)
        .padding(AppDialogTokens.panelShadowInset)

        let hostingView = AppDialogTokens.makeHostingView(rootView: rootView)
        hostingView.frame = surface.bounds
        hostingView.autoresizingMask = [.width, .height]
        surface.addSubview(hostingView)

        AppDialogTokens.presentWithMotion(panel)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        if Self.activePresenter === self {
            Self.activePresenter = nil
        }
    }
}

private struct AlbumOrderingFailureDialogView: View {
    @Bindable var uiState: UIStateViewModel
    let appSession: AppSessionHost
    let onClose: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore
    @State private var retryingAlbumKeys: Set<String> = []

    var body: some View {
        SettingsTaskDialog(
            title: "专辑曲序",
            subtitle: subtitle,
            systemImage: "exclamationmark.triangle",
            iconColor: .orange,
            onClose: onClose
        ) {
            if uiState.albumOrderingFailures.isEmpty {
                ContentUnavailableView(
                    "暂无待处理记录",
                    systemImage: "checkmark.circle"
                )
            } else {
                AppPopupScrollRegion {
                    LazyVStack(spacing: AppPopupStyle().rowSpacing) {
                        ForEach(uiState.albumOrderingFailures) { failure in
                            failureRow(failure)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } actions: {
                    EmptyView()
                }
            }
        } footer: {
            SettingsTaskDialogButton("清除记录", kind: .secondary) {
                uiState.clearAlbumOrderingFailures()
            }
            SettingsTaskDialogButton(
                "全部重试",
                kind: .secondary,
                disabled: uiState.albumOrderingFailures.isEmpty || !retryingAlbumKeys.isEmpty
            ) {
                retryAll()
            }
            SettingsTaskDialogButton("完成", kind: .primary, action: onClose)
        }
    }

    private var subtitle: String {
        let count = uiState.albumOrderingFailures.count
        return count == 0 ? "已处理" : "\(count) 张专辑"
    }

    private func failureRow(_ failure: AlbumOrderingFailure) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.orange)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(failure.albumTitle.isEmpty ? "未知专辑" : failure.albumTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .lineLimit(1)
                if !failure.artist.isEmpty {
                    Text(failure.artist)
                        .font(.caption)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(1)
                }
                Text(failure.detail)
                    .font(.caption)
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                Button("打开") {
                    openAlbum(failure.albumKey)
                }
                .buttonStyle(AppDialogGlassButtonStyle())
                .disabled(albumExists(failure.albumKey) == false)

                Button(retryingAlbumKeys.contains(failure.albumKey) ? "重试中" : "重试") {
                    Task { await retry(failure.albumKey) }
                }
                .buttonStyle(AppDialogGlassButtonStyle(kind: .secondary))
                .disabled(retryingAlbumKeys.contains(failure.albumKey))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .appPopupContentBackground(cornerRadius: 10)
    }

    private func albumExists(_ albumKey: String) -> Bool {
        appSession.libraryVM?.runtimeAlbums.contains { $0.key == albumKey } == true
    }

    private func openAlbum(_ albumKey: String) {
        guard let libraryVM = appSession.libraryVM,
              let album = libraryVM.runtimeAlbums.first(where: { $0.key == albumKey })
        else { return }
        libraryVM.selectAlbum(album)
        onClose()
    }

    private func retryAll() {
        let keys = uiState.albumOrderingFailures.map(\.albumKey)
        Task {
            for key in keys where !retryingAlbumKeys.contains(key) {
                await retry(key)
            }
        }
    }

    private func retry(_ albumKey: String) async {
        guard !retryingAlbumKeys.contains(albumKey) else { return }
        retryingAlbumKeys.insert(albumKey)
        defer { retryingAlbumKeys.remove(albumKey) }
        guard let libraryVM = appSession.libraryVM else { return }
        let outcome = await libraryVM.organizeAlbumTrackOrder(albumKey: albumKey)
        if outcome.updatedAlbumCount > 0 {
            await libraryVM.syncVisibleStateFromRepositoryAfterImport()
        }
    }
}
