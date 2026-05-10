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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            headerView
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()
                .opacity(0.25)

            contentView
                .padding(20)

            Divider()
                .opacity(0.25)

            footerView
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 40)
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
            return "扫描整个本地曲库，只填充缺失项。"
        case .running:
            return viewModel.progress.phase.title
        case .result:
            return "已生成本次处理结果摘要。"
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

    private var headerView: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(headerIconColor.opacity(colorScheme == .dark ? 0.18 : 0.12))
                    .frame(width: 54, height: 54)
                Image(systemName: headerIconName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(headerIconColor)
            }
            .liquidGlassCircle(
                colorScheme: colorScheme,
                accentColor: headerIconColor,
                prominence: .prominent,
                isFloating: true
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(headerTitle)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
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
            Text("本次会扫描整个本地曲库，只补全缺失信息；已有元数据、封面和歌词不会被覆盖。")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                CompletionOptionToggle(
                    title: "补全元数据",
                    detail: "包括歌曲缺失字段、封面、专辑信息、艺人信息、描述、年份等可由外部来源补全的空字段",
                    isOn: $viewModel.options.fillMetadata
                )

                CompletionOptionToggle(
                    title: "补全歌词",
                    detail: "只为没有歌词的歌曲查找并保存歌词，不替换已保存歌词",
                    isOn: $viewModel.options.fillLyrics
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                safetyRow("字段级合并，不用搜索结果整体覆盖本地数据")
                safetyRow("已有歌曲、专辑、艺人封面都会保留")
                safetyRow("网络失败或单曲匹配失败会记录后继续处理")
            }
            .padding(14)
            .liquidGlassRect(
                cornerRadius: 16,
                colorScheme: colorScheme,
                accentColor: themeStore.accentColor,
                prominence: .standard
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryCard(title: "正在处理", items: viewModel.selectedItemTitles)

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

                Text(viewModel.progress.phase.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)

                if let currentTrackTitle = viewModel.progress.currentTrackTitle,
                   !currentTrackTitle.isEmpty {
                    Text("当前：\(currentTrackTitle)")
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Text(viewModel.progress.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .liquidGlassRect(
                cornerRadius: 18,
                colorScheme: colorScheme,
                accentColor: themeStore.accentColor,
                prominence: .standard
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var resultContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let result = viewModel.result {
                VStack(alignment: .leading, spacing: 10) {
                    resultRow("处理歌曲", value: "\(result.processedTrackCount) 首")
                    resultRow("补全元数据", value: "\(result.metadataItemsFilledCount) 项")
                    resultRow("补全歌词", value: "\(result.lyricsFilledTrackCount) 首")
                    resultRow("跳过已有数据", value: "\(result.skippedExistingDataCount) 项")
                    resultRow("失败", value: "\(result.failureCount) 项")
                }
                .padding(16)
                .liquidGlassRect(
                    cornerRadius: 18,
                    colorScheme: colorScheme,
                    accentColor: result.failureCount == 0 ? .green : .orange,
                    prominence: .standard
                )

                if !result.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("失败原因")
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
                dialogButton("取消", kind: .secondary, action: onCancel)
                dialogButton(
                    "开始补全",
                    kind: .primary,
                    disabled: !viewModel.canStart,
                    action: viewModel.start
                )
            case .running:
                dialogButton("取消操作", kind: .secondary, action: viewModel.cancel)
            case .result:
                dialogButton("关闭", kind: .primary, action: onCloseResult)
            }
        }
    }

    private func safetyRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(themeStore.accentColor)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private func summaryCard(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            ForEach(items, id: \.self) { item in
                safetyRow(item)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassRect(
            cornerRadius: 18,
            colorScheme: colorScheme,
            accentColor: themeStore.accentColor,
            prominence: .standard
        )
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

    @ViewBuilder
    private func dialogButton(
        _ title: String,
        kind: CompletionDialogButtonKind,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: kind == .primary ? .semibold : .medium))
                .foregroundStyle(kind.foregroundColor)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .background(kind.backgroundColor)
        .overlay(
            Capsule()
                .strokeBorder(GlassStyleTokens.glassBorderColor, lineWidth: GlassStyleTokens.hairlineWidth)
        )
        .glassEffect(.clear, in: Capsule())
        .clipShape(Capsule())
        .if(kind == .primary) { view in
            view.subtleFloatingShadow()
        }
    }
}

private struct CompletionOptionToggle: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var themeStore: ThemeStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .toggleStyle(.checkbox)

            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlassRect(
            cornerRadius: 16,
            colorScheme: colorScheme,
            accentColor: isOn ? themeStore.accentColor : nil,
            prominence: isOn ? .prominent : .standard
        )
    }
}

private enum CompletionDialogButtonKind: Equatable {
    case secondary
    case primary

    var foregroundColor: Color {
        switch self {
        case .secondary:
            return .primary
        case .primary:
            return .white
        }
    }

    var backgroundColor: some View {
        Capsule()
            .fill(fillColor)
    }

    private var fillColor: Color {
        switch self {
        case .secondary:
            return Color.black.opacity(0.08)
        case .primary:
            return ThemeStore.shared.accentColor.opacity(0.88)
        }
    }
}
