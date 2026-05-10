//
//  LibraryCompletionDialog.swift
//  myPlayer2
//
//  Manual library-wide missing metadata and lyrics completion dialog.
//

import AppKit
import Observation
import SwiftUI

@MainActor
enum LibraryCompletionDialogPresenter {
    private static var activeController: LibraryCompletionDialogController?

    static func present(libraryVM: LibraryViewModel) {
        if let activeController {
            activeController.bringToFront()
            return
        }

        let controller = LibraryCompletionDialogController(libraryVM: libraryVM)
        activeController = controller
        controller.onClose = {
            activeController = nil
        }
        controller.show()
    }
}

@MainActor
@Observable
private final class LibraryCompletionDialogViewModel {
    enum Stage {
        case selection
        case running
        case result
    }

    var stage: Stage = .selection
    var options = LibraryCompletionOptions()
    var progress: LibraryCompletionProgress = .idle
    var result: LibraryCompletionResult?
    var isRunning = false

    @ObservationIgnored private let service: LibraryCompletionService
    @ObservationIgnored private var task: Task<Void, Never>?

    init(libraryVM: LibraryViewModel) {
        service = LibraryCompletionService(libraryVM: libraryVM)
    }

    var canStart: Bool {
        options.hasSelection && !isRunning
    }

    var selectedItemTitles: [String] {
        options.selectedItemTitles
    }

    func start() {
        guard canStart else { return }
        isRunning = true
        result = nil
        stage = .running
        progress = LibraryCompletionProgress(
            phase: .scanning,
            processedCount: 0,
            totalCount: 0,
            currentTrackTitle: nil,
            currentArtist: nil,
            currentAlbum: nil,
            currentTaskLabel: nil,
            recentEvents: [],
            detail: "正在准备扫描整个本地曲库"
        )

        let selectedOptions = options
        task = Task { [weak self] in
            guard let self else { return }
            let result = await service.completeLibrary(options: selectedOptions) { [weak self] progress in
                self?.progress = progress
            }
            guard !Task.isCancelled || result.cancelled else { return }
            self.result = result
            self.isRunning = false
            self.stage = .result
            self.task = nil
        }
    }

    func cancel() {
        guard isRunning else { return }
        progress = LibraryCompletionProgress(
            phase: .cancelled,
            processedCount: progress.processedCount,
            totalCount: progress.totalCount,
            currentTrackTitle: progress.currentTrackTitle,
            currentArtist: progress.currentArtist,
            currentAlbum: progress.currentAlbum,
            currentTaskLabel: progress.currentTaskLabel,
            recentEvents: progress.recentEvents,
            detail: "正在取消，当前请求结束后停止继续处理"
        )
        task?.cancel()
    }
}

