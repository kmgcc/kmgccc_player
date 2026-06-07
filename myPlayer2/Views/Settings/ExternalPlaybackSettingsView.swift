//
//  ExternalPlaybackSettingsView.swift
//  myPlayer2
//
//  External playback source management and cache settings.
//

import SwiftUI

@MainActor
func clearExternalPlaybackCachesAction(
    isClearing: Binding<Bool>,
    playbackCoordinator: PlaybackCoordinator
) {
    guard !isClearing.wrappedValue else { return }
    isClearing.wrappedValue = true
    Task {
        await ExternalPlaybackMetadataStore.shared.clearAllCaches()
        playbackCoordinator.clearExternalPlaybackRuntimeCaches()
        isClearing.wrappedValue = false
    }
}

@MainActor
struct ExternalPlaybackSettingsView: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(AppSettings.self) private var settings
    @Environment(\.colorScheme) private var colorScheme

    @State private var sourceStore = ExternalPlaybackSourceStore.shared
    @State private var showClearCacheAlert = false
    @State private var isClearingCaches = false
    @State private var showPlaybackSourceSwitcher: Bool = AppSettings.shared.showPlaybackSourceSwitcher
    @State private var enableSystemNowPlaying: Bool = AppSettings.shared.enableSystemNowPlayingMode
    @State private var appleMusicPermission: ExternalPlaybackPermissionState = .unknown
    @State private var systemNowPlayingPermission: ExternalPlaybackPermissionState = .unknown
    @State private var isCheckingSystemNowPlayingPermission = false
    @State private var activeSourceIDs: [String] = []
    @State private var disabledSourceIDs: [String] = []

    @State private var draggingSourceID: String?
    @State private var dragStartSectionIsDisabled = false
    @State private var dragStartIndex = 0
    @State private var dragLastTargetSectionIsDisabled = false
    @State private var dragLastTargetIndex = 0
    @State private var dragFloatingX: CGFloat = 0
    @State private var dragFloatingY: CGFloat = 0
    @State private var dragContainerWidth: CGFloat = 0
    @State private var dragActiveCount = 0
    @State private var dragDisabledCount = 0
    @State private var isFinishingDrag = false

    private let sourceRowHeight: CGFloat = 40
    private let sourceRowSpacing: CGFloat = 6
    private let sourceSectionTitleHeight: CGFloat = 18
    private let sourceSectionTitleSpacing: CGFloat = 7
    private let sourceSectionSpacing: CGFloat = 10
    private let sourceReorderSpace = "externalPlaybackSourceReorderSpace"
    private let dragHorizontalDamping: CGFloat = 0.45
    private let dragHorizontalLimit: CGFloat = 28

    private var sourceRowStride: CGFloat { sourceRowHeight + sourceRowSpacing }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            SettingsHeaderLabel("外部播放", systemImage: "music.note.tv")

            SettingsSection {
                SettingsSwitchRow(title: "从外部播放", isOn: $showPlaybackSourceSwitcher)
            }

            SettingsSection("Apple Music") {
                permissionRow(
                    title: "权限",
                    state: appleMusicPermission,
                    buttonTitle: permissionButtonTitle(for: appleMusicPermission)
                ) {
                    requestAppleMusicPermission()
                }
            }

            SettingsSection("其他播放器") {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsSwitchRow(title: "启用其他播放器（beta）", isOn: $enableSystemNowPlaying)

                    permissionRow(
                        title: "系统正在播放",
                        state: systemNowPlayingPermission,
                        buttonTitle: permissionButtonTitle(for: systemNowPlayingPermission)
                    ) {
                        requestSystemNowPlayingPermission()
                    }

                    if systemNowPlayingPermission == .manual {
                        Text("无直接权限开关")
                            .settingsDescriptionStyle()
                    }

                    sourcePriorityEditor
                }
            }

            SettingsSection {
                VStack(alignment: .leading, spacing: 12) {
                    Button(role: .destructive) {
                        showClearCacheAlert = true
                    } label: {
                        if isClearingCaches {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("清理外部播放元数据缓存")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .clipShape(Capsule())
                    .disabled(isClearingCaches)

                    Text("清除外部播放匹配、覆盖、封面和歌词缓存。")
                        .settingsDescriptionStyle()
                }
            }
        }
        .onAppear {
            showPlaybackSourceSwitcher = settings.showPlaybackSourceSwitcher
            enableSystemNowPlaying = settings.enableSystemNowPlayingMode
            syncSourceSections()
            refreshPermissionStates()
        }
        .onChange(of: showPlaybackSourceSwitcher) { _, newValue in
            settings.showPlaybackSourceSwitcher = newValue
        }
        .onChange(of: enableSystemNowPlaying) { _, newValue in
            settings.enableSystemNowPlayingMode = newValue
            if !newValue, playbackCoordinator.activeSource == .systemNowPlaying {
                playbackCoordinator.setActiveSource(.local)
            }
        }
        .onChange(of: sourceStore.snapshots) { _, _ in
            syncSourceSections()
        }
        .alert("清理外部播放缓存？", isPresented: $showClearCacheAlert) {
            Button("取消", role: .cancel) {}
            Button("清理", role: .destructive) {
                clearExternalPlaybackCaches()
            }
        } message: {
            Text("将清除外部播放的手动匹配覆盖、匹配结果、联网封面、联网歌词和相关解析缓存。不会删除本地资料库歌曲。")
        }
    }

    private var sourcePriorityEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("播放源优先级")
                    .settingsRowLabelStyle()
                Text("拖动排序")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.08)))
            }

            VStack(alignment: .leading, spacing: 0) {
                sourceSectionTitle("使用中")
                Spacer().frame(height: sourceSectionTitleSpacing)
                sourceRows(ids: activeSourceIDs, isDisabledSection: false)

                Spacer().frame(height: sourceSectionSpacing)

                sourceSectionTitle("禁用")
                Spacer().frame(height: sourceSectionTitleSpacing)
                sourceRows(ids: disabledSourceIDs, isDisabledSection: true)
            }
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { dragContainerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            dragContainerWidth = newValue
                        }
                }
            )
            .coordinateSpace(name: sourceReorderSpace)
            .overlay(alignment: .top) {
                if let draggingSourceID,
                   let snapshot = snapshot(for: draggingSourceID) {
                    sourceFloatingPill(snapshot)
                        .frame(width: dragContainerWidth, height: sourceRowHeight)
                        .offset(x: dragFloatingX, y: dragFloatingY)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func sourceSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(height: sourceSectionTitleHeight, alignment: .center)
    }

    private func sourceRows(ids: [String], isDisabledSection: Bool) -> some View {
        VStack(spacing: sourceRowSpacing) {
            if ids.isEmpty {
                sourceEmptyPill(isDisabledSection: isDisabledSection)
            } else {
                ForEach(ids, id: \.self) { id in
                    if let snapshot = snapshot(for: id) {
                        sourceRow(snapshot, isDisabledSection: isDisabledSection)
                    }
                }
            }
        }
    }

    private func sourceRow(
        _ source: ExternalPlaybackSourceSnapshot,
        isDisabledSection: Bool
    ) -> some View {
        let isDragging = draggingSourceID == source.id
        return ZStack {
            sourcePlaceholderPill()
                .opacity(isDragging ? 1 : 0)
            sourcePill(source, isDisabledSection: isDisabledSection, isFloating: false)
                .opacity(isDragging ? 0 : 1)
        }
        .frame(height: sourceRowHeight)
        .contentShape(Capsule())
        .highPriorityGesture(reorderGesture(for: source, isDisabledSection: isDisabledSection))
    }

    private func sourceEmptyPill(isDisabledSection: Bool) -> some View {
        Text(isDisabledSection ? "没有禁用的播放源" : "尚未检测到播放源")
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, minHeight: sourceRowHeight)
            .background(Capsule().fill(Color.secondary.opacity(0.045)))
            .contentShape(Capsule())
    }

    private func sourcePlaceholderPill() -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.035))
            .frame(maxWidth: .infinity)
            .contentShape(Capsule())
    }

    private func sourceFloatingPill(_ source: ExternalPlaybackSourceSnapshot) -> some View {
        sourcePill(source, isDisabledSection: false, isFloating: true)
    }

    private func sourcePill(
        _ source: ExternalPlaybackSourceSnapshot,
        isDisabledSection: Bool,
        isFloating: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(source.isCurrent && !isDisabledSection ? Color.accentColor : Color.secondary.opacity(0.38))
                .frame(width: 7, height: 7)

            Text(source.displayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isDisabledSection ? .secondary : .primary)
                .lineLimit(1)

            Spacer(minLength: 10)

            if source.isCurrent && !isDisabledSection {
                Text("当前")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            }

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 20)
                .help("拖动排序")
        }
        .padding(.horizontal, 14)
        .frame(height: sourceRowHeight)
        .glassEffect(isDisabledSection ? .clear : .regular, in: Capsule())
        .background(
            Capsule()
                .fill(sourceFillColor(source, isDisabledSection: isDisabledSection, isFloating: isFloating))
        )
        .opacity(isDisabledSection ? 0.62 : 1)
        .shadow(
            color: isFloating ? GlassStyleTokens.subtleShadowColor : .clear,
            radius: isFloating ? GlassStyleTokens.subtleShadowRadius : 0,
            x: 0,
            y: isFloating ? 2 : 0
        )
        .contentShape(Capsule())
    }

    private func sourceFillColor(
        _ source: ExternalPlaybackSourceSnapshot,
        isDisabledSection: Bool,
        isFloating: Bool
    ) -> Color {
        if isDisabledSection {
            return Color.secondary.opacity(0.045)
        }
        if source.isCurrent || isFloating {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.16 : 0.11)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.05 : 0.035)
    }

    private func reorderGesture(
        for source: ExternalPlaybackSourceSnapshot,
        isDisabledSection: Bool
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(sourceReorderSpace))
            .onChanged { value in
                if draggingSourceID != source.id {
                    beginSourceDrag(source.id, isDisabledSection: isDisabledSection)
                }

                let metrics = sourceSectionMetrics(
                    activeCount: dragActiveCount,
                    disabledCount: dragDisabledCount
                )
                let startY = dragStartSectionIsDisabled
                    ? metrics.disabledRowsStart + CGFloat(dragStartIndex) * sourceRowStride
                    : metrics.activeRowsStart + CGFloat(dragStartIndex) * sourceRowStride
                dragFloatingY = startY + value.translation.height
                dragFloatingX = max(
                    -dragHorizontalLimit,
                    min(dragHorizontalLimit, value.translation.width * dragHorizontalDamping)
                )

                let target = targetSectionAndIndex(forCenterY: dragFloatingY + sourceRowHeight / 2)
                guard target.isDisabled != dragLastTargetSectionIsDisabled
                        || target.index != dragLastTargetIndex else { return }
                dragLastTargetSectionIsDisabled = target.isDisabled
                dragLastTargetIndex = target.index
                moveSource(source.id, toDisabledSection: target.isDisabled, index: target.index)
            }
            .onEnded { _ in
                saveSourceSections()
                settleSourceDrag(source.id)
            }
    }

    private func beginSourceDrag(_ id: String, isDisabledSection: Bool) {
        draggingSourceID = id
        dragStartSectionIsDisabled = isDisabledSection
        dragActiveCount = max(activeSourceIDs.count, 1)
        dragDisabledCount = max(disabledSourceIDs.count, 1)
        dragStartIndex = (isDisabledSection ? disabledSourceIDs : activeSourceIDs).firstIndex(of: id) ?? 0
        dragLastTargetSectionIsDisabled = isDisabledSection
        dragLastTargetIndex = dragStartIndex
        isFinishingDrag = false
    }

    private func targetSectionAndIndex(forCenterY centerY: CGFloat) -> (isDisabled: Bool, index: Int) {
        let metrics = sourceSectionMetrics(activeCount: dragActiveCount, disabledCount: dragDisabledCount)
        let isDisabled = centerY >= metrics.disabledTitleStart
        let rowsStart = isDisabled ? metrics.disabledRowsStart : metrics.activeRowsStart
        let baseCount = isDisabled
            ? disabledSourceIDs.filter { $0 != draggingSourceID }.count
            : activeSourceIDs.filter { $0 != draggingSourceID }.count
        let rawIndex = Int(((centerY - rowsStart) / sourceRowStride).rounded(.down))
        return (isDisabled, max(0, min(baseCount, rawIndex)))
    }

    private func moveSource(_ id: String, toDisabledSection isDisabled: Bool, index: Int) {
        var active = activeSourceIDs.filter { $0 != id }
        var disabled = disabledSourceIDs.filter { $0 != id }
        if isDisabled {
            disabled.insert(id, at: max(0, min(disabled.count, index)))
        } else {
            active.insert(id, at: max(0, min(active.count, index)))
        }
        guard active != activeSourceIDs || disabled != disabledSourceIDs else { return }
        withAnimation(.snappy(duration: 0.16)) {
            activeSourceIDs = active
            disabledSourceIDs = disabled
        }
    }

    private func settleSourceDrag(_ id: String) {
        let isDisabled = disabledSourceIDs.contains(id)
        let index = (isDisabled ? disabledSourceIDs : activeSourceIDs).firstIndex(of: id) ?? dragStartIndex
        let metrics = sourceSectionMetrics(
            activeCount: max(activeSourceIDs.count, 1),
            disabledCount: max(disabledSourceIDs.count, 1)
        )
        let finalY = (isDisabled ? metrics.disabledRowsStart : metrics.activeRowsStart)
            + CGFloat(index) * sourceRowStride
        isFinishingDrag = true
        withAnimation(.snappy(duration: 0.16)) {
            dragFloatingX = 0
            dragFloatingY = finalY
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard isFinishingDrag, draggingSourceID == id else { return }
            draggingSourceID = nil
            isFinishingDrag = false
        }
    }

    private func sourceSectionMetrics(
        activeCount: Int,
        disabledCount: Int
    ) -> (activeRowsStart: CGFloat, disabledTitleStart: CGFloat, disabledRowsStart: CGFloat) {
        let activeRowsStart = sourceSectionTitleHeight + sourceSectionTitleSpacing
        let activeHeight = sourceListHeight(count: activeCount)
        let disabledTitleStart = activeRowsStart + activeHeight + sourceSectionSpacing
        let disabledRowsStart = disabledTitleStart + sourceSectionTitleHeight + sourceSectionTitleSpacing
        return (activeRowsStart, disabledTitleStart, disabledRowsStart)
    }

    private func sourceListHeight(count: Int) -> CGFloat {
        let normalized = max(count, 1)
        return CGFloat(normalized) * sourceRowHeight + CGFloat(normalized - 1) * sourceRowSpacing
    }

    private func permissionRow(
        title: String,
        state: ExternalPlaybackPermissionState,
        buttonTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .settingsRowLabelStyle()

            Spacer()

            Text(state.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(state == .allowed ? Color.accentColor : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(state == .allowed ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08))
                )

            if let buttonTitle {
                Button(buttonTitle, action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 12, weight: .medium))
            }
        }
    }

    private func snapshot(for id: String) -> ExternalPlaybackSourceSnapshot? {
        sourceStore.snapshots.first { $0.id == id }
    }

    private func syncSourceSections() {
        guard draggingSourceID == nil else { return }
        let active = sourceStore.snapshots.filter { !$0.isDisabled }.map(\.id)
        let disabled = sourceStore.snapshots.filter(\.isDisabled).map(\.id)
        if activeSourceIDs != active {
            activeSourceIDs = active
        }
        if disabledSourceIDs != disabled {
            disabledSourceIDs = disabled
        }
    }

    private func saveSourceSections() {
        sourceStore.updateSourceSections(
            activeIDs: activeSourceIDs,
            disabledIDs: disabledSourceIDs
        )
    }

    private func refreshPermissionStates() {
        appleMusicPermission = ExternalPlaybackPermissions.appleMusicAutomationStatus(prompt: false)
        refreshSystemNowPlayingPermission()
    }

    private func requestAppleMusicPermission() {
        appleMusicPermission = ExternalPlaybackPermissions.appleMusicAutomationStatus(prompt: true)
        if appleMusicPermission != .allowed {
            ExternalPlaybackPermissions.openAutomationSettings()
        }
    }

    private func requestSystemNowPlayingPermission() {
        if systemNowPlayingPermission == .manual {
            ExternalPlaybackPermissions.openPrivacySettings()
        }
        refreshSystemNowPlayingPermission()
    }

    private func permissionButtonTitle(for state: ExternalPlaybackPermissionState) -> String? {
        switch state {
        case .allowed, .checking:
            return nil
        case .notAllowed, .manual, .unknown:
            return "获取权限"
        }
    }

    private func refreshSystemNowPlayingPermission() {
        guard !isCheckingSystemNowPlayingPermission else { return }
        isCheckingSystemNowPlayingPermission = true
        systemNowPlayingPermission = .checking
        Task {
            let state = await playbackCoordinator.checkSystemNowPlayingAvailability()
            await MainActor.run {
                systemNowPlayingPermission = state
                isCheckingSystemNowPlayingPermission = false
            }
        }
    }

    private func clearExternalPlaybackCaches() {
        clearExternalPlaybackCachesAction(
            isClearing: $isClearingCaches,
            playbackCoordinator: playbackCoordinator
        )
    }
}
