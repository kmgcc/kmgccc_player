//
//  MusicPreferenceResetDialog.swift
//  myPlayer2
//
//  Multi-step liquid-glass dialog for resetting library-wide music preference data.
//

import AppKit
import Observation
import SwiftUI

@MainActor
enum MusicPreferenceResetDialogPresenter {
    private static var activeController: MusicPreferenceResetDialogController?

    static func present(libraryVM: LibraryViewModel, playerVM: PlayerViewModel) {
        if let activeController {
            activeController.bringToFront()
            return
        }

        let controller = MusicPreferenceResetDialogController(libraryVM: libraryVM, playerVM: playerVM)
        activeController = controller
        controller.onClose = {
            activeController = nil
        }
        controller.show()
    }
}

@MainActor
@Observable
private final class MusicPreferenceResetDialogViewModel {
    enum Stage {
        case selection
        case review
        case finalConfirmation
        case running
        case result
    }

    var stage: Stage = .selection
    var options = ResetMusicPreferenceOptions()
    var progress = MusicPreferenceResetProgress(
        processedCount: 0,
        totalCount: 0,
        currentTrackTitle: nil,
        detail: ""
    )
    var result: MusicPreferenceResetResult?
    var isRunning = false

    @ObservationIgnored private let libraryVM: LibraryViewModel
    @ObservationIgnored private let playerVM: PlayerViewModel

    init(libraryVM: LibraryViewModel, playerVM: PlayerViewModel) {
        self.libraryVM = libraryVM
        self.playerVM = playerVM
    }

    var canAdvanceFromSelection: Bool {
        options.hasSelection && !isRunning
    }

    var selectedItemTitles: [String] {
        options.selectedItemTitles
    }

    func goToReviewStep() {
        guard canAdvanceFromSelection else { return }
        stage = .review
    }

    func returnToSelection() {
        guard !isRunning else { return }
        stage = .selection
    }

    func goToFinalConfirmation() {
        guard options.hasSelection, !isRunning else { return }
        stage = .finalConfirmation
    }

    func startReset() {
        guard options.hasSelection, !isRunning else { return }

        isRunning = true
        result = nil
        stage = .running
        progress = MusicPreferenceResetProgress(
            processedCount: 0,
            totalCount: libraryVM.allTracks.count,
            currentTrackTitle: nil,
            detail: "准备修改整个音乐资料库中的 meta.json"
        )

        let tracks = libraryVM.allTracks
        let selectedOptions = options
        playerVM.discardCurrentPlaybackSessionStatsOnce()

        Task {
            let result = await PreferenceResetService.shared.resetLibraryTracks(
                tracks,
                options: selectedOptions
            ) { [weak self] progress in
                self?.progress = progress
            }

            guard !Task.isCancelled else { return }

            libraryVM.notifyTrackAuxiliaryDataChanged(trackIDs: result.updatedTrackIDs)
            self.result = result
            self.isRunning = false
            self.stage = .result
        }
    }
}