@MainActor
private final class LibraryCompletionDialogController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let viewModel: LibraryCompletionDialogViewModel
    var onClose: (() -> Void)?

    init(libraryVM: LibraryViewModel) {
        viewModel = LibraryCompletionDialogViewModel(libraryVM: libraryVM)
        super.init()
    }

    func show() {
        guard panel == nil else {
            bringToFront()
            return
        }

        let windowSize = NSSize(width: 560, height: 580)
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

        let rootView = LibraryCompletionDialogView(
            viewModel: viewModel,
            onCancel: { [weak self] in
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
        panel.makeKeyAndOrderFront(nil)
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

private struct LibraryCompletionDialogView: View {
    @Bindable var viewModel: LibraryCompletionDialogViewModel
    let onCancel: () -> Void
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
        case .selection:
            return "手动补全所有歌曲信息"
        case .running:
            return "正在补全本地曲库"
        case .result:
            return viewModel.result?.cancelled == true ? "补全已取消" : "补全完成"
        }
    }

    private var headerSubtitle: String {
        switch viewModel.stage {
        case .selection:
            return "选择补全范围。"
        case .running:
            return "处理中，可随时取消。"
        case .result:
            return "已生成本次补全结果摘要。"
        }
    }

    private var headerIconName: String {
        switch viewModel.stage {
        case .selection:
            return "wand.and.sparkles"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .result:
            return viewModel.result?.cancelled == true ? "stop.circle.fill" : "checkmark.circle.fill"
        }
    }

    private var headerIconColor: Color {
        switch viewModel.stage {
        case .selection, .running:
            return themeStore.accentColor
        case .result:
            guard let result = viewModel.result else { return themeStore.accentColor }
            if result.cancelled { return .orange }
            return result.failureCount == 0 ? .green : .orange
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch viewModel.stage {
        case .selection:
            selectionContent
        case .running:
            runningContent
        case .result:
            resultContent
        }
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("扫描本地曲库，补全缺失内容。已有歌曲信息、封面和歌词会保留。")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                SettingsTaskOptionToggle(
                    title: "补全歌曲信息",
                    detail: "补全歌曲资料、封面、专辑和艺人信息。",
                    isOn: $viewModel.options.fillMetadata
                )

                SettingsTaskOptionToggle(
                    title: "补全歌词",
                    detail: "为没有歌词的歌曲查找并保存歌词。",
                    isOn: $viewModel.options.fillLyrics
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsTaskPanel(accentColor: themeStore.accentColor) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("已处理 \(viewModel.progress.processedCount) / \(viewModel.progress.totalCount)")
                            .font(.system(size: 14, weight: .medium))
                        Spacer()
                        Text("\(Int(viewModel.progress.fractionCompleted * 100))%")
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: viewModel.progress.fractionCompleted)
                        .progressViewStyle(.linear)

                    HStack(spacing: 8) {
                        if let currentTaskLabel = viewModel.progress.currentTaskLabel,
                           !currentTaskLabel.isEmpty {
                            Text(currentTaskLabel)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(themeStore.accentColor.opacity(0.88)))
                        }

                        Spacer()
                    }

                    if let currentTrackTitle = viewModel.progress.currentTrackTitle,
                       !currentTrackTitle.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentTrackTitle)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            if !currentTrackSubtitle.isEmpty {
                                Text(currentTrackSubtitle)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            if !viewModel.progress.recentEvents.isEmpty {
                SettingsTaskPanel(accentColor: nil) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("已找到内容")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)

                        ForEach(viewModel.progress.recentEvents) { event in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "sparkle.magnifyingglass")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(themeStore.accentColor)
                                    .frame(width: 18, height: 18)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(.primary)
                                    Text(event.detail)
                                        .font(.system(size: 12))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }

                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = viewModel.result {
                SettingsTaskPanel(accentColor: result.failureCount == 0 ? .green : .orange) {
                    VStack(alignment: .leading, spacing: 10) {
                        resultRow("已检查", value: "\(result.processedTrackCount) 首")
                        resultRow("已补全信息", value: "\(result.metadataItemsFilledCount) 项")
                        resultRow("已补全歌词", value: "\(result.lyricsFilledTrackCount) 首")
                        resultRow("已跳过已有内容", value: "\(result.skippedExistingDataCount) 项")
                        resultRow("未找到", value: "\(result.failureCount) 项")
                    }
                }

                if !result.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("未补全项目")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(result.failures.prefix(8)) { failure in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(failure.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                        Text(failure.reason)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 150)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            Spacer()

            switch viewModel.stage {
            case .selection:
                SettingsTaskDialogButton("取消", kind: .secondary, action: onCancel)
                SettingsTaskDialogButton(
                    "开始补全",
                    kind: .primary,
                    disabled: !viewModel.canStart,
                    action: viewModel.start
                )
            case .running:
                SettingsTaskDialogButton("取消操作", kind: .secondary, action: viewModel.cancel)
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

    private var currentTrackSubtitle: String {
        [
            viewModel.progress.currentArtist,
            viewModel.progress.currentAlbum
        ]
        .compactMap { value in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        .joined(separator: " · ")
    }
}
