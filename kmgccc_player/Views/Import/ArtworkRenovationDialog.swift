import AppKit
import SwiftUI

@MainActor
final class ArtworkRenovationDialogPresenter: NSObject, NSWindowDelegate {
    private static var activePresenter: ArtworkRenovationDialogPresenter?
    private var panel: NSPanel?
    private weak var source: ArtworkRenovationWorkSource?

    static func present(source: ArtworkRenovationWorkSource) {
        if let activePresenter, activePresenter.source === source, let panel = activePresenter.panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        activePresenter?.panel?.close()
        let presenter = ArtworkRenovationDialogPresenter()
        activePresenter = presenter
        presenter.source = source
        let size = NSSize(width: 520, height: 400)
        let (panel, surface) = AppDialogTokens.makeInsetPanel(contentSize: size)
        presenter.panel = panel
        panel.delegate = presenter
        let content = ArtworkRenovationDialog(source: source) { [weak presenter] in
            presenter?.panel?.close()
        }
        .environmentObject(ThemeStore.shared)
        .frame(width: size.width, height: size.height)
        .padding(AppDialogTokens.panelShadowInset)
        let hosting = AppDialogTokens.makeHostingView(rootView: content)
        hosting.frame = surface.bounds
        hosting.autoresizingMask = [.width, .height]
        surface.addSubview(hosting)
        AppDialogTokens.presentWithMotion(panel)
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        if Self.activePresenter === self { Self.activePresenter = nil }
    }
}

private struct ArtworkRenovationDialog: View {
    let source: ArtworkRenovationWorkSource
    let onClose: () -> Void
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        SettingsTaskDialog(
            title: "资料库封面翻新", subtitle: status, systemImage: "photo.badge.arrow.down",
            iconColor: themeStore.accentColor, onClose: onClose
        ) {
            VStack(alignment: .leading, spacing: 16) {
                Text("旧版本的部分问题可能降低了歌曲封面的画质。正在联网重新查找封面，为资料库换回更清晰的图片。")
                    .foregroundStyle(themeStore.appForegroundPalette.primaryColor)
                    .fixedSize(horizontal: false, vertical: true)
                ProgressView(value: Double(source.completed), total: Double(max(1, source.total)))
                    .tint(themeStore.accentColor)
                if let title = source.currentTitle {
                    Text(title)
                        .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                        .lineLimit(1)
                }
                Text("可能会覆盖曾经手动导入或选择的封面")
                    .foregroundStyle(themeStore.appForegroundPalette.secondaryColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } footer: {
            SettingsTaskDialogButton(String(localized: "artwork.renovation.decline", defaultValue: "我不需要"), kind: .secondary, disabled: source.isDeclined && source.lastError == nil) {
                source.decline()
                onClose()
            }
            SettingsTaskDialogButton(source.isPaused ? "继续" : "暂停", kind: .secondary,
                                     disabled: !source.isReady || source.completed == source.total || source.isDeclined) {
                source.setPaused(!source.isPaused)
            }
            SettingsTaskDialogButton("关闭", kind: .primary, action: onClose)
        }
        .onChange(of: source.isClosed) { _, closed in if closed { onClose() } }
    }

    private var status: String {
        if let error = source.lastError { return error }
        if source.isDeclined { return "已结束翻新" }
        let counts = "已检查 \(source.completed)/\(source.total) 首，已翻新 \(source.updated) 首"
        if source.isPaused { return "已暂停，下次启动继续" }
        if source.completed == source.total {
            return source.failed > 0 ? "翻新结束，\(source.failed) 首未能完成" : "翻新完成"
        }
        return counts
    }
}
