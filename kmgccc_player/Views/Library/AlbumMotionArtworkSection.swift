//
//  AlbumMotionArtworkSection.swift
//  myPlayer2
//
//  The album editor's motion artwork section, under the cover: the album's own
//  artwork, shown by every song without a choice of its own. Changes stay
//  pending until Save.
//

import SwiftUI

/// A pending change to the album's artwork that is not a new video.
enum AlbumMotionClear: Equatable {
    /// No motion artwork for the album.
    case remove
    /// Hand the album back to the automatic search.
    case automatic
}

struct AlbumMotionArtworkSection: View {
    /// A song of the album; it names the album the artwork belongs to.
    let query: MusicEnrichmentQuery?
    let albumTitle: String
    let albumArtist: String
    @Binding var selection: MusicEnrichmentResult?
    @Binding var importedVideo: MotionVideoImportSelection?
    @Binding var isValidatingImport: Bool
    @Binding var pendingClear: AlbumMotionClear?

    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(\.fullscreenSettingsPresentationStyle) private var presentationStyle
    @State private var state: MusicEnrichmentStore.AlbumMotionState?
    @State private var isLoading = true

    var body: some View {
        SettingsSection("动态封面", info: "专辑里没有单独设置的歌曲都会使用。") {
            if let query {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        TrackInfoValueRow("状态", value: statusText)
                        if pendingClear == nil, selection == nil, importedVideo == nil, let assets = state?.assets, let first = assets.first {
                            TrackInfoValueRow("时长", value: Self.formatDuration(first.duration))
                            TrackInfoValueRow("画幅", value: Self.shapes(assets))
                        }
                        actions
                    }

                    MotionArtworkSearchSection(
                        query: MusicEnrichmentQuery(key: query.key, title: albumTitle, artist: albumArtist, album: "", duration: 0),
                        selection: $selection,
                        importedVideo: $importedVideo,
                        isValidatingImport: $isValidatingImport,
                        titlePrompt: "专辑名称"
                    )
                    .onChange(of: selection) { _, value in if value != nil { pendingClear = nil } }
                    .onChange(of: importedVideo == nil) { _, isEmpty in if !isEmpty { pendingClear = nil } }
                }
                .task(id: query.key) { await load(query) }
            } else {
                Text("专辑里还没有歌曲。")
                    .settingsDescriptionStyle()
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        let hasArtwork = state?.assets.isEmpty == false
        let isUserSelected = state?.isUserSelected == true
        if pendingClear != nil || hasArtwork || isUserSelected {
            HStack(spacing: 8) {
                if pendingClear != nil {
                    Button("撤销") { pendingClear = nil }
                } else {
                    if hasArtwork {
                        Button("移除", role: .destructive) { choose(.remove) }
                    }
                    if isUserSelected {
                        Button("恢复自动查找") { choose(.automatic) }
                    }
                }
            }
            .buttonStyle(AppPanelButtonStyle())
            .font(.system(size: presentationStyle.rowFontSize, weight: .medium))
        }
    }

    private func choose(_ clear: AlbumMotionClear) {
        selection = nil
        importedVideo = nil
        pendingClear = clear
    }

    private var statusText: String {
        if pendingClear == .remove { return "保存后移除" }
        if pendingClear == .automatic { return "保存后恢复自动查找" }
        if selection != nil || importedVideo != nil { return "保存后使用新的选择" }
        if isLoading { return "正在读取" }
        guard let state else { return "无" }
        if state.assets.isEmpty { return state.isUserSelected ? "已关闭" : "无" }
        return state.isUserSelected ? "手动设置" : "自动查找"
    }

    private func load(_ query: MusicEnrichmentQuery) async {
        isLoading = true
        state = try? await cacheServices.musicEnrichmentService.albumMotionState(for: query)
        isLoading = false
    }

    private static func shapes(_ assets: [StoredMotionArtwork]) -> String {
        let kinds = Set(assets.map(\.kind))
        return [kinds.contains("square") ? "方形" : nil, kinds.contains("tall") ? "竖版" : nil]
            .compactMap { $0 }.joined(separator: "、")
    }

    private static func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
