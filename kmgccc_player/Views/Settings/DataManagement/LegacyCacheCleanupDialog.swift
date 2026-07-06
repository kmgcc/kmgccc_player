//
//  LegacyCacheCleanupDialog.swift
//  myPlayer2
//
//  Build 7 legacy cache cleanup prompt.
//

import AppKit
import Observation
import SwiftUI

@MainActor
enum LegacyCacheCleanupDialogPresenter {
    private static var activeController: LegacyCacheCleanupDialogController?

    static func present() {
        if let activeController {
            activeController.bringToFront()
            return
        }

        let controller = LegacyCacheCleanupDialogController()
        activeController = controller
        controller.onClose = {
            activeController = nil
        }
        controller.show()
    }
}

@MainActor
@Observable
private final class LegacyCacheCleanupDialogViewModel {
    enum Stage {
        case prompt
        case running
        case result
    }

    var stage: Stage = .prompt
    var result: LegacyCacheCleanupResult?
    var isRunning = false

    @ObservationIgnored private var task: Task<Void, Never>?

    func clean() {
        guard !isRunning else { return }
        isRunning = true
        stage = .running
        task = Task { [weak self] in
            let result = await LegacyCacheCleanupCoordinator.shared.clearLegacyCaches()
            self?.result = result
            self?.isRunning = false
            self?.stage = .result
            self?.task = nil
        }
    }
}

@MainActor
private final class LegacyCacheCleanupDialogController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let viewModel = LegacyCacheCleanupDialogViewModel()
    var onClose: (() -> Void)?

    func show() {
        guard panel == nil else {
            bringToFront()
            return
        }

        let windowSize = NSSize(width: 520, height: 330)
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.title = ""
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.frame = NSRect(origin: .zero, size: windowSize)
        visualEffect.autoresizingMask = [.width, .height]
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 28
        panel.contentView = visualEffect

        let rootView = LegacyCacheCleanupDialogView(
            viewModel: viewModel,
            onRemindLater: { [weak self] in
                LegacyCacheCleanupCoordinator.shared.remindLater()
                self?.dismiss()
            },
            onDismissPermanently: { [weak self] in
                LegacyCacheCleanupCoordinator.shared.markHandled()
                self?.dismiss()
            },
            onCloseResult: { [weak self] in
                self?.dismiss()
            }
        )
        .environment(AppSettings.shared)
        .environmentObject(ThemeStore.shared)
        .tint(ThemeStore.shared.accentColor)
        .accentColor(ThemeStore.shared.accentColor)
        .frame(width: windowSize.width, height: windowSize.height)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: windowSize)
        hostingView.autoresizingMask = [.width, .height]
        visualEffect.addSubview(hostingView)

        applyCurrentAppearance(to: panel)

        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(NSApp)
        panel.orderFrontRegardless()
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    func bringToFront() {
        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
    }

    func dismiss() {
        guard let panel, !viewModel.isRunning else { return }

        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.18
                panel.animator().alphaValue = 0
            },
            completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let onClose = self.onClose
                    self.onClose = nil
                    self.panel = nil
                    panel.close()
                    onClose?()
                }
            }
        )
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        !viewModel.isRunning
    }

    func windowWillClose(_ notification: Notification) {
        panel = nil
        let onClose = onClose
        self.onClose = nil
        onClose?()
    }

    private func applyCurrentAppearance(to window: NSWindow) {
        let settings = AppSettings.shared
        if settings.followSystemAppearance {
            window.appearance = nil
        } else {
            let appearanceName: NSAppearance.Name = settings.manualAppearance == .dark ? .darkAqua : .aqua
            window.appearance = NSAppearance(named: appearanceName)
        }
    }
}

private struct LegacyCacheCleanupDialogView: View {
    @Bindable var viewModel: LegacyCacheCleanupDialogViewModel
    let onRemindLater: () -> Void
    let onDismissPermanently: () -> Void
    let onCloseResult: () -> Void

    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        SettingsTaskDialog(
            title: headerTitle,
            subtitle: headerSubtitle,
            systemImage: headerIconName,
            iconColor: headerIconColor
        ) {
            contentView
        } footer: {
            footerView
        }
    }

    private var headerTitle: String {
        switch viewModel.stage {
        case .prompt:
            return "缓存体系已更新"
        case .running:
            return "正在清理"
        case .result:
            return "已清理"
        }
    }

    private var headerSubtitle: String {
        switch viewModel.stage {
        case .prompt:
            return "是否清理旧路径中的可再生成缓存"
        case .running:
            return "正在处理"
        case .result:
            return "旧缓存清理已完成"
        }
    }

    private var headerIconName: String {
        switch viewModel.stage {
        case .prompt:
            return "externaldrive.badge.checkmark"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .result:
            return "checkmark.circle.fill"
        }
    }

    private var headerIconColor: Color {
        switch viewModel.stage {
        case .prompt, .running:
            return themeStore.accentColor
        case .result:
            return viewModel.result?.failedItemCount == 0 ? .green : .orange
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.stage {
        case .prompt:
            promptContent
        case .running:
            runningContent
        case .result:
            resultContent
        }
    }

    private var promptContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("现在会把 App 自身的缓存集中到资料库内，减少旧缓存散落。可以现在清理旧路径中的可再生成缓存。")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            SettingsTaskPanel(accentColor: themeStore.accentColor) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("您的数据将保留")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("歌曲文件、播放列表、元数据和手动外部播放规则将保持原样。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningContent: some View {
        SettingsTaskPanel(accentColor: themeStore.accentColor) {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                Text("正在清理旧路径中的缓存。")
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var resultContent: some View {
        SettingsTaskPanel(accentColor: viewModel.result?.failedItemCount == 0 ? .green : .orange) {
            VStack(alignment: .leading, spacing: 10) {
                resultRow("已清理项目", value: "\(viewModel.result?.removedItemCount ?? 0)")
                if let failed = viewModel.result?.failedItemCount, failed > 0 {
                    resultRow("未清理项目", value: "\(failed)")
                    Text("遇到问题，这些项目未清理")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            Spacer()

            switch viewModel.stage {
            case .prompt:
                SettingsTaskDialogButton("稍后", kind: .secondary, action: onRemindLater)
                SettingsTaskDialogButton("不再提示", kind: .secondary, action: onDismissPermanently)
                SettingsTaskDialogButton("清理旧缓存", kind: .primary, action: viewModel.clean)
            case .running:
                SettingsTaskDialogButton("处理中", kind: .secondary, disabled: true, action: {})
            case .result:
                SettingsTaskDialogButton("关闭", kind: .primary, action: onCloseResult)
            }
        }
    }

    private func resultRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.primary)
                .monospacedDigit()
        }
    }
}