@MainActor
private final class MusicPreferenceResetDialogController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private let viewModel: MusicPreferenceResetDialogViewModel
    var onClose: (() -> Void)?

    init(libraryVM: LibraryViewModel, playerVM: PlayerViewModel) {
        self.viewModel = MusicPreferenceResetDialogViewModel(libraryVM: libraryVM, playerVM: playerVM)
        super.init()
    }

    func show() {
        guard panel == nil else {
            bringToFront()
            return
        }

        let windowSize = NSSize(width: 540, height: 560)
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

        let rootView = MusicPreferenceResetDialogView(
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

private struct MusicPreferenceResetDialogView: View {
    @Bindable var viewModel: MusicPreferenceResetDialogViewModel
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
            return "重置音乐偏好数据"
        case .review:
            return "请再次确认"
        case .finalConfirmation:
            return "最后确认重置"
        case .running:
            return "正在重置音乐偏好数据"
        case .result:
            return "音乐偏好数据重置完成"
        }
    }

    private var headerSubtitle: String {
        switch viewModel.stage {
        case .selection:
            return "全库批量操作，会修改所有歌曲的 meta.json。"
        case .review:
            return "整个音乐资料库中的所选播放统计数据将被重置，此操作不可恢复。"
        case .finalConfirmation:
            return "最后确认：全库所选播放统计数据将被清空或重置，此操作不可撤销。"
        case .running:
            return "后台处理中，设置页不会触发额外整库重复扫描。"
        case .result:
            return "已完成全库处理，可在结果摘要中查看成功与失败数量。"
        }
    }

    private var headerIconName: String {
        switch viewModel.stage {
        case .selection, .review, .finalConfirmation:
            return "exclamationmark.triangle.fill"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .result:
            return "checkmark.circle.fill"
        }
    }

    private var headerIconColor: Color {
        switch viewModel.stage {
        case .selection, .review, .finalConfirmation:
            return .orange
        case .running:
            return themeStore.accentColor
        case .result:
            return viewModel.result?.failureCount == 0 ? .green : .orange
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
        case .review:
            reviewContent
        case .finalConfirmation:
            finalConfirmationContent
        case .running:
            runningContent
        case .result:
            resultContent
        }
    }

    private var selectionContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("选择要重置的播放统计数据类别")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 12) {
                ResetOptionToggle(
                    title: "重置自动记录的播放统计与歌曲偏好",
                    detail: "包括播放次数、播放时长、完整播放计数、跳过计数、快速跳过计数、偏好分数与权重缓存",
                    isOn: $viewModel.options.resetPlaybackStatsAndPreference
                )

                ResetOptionToggle(
                    title: "清理旧版残留与废弃缓存",
                    detail: "仅清理统计相关的旧顶层残留与废弃缓存，不影响歌曲正常统计数据。",
                    isOn: $viewModel.options.cleanupLegacyResiduals
                )
            }

            Text("至少勾选一项后才能继续。操作范围是整个音乐资料库，且不可恢复。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var reviewContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("这将重置整个音乐资料库中所选的播放统计数据，并修改对应 meta.json。此操作不可恢复。")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            summaryCard(
                title: "本次将处理",
                items: viewModel.selectedItemTitles
            )

            Text("确认无误后继续进入最后确认。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var finalConfirmationContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("最后确认：所选播放统计数据将被清空或重置；若勾选清理旧版残留与废弃缓存，也会一并清理。此操作不可撤销，不可恢复。")
                .font(.system(size: 14))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            summaryCard(
                title: "确认重置项目",
                items: viewModel.selectedItemTitles
            )

            Text("确认重置后将立即在后台逐首写回 meta.json。")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            summaryCard(
                title: "正在处理整个音乐资料库",
                items: viewModel.selectedItemTitles
            )

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
        VStack(alignment: .leading, spacing: 18) {
            if let result = viewModel.result {
                VStack(alignment: .leading, spacing: 12) {
                    Text("已处理 \(result.successCount) 首，失败 \(result.failureCount) 首。")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)

                    Text("本次未触发额外整库重复扫描，仅对对应歌曲的 meta.json 做了定点写回。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                        Text("失败项")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)

                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                ForEach(result.failures.prefix(8)) { failure in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(failure.title)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.primary)
                                        Text(failure.reason)
                                            .font(.system(size: 12))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 180)
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
                    "下一步",
                    kind: .primary,
                    disabled: !viewModel.canAdvanceFromSelection,
                    action: viewModel.goToReviewStep
                )

            case .review:
                dialogButton("返回修改", kind: .secondary, action: viewModel.returnToSelection)
                dialogButton("继续", kind: .primary, action: viewModel.goToFinalConfirmation)

            case .finalConfirmation:
                dialogButton("取消", kind: .secondary, action: onCancel)
                dialogButton("确认重置", kind: .destructive, action: viewModel.startReset)

            case .running:
                dialogButton("处理中", kind: .secondary, disabled: true, action: {})

            case .result:
                dialogButton("关闭", kind: .primary, action: onCloseResult)
            }
        }
    }

    private func summaryCard(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.primary)

            ForEach(items, id: \.self) { item in
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(themeStore.accentColor)
                    Text(item)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                }
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

    @ViewBuilder
    private func dialogButton(
        _ title: String,
        kind: ResetDialogButtonKind,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: kind == .primary || kind == .destructive ? .semibold : .medium))
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
        .if(kind == .primary || kind == .destructive) { view in
            view.subtleFloatingShadow()
        }
    }
}

private struct ResetOptionToggle: View {
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

private enum ResetDialogButtonKind: Equatable {
    case secondary
    case primary
    case destructive

    var foregroundColor: Color {
        switch self {
        case .secondary:
            return .primary
        case .primary, .destructive:
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
        case .destructive:
            return Color.red.opacity(0.88)
        }
    }
}
