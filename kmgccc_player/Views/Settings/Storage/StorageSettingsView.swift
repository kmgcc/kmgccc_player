//
//  StorageSettingsView.swift
//  kmgccc_player
//
//  Settings › Storage: what the App occupies, and cleaning by category.
//

import MotionKit
import SwiftUI

struct StorageSettingsView: View {
    @EnvironmentObject private var appSession: AppSessionHost
    @EnvironmentObject private var themeStore: ThemeStore
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    @State private var model = StorageUsageModel()
    @State private var showRebuildIndexAlert = false
    @State private var isRebuildingIndex = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsStyleTokens.sectionSpacing) {
            SettingsSection {
                StorageOverview(
                    libraryName: libraryName,
                    report: model.report,
                    colors: categoryColors
                )
            }

            SettingsSection("资料库") {
                VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
                    row(musicCategory)
                    Divider()
                    row(.libraryContent)
                    Divider()
                    row(.indexes) {
                        StorageActionButton(title: "重建", isBusy: isRebuildingIndex) {
                            showRebuildIndexAlert = true
                        }
                    }
                }
            }

            SettingsSection("缓存") {
                VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
                    ForEach(StorageCategory.cacheCategories) { category in
                        row(category) {
                            StorageActionButton(
                                title: "清理",
                                isBusy: model.busyCategories.contains(category),
                                isDisabled: (model.report?.bytes(for: category) ?? 0) == 0
                            ) {
                                clean([category])
                            }
                        }
                        Divider()
                    }
                    VStack(alignment: .leading, spacing: SettingsStyleTokens.inlineSpacing) {
                        StorageActionButton(
                            title: "清理全部缓存",
                            isBusy: !model.busyCategories.isDisjoint(with: StorageCategory.cacheCategories),
                            isDisabled: (model.report?.cleanableBytes ?? 0) == 0
                        ) {
                            clean(StorageCategory.cacheCategories)
                        }
                        Text("App 会在空闲时也会整理缓存，让它们保持在各自的上限以内；清理后，需要的内容会在使用时重新生成。")
                            .settingsDescriptionStyle()
                    }
                }
            }

            SettingsSection("App") {
                row(.appData)
            }

            if !model.otherLibraries.isEmpty {
                SettingsSection("其他资料库") {
                    VStack(alignment: .leading, spacing: SettingsStyleTokens.groupSpacing) {
                        ForEach(Array(model.otherLibraries.enumerated()), id: \.element.id) { index, library in
                            if index > 0 { Divider() }
                            otherLibraryRow(library)
                        }
                    }
                }
            }
        }
        .motionAnimation(.microInteraction, value: model.report)
        .task { await refresh() }
        .alert("重建索引？", isPresented: $showRebuildIndexAlert) {
            Button("取消", role: .cancel) {}
            Button("重建") { rebuildIndex() }
        } message: {
            Text("索引会清空，并重新扫描整个资料库；响度测量结果会保留。")
        }
    }

    // MARK: - Rows

    private func row(_ category: StorageCategory) -> some View {
        row(category) { EmptyView() }
    }

    private func row<Action: View>(
        _ category: StorageCategory,
        @ViewBuilder action: () -> Action
    ) -> some View {
        StorageCategoryRow(
            title: category.title,
            detail: category.detail,
            color: categoryColors[category] ?? .secondary,
            size: model.report.map { $0.bytes(for: category) },
            action: action()
        )
    }

    private func otherLibraryRow(_ library: InactiveLibraryUsage) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(library.displayName)
                    .settingsRowLabelStyle()
                Text("共 \(formatted(library.totalBytes))，其中缓存 \(formatted(library.cleanableBytes))")
                    .settingsDescriptionStyle()
            }
            Spacer(minLength: 16)
            StorageActionButton(
                title: "清理缓存",
                isBusy: model.busyLibraryIDs.contains(library.id),
                isDisabled: library.cleanableBytes == 0
            ) {
                Task {
                    await model.clearCaches(of: library)
                    await refresh()
                }
            }
        }
    }

    // MARK: - Actions

    private func clean(_ categories: [StorageCategory]) {
        Task {
            await model.clear(categories, services: cacheServices)
            if categories.contains(.onlineCache) {
                playbackCoordinator.clearExternalPlaybackRuntimeCaches()
            }
            await refresh()
        }
    }

    private func rebuildIndex() {
        guard !isRebuildingIndex else { return }
        isRebuildingIndex = true
        Task {
            await libraryVM.clearIndexCacheAndRebuild()
            isRebuildingIndex = false
            await refresh()
        }
    }

    private func refresh() async {
        guard let context = appSession.activeLibraryBinding.context else { return }
        let registry = await appSession.musicLibraryRegistrySnapshot()
        await model.refresh(
            storage: cacheServices.storageLocations,
            activeLibraryID: context.id,
            tracks: libraryVM.allTracks,
            registry: registry
        )
    }

    // MARK: - Presentation

    private var libraryName: String {
        model.activeLibraryName ?? "资料库"
    }

    private var musicCategory: StorageCategory {
        appSession.activeLibraryBinding.context?.mode == .referenced ? .externalMusic : .music
    }

    private var categoryColors: [StorageCategory: Color] {
        let colors = themeStore.artworkSwatchColors(count: StorageCategory.allCases.count)
        return Dictionary(uniqueKeysWithValues: zip(StorageCategory.allCases, colors))
    }
}

// MARK: - Overview

private struct StorageOverview: View {
    let libraryName: String
    let report: StorageUsageReport?
    let colors: [StorageCategory: Color]

    @Environment(\.settingsAppForegroundColors) private var appColors

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(libraryName)
                    .settingsRowLabelStyle()
                    .lineLimit(1)
                Spacer(minLength: 16)
                Text(report.map { "共 \(formatted($0.totalBytes))" } ?? "正在计算…")
                    .settingsRowLabelStyle()
                    .monospacedDigit()
            }

            StorageUsageBar(segments: segments, trackColor: trackColor)
                .frame(height: 16)

            if !segments.isEmpty {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                    alignment: .leading,
                    spacing: 8
                ) {
                    ForEach(segments, id: \.category) { segment in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(segment.color)
                                .frame(width: 8, height: 8)
                            Text(segment.category.title)
                                .settingsDescriptionStyle()
                                .lineLimit(1)
                        }
                    }
                }
            }

            if let available = report?.volumeAvailableBytes {
                Text("资料库所在的磁盘还有 \(formatted(available)) 可用。")
                    .settingsDescriptionStyle()
            }
        }
    }

    private var segments: [StorageUsageBar.Segment] {
        guard let report else { return [] }
        return StorageCategory.allCases.compactMap { category in
            let bytes = report.bytes(for: category)
            guard bytes > 0 else { return nil }
            return StorageUsageBar.Segment(
                category: category,
                bytes: bytes,
                color: colors[category] ?? .secondary
            )
        }
    }

    private var trackColor: Color {
        (appColors?.secondary ?? .secondary).opacity(0.12)
    }
}

/// Apple-style proportional bar: one coloured run per category, separated
/// by a hairline gap so neighbouring colours stay distinct.
private struct StorageUsageBar: View {
    struct Segment {
        let category: StorageCategory
        let bytes: Int64
        let color: Color
    }

    let segments: [Segment]
    let trackColor: Color

    private let gap: CGFloat = 2
    private let minimumWidth: CGFloat = 3

    var body: some View {
        GeometryReader { proxy in
            let widths = segmentWidths(in: proxy.size.width)
            HStack(spacing: gap) {
                ForEach(Array(segments.enumerated()), id: \.offset) { index, segment in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: widths[index])
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .leading)
            .background(trackColor)
            .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
    }

    /// Widths sum to exactly the bar width, so the segments reach both ends.
    private func segmentWidths(in totalWidth: CGFloat) -> [CGFloat] {
        let total = segments.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else { return [] }
        let usable = max(0, totalWidth - gap * CGFloat(max(0, segments.count - 1)))
        var widths = segments.map { max(minimumWidth, usable * CGFloat($0.bytes) / CGFloat(total)) }
        // Minimum widths push the sum past `usable`; the largest segment gives back the difference.
        let overflow = widths.reduce(0, +) - usable
        if overflow > 0, let largest = widths.indices.max(by: { widths[$0] < widths[$1] }) {
            widths[largest] -= overflow
        }
        return widths
    }

    private var accessibilitySummary: String {
        segments.map { "\($0.category.title) \(formatted($0.bytes))" }.joined(separator: "，")
    }
}

// MARK: - Row

private struct StorageCategoryRow<Action: View>: View {
    let title: String
    let detail: String
    let color: Color
    let size: Int64?
    let action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .settingsRowLabelStyle()
                Text(detail)
                    .settingsDescriptionStyle()
            }
            Spacer(minLength: 16)
            Text(size.map(formatted) ?? "—")
                .settingsRowLabelStyle()
                .monospacedDigit()
            action
        }
    }
}

private struct StorageActionButton: View {
    let title: String
    var isBusy = false
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(AppPanelButtonStyle())
            .disabled(isBusy || isDisabled)
    }

    private var label: some View {
        ZStack {
            Text(title).opacity(isBusy ? 0 : 1)
            if isBusy {
                ProgressView().controlSize(.small)
            }
        }
    }
}

// MARK: - Copy

private extension StorageCategory {
    var title: String {
        switch self {
        case .music: "音乐文件"
        case .externalMusic: "外部音乐"
        case .libraryContent: "资料库内容"
        case .indexes: "索引与分析"
        case .artworkCache: "封面缓存"
        case .onlineCache: "联网缓存"
        case .otherCache: "其他缓存"
        case .appData: "App 数据"
        }
    }

    var detail: String {
        switch self {
        case .music: "复制进资料库的音频文件"
        case .externalMusic: "资料库引用的音频，保存在原来的文件夹里"
        case .libraryContent: "歌曲信息、封面、歌词、歌单与播放记录"
        case .indexes: "搜索索引、扫描记录与响度测量，可以由资料库重新生成"
        case .artworkCache: "列表与播放界面所用的各尺寸封面"
        case .onlineCache: "在线封面候选、外部播放结果与歌词库索引"
        case .otherCache: "主题色、首页快照、导入暂存与旧版本留下的文件"
        case .appData: "设置、音效预设、皮肤与诊断记录"
        }
    }
}

private func formatted(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
