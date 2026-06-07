//
//  BatchTrackEditSheet.swift
//  myPlayer2
//
//  Queue-based batch metadata + lyrics processing sheet.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct BatchEditTrackSnapshot: Identifiable, Equatable {
    var id: UUID
    var title: String
    var artist: String
    var album: String
    var artworkData: Data?
    var listRowID: String
}

struct BatchTrackEditSheet: View {

    private struct ProcessState {
        var edited = false
        var saved = false
        var skipped = false
        var saveError: String?
    }

    private struct TrackDraftChangeSet {
        let hasChanges: Bool
        let persistenceMode: TrackEditPersistenceMode
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(CoverDownloadService.self) private var coverDownloadService
    @Environment(NetEaseCoverService.self) private var netEaseCoverService
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore

    let tracks: [Track]

    @State private var trackSnapshots: [BatchEditTrackSnapshot] = []

    @State private var currentIndex = 0
    @State private var autoSearchToken = 0

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var trackDescription = ""
    @State private var genreTagsText = ""
    @State private var language = ""
    @State private var labelOrCompany = ""
    @State private var releaseDateText = ""
    @State private var qqMusicSongMid = ""
    @State private var metadataSource = ""
    @State private var metadataFetchedAt: Date?
    @State private var metadataConfidence: Double?
    @State private var lyricsText = ""
    @State private var artworkData: Data?
    @State private var lyricsTimeOffsetMs: Double = 0
    @State private var batchPreviewRefreshTask: Task<Void, Never>?
    @State private var batchPreviewReloadToken = 0
    @State private var restoreWindowLyricsAfterDismiss = false
    @State private var didSuspendWindowLyricsSurface = false

    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false
    @State private var statusMessage: String?
    @State private var isSavingCurrent = false
    @State private var isLoadingDraft = false
    @State private var processStateByTrackID: [UUID: ProcessState] = [:]
    @State private var coverFetchTask: Task<Void, Never>?
    @State private var metadataCandidates: [QQMusicArtworkCandidate] = []
    @State private var isMetadataLookupInFlight = false
    @State private var metadataLookupMessage: String?
    @State private var metadataFetchTask: Task<Void, Never>?

    // MARK: - Cover Search Coordinator

    @State private var coverCoordinator: CoverSearchCoordinator?

    private let amllDbURL = URL(string: "https://github.com/amll-dev/amll-ttml-db")!
    private let ttmlToolURL = URL(string: "https://amll-ttml-tool.stevexmh.net/")!

    // Phase 4.5: ordinary-text foregrounds tinted from the active ThemeStore palette.
    private var appFgPrimary: Color { Color(nsColor: themeStore.appForegroundPalette.primary) }
    private var appFgSecondary: Color { Color(nsColor: themeStore.appForegroundPalette.secondary) }
    private var appFgTertiary: Color { Color(nsColor: themeStore.appForegroundPalette.tertiary) }

    init(tracks: [Track]) {
        self.tracks = tracks
        
        var snapshots: [BatchEditTrackSnapshot] = []
        var seenIDs = Set<UUID>()
        var duplicateCount = 0
        
        print("[BatchTrackEditSheet] Initializing with \(tracks.count) tracks.")
        for (index, track) in tracks.enumerated() {
            let trackID = track.id
            let isDuplicate = seenIDs.contains(trackID)
            if isDuplicate {
                duplicateCount += 1
                print("[BatchTrackEditSheet] WARNING: Duplicate track ID detected: \(trackID) for track '\(track.title)'.")
            } else {
                seenIDs.insert(trackID)
            }
            
            let listRowID = isDuplicate ? "\(trackID.uuidString)-fallback-\(index)" : trackID.uuidString
            let title = track.title
            let artist = track.artist
            let album = track.album
            let artwork = track.loadArtworkDataIfNeeded()
            
            print("[BatchTrackEditSheet] Track [\(index)]: ID=\(trackID), Title='\(title)' (empty: \(title.isEmpty)), Artist='\(artist)' (empty: \(artist.isEmpty)), Album='\(album)' (empty: \(album.isEmpty))")
            
            snapshots.append(
                BatchEditTrackSnapshot(
                    id: trackID,
                    title: title,
                    artist: artist,
                    album: album,
                    artworkData: artwork,
                    listRowID: listRowID
                )
            )
        }
        
        self._trackSnapshots = State(initialValue: snapshots)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView

            Divider()

            if tracks.isEmpty {
                emptyView
            } else {
                HSplitView {
                    queuePanel
                        .frame(minWidth: 160, idealWidth: 220, maxWidth: 300)
                        .clipped()
                    editorPanel
                        .frame(minWidth: 500, idealWidth: 720, maxWidth: .infinity)
                        .layoutPriority(1)
                        .clipped()
                    amllPreviewPanel
                        .frame(minWidth: 280, idealWidth: 480, maxWidth: 640)
                        .clipped()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }

            Divider()

            footerView
        }
        .frame(width: 1120, height: 812)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .onAppear {
            enterBatchPreviewSession()
            // Initialize cover coordinator with injected services
            coverCoordinator = CoverSearchCoordinator(
                coverDownloadService: coverDownloadService,
                netEaseCoverService: netEaseCoverService
            )
            guard !tracks.isEmpty else { return }
            prepareTrack(at: 0, triggerAutoSearch: true)
            scheduleBatchPreviewRefresh(reason: "sheet appeared", debounceMilliseconds: 0)
        }
        .onDisappear {
            coverFetchTask?.cancel()
            coverFetchTask = nil
            metadataFetchTask?.cancel()
            metadataFetchTask = nil
            batchPreviewRefreshTask?.cancel()
            batchPreviewRefreshTask = nil
            leaveBatchPreviewSession()
            LyricsSurfaceManager.shared.deactivate(role: .batchPreview)
            coverCoordinator?.cancelSearch()
            
            // Print final summary
            let totalCount = tracks.count
            let savedCount = processStateByTrackID.values.filter { $0.saved }.count
            let skippedCount = processStateByTrackID.values.filter { $0.skipped }.count
            let failedCount = processStateByTrackID.values.filter { $0.saveError != nil }.count
            print("[BatchTrackEditSheet] Batch Edit Session finished. Total tracks: \(totalCount), Saved successfully: \(savedCount), Skipped: \(skippedCount), Failed: \(failedCount)")
        }
        .onChange(of: title) { _, _ in draftDidChange() }
        .onChange(of: artist) { _, _ in draftDidChange() }
        .onChange(of: album) { _, _ in draftDidChange() }
        .onChange(of: trackDescription) { _, _ in draftDidChange() }
        .onChange(of: genreTagsText) { _, _ in draftDidChange() }
        .onChange(of: language) { _, _ in draftDidChange() }
        .onChange(of: labelOrCompany) { _, _ in draftDidChange() }
        .onChange(of: releaseDateText) { _, _ in draftDidChange() }
        .onChange(of: lyricsText) { _, _ in
            draftDidChange()
            scheduleBatchPreviewRefresh(reason: "lyrics draft changed", debounceMilliseconds: 350)
        }
        .onChange(of: artworkData) { _, _ in draftDidChange() }
        .onChange(of: lyricsTimeOffsetMs) { _, _ in
            draftDidChange()
            scheduleBatchPreviewRefresh(reason: "lyrics offset changed", debounceMilliseconds: 0)
        }
        .onChange(of: currentIndex) { _, _ in
            scheduleBatchPreviewRefresh(reason: "selected track changed", debounceMilliseconds: 0)
        }
        .onChange(of: themeStore.themeGeneration) { _, _ in
            scheduleBatchPreviewRefresh(reason: "theme changed", debounceMilliseconds: 0)
        }
        .onChange(of: coverCoordinator?.selectedForPreview) { _, newValue in
            // Reactively update artwork preview when coordinator selects a candidate
            if let candidate = newValue {
                artworkData = candidate.imageData
                statusMessage = "封面已更新"
                // Auto-save for batch edit
                _ = saveCurrentTrack(
                    showFailureMessage: true,
                    markProcessedIfUnchanged: false,
                    reason: "查找封面后保存"
                )
            }
        }
        .fileImporter(
            isPresented: $showingArtworkPicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            handleArtworkImport(result)
        }
        .fileImporter(
            isPresented: $showingLyricsPicker,
            allowedContentTypes: [
                UTType(filenameExtension: "ttml") ?? .xml,
            ],
            allowsMultipleSelection: false
        ) { result in
            handleLyricsImport(result)
        }
    }

    private var currentTrack: Track? {
        guard tracks.indices.contains(currentIndex) else { return nil }
        return tracks[currentIndex]
    }

    private var batchPreviewStore: LyricsWebViewStore {
        LyricsSurfaceManager.shared.store(for: .batchPreview)
    }

    private var currentPreviewSnapshot: BatchEditTrackSnapshot? {
        guard let track = currentTrack else { return nil }
        return BatchEditTrackSnapshot(
            id: track.id,
            title: title,
            artist: artist,
            album: album,
            artworkData: artworkData,
            listRowID: track.id.uuidString
        )
    }

    private var headerView: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("批量编辑歌曲信息")
                    .font(.title2)
                    .fontWeight(.bold)

                if let track = currentTrack {
                    Text(
                        "当前：\(currentIndex + 1)/\(tracks.count) · \(track.title) · \(displayArtist(track.artist)) · \(displayAlbum(track.album))"
                    )
                    .font(.subheadline)
                    .foregroundStyle(appFgSecondary)
                }
            }

            Spacer()

            if isSavingCurrent {
                ProgressView()
                    .controlSize(.small)
            }

            GlassIconButton(
                systemImage: "xmark",
                size: GlassStyleTokens.headerControlHeight,
                iconSize: GlassStyleTokens.headerStandardIconSize,
                isPrimary: false,
                help: "关闭",
                surfaceVariant: .defaultToolbar
            ) {
                dismiss()
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 40))
                .foregroundStyle(appFgTertiary)
            Text("未传入批量处理歌曲")
                .foregroundStyle(appFgSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queuePanel: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(trackSnapshots.enumerated()), id: \.element.listRowID) { index, snapshot in
                    queueRow(snapshot: snapshot, index: index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func queueRow(snapshot: BatchEditTrackSnapshot, index: Int) -> some View {
        let state = processStateByTrackID[snapshot.id]
        let isCurrent = index == currentIndex
        let status = queueStatus(for: state, isCurrent: isCurrent)

        return Button {
            selectTrack(index)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                queueArtwork(snapshot: snapshot, index: index)

                VStack(alignment: .leading, spacing: 4) {
                    Text(snapshot.title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : snapshot.title)
                        .font(.subheadline)
                        .foregroundStyle(appFgPrimary)
                        .lineLimit(1)

                    Text(displayArtist(snapshot.artist))
                        .font(.caption)
                        .foregroundStyle(appFgSecondary)
                        .lineLimit(1)

                    Text(displayAlbum(snapshot.album))
                        .font(.caption2)
                        .foregroundStyle(appFgSecondary)
                        .lineLimit(1)

                    Text(status.text)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(status.color.opacity(0.16))
                        .foregroundStyle(status.color)
                        .clipShape(Capsule())
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isCurrent ? themeStore.selectionFill : Color(nsColor: .controlBackgroundColor).opacity(0.22))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isCurrent ? themeStore.accentColor.opacity(0.45) : .clear, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func queueArtwork(snapshot: BatchEditTrackSnapshot, index: Int) -> some View {
        let rowArtworkData = index == currentIndex ? artworkData : snapshot.artworkData

        return Group {
            if let data = rowArtworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.body)
                    .foregroundStyle(appFgSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.8))
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var editorPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metadataSection
                lyricsSection
                Color.clear.frame(height: 80)
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("元数据", systemImage: "info.circle")
                .font(.headline)

            HStack(spacing: 14) {
                ZStack {
                    Group {
                        if let data = artworkData, let nsImage = NSImage(data: data) {
                            Image(nsImage: nsImage)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(appFgSecondary)
                        }
                    }
                    .frame(width: 84, height: 84)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if coverCoordinator?.isLoading == true {
                        ProgressView()
                            .controlSize(.small)
                            .padding(8)
                            .background(.regularMaterial)
                            .clipShape(Circle())
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Button("导入封面") {
                        showingArtworkPicker = true
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())

                    Button("查找封面") {
                        fetchCover()
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(coverCoordinator?.isLoading == true)

                    if artworkData != nil {
                        Button("移除封面", role: .destructive) {
                            artworkData = nil
                            coverCoordinator?.clear()
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .clipShape(Capsule())
                    }

                    if let error = coverCoordinator?.error {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                // Candidate strip (appears when candidates exist)
                if let coordinator = coverCoordinator, coordinator.hasCandidates {
                    CoverCandidateStripView(
                        candidates: coordinator.candidates,
                        selectedCandidate: coordinator.selectedForPreview,
                        onSelect: { candidate in
                            coordinator.selectForPreview(candidate)
                            artworkData = candidate.imageData
                        }
                    )
                    .frame(maxWidth: 200)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("标题")
                        .font(.caption)
                        .foregroundStyle(appFgSecondary)
                    TextField("标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("艺人")
                        .font(.caption)
                        .foregroundStyle(appFgSecondary)
                    TextField("艺人", text: $artist)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("专辑")
                        .font(.caption)
                        .foregroundStyle(appFgSecondary)
                    TextField("专辑", text: $album)
                        .textFieldStyle(.roundedBorder)
                }
            }

            batchScrollingEditor(
                "歌曲描述",
                prompt: "可选，用于主页歌曲卡片横幅展示",
                text: $trackDescription,
                height: 96,
                font: .body
            )

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("更多详细元数据", systemImage: "list.bullet.rectangle")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Button {
                        fetchMetadata()
                    } label: {
                        Label("查找元数据", systemImage: "sparkle.magnifyingglass")
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .disabled(isMetadataLookupInFlight)
                    .font(.caption)

                    if isMetadataLookupInFlight {
                        ProgressView()
                            .controlSize(.small)
                    }

                    if let metadataLookupMessage {
                        Text(metadataLookupMessage)
                            .font(.caption)
                            .foregroundStyle(appFgSecondary)
                    }
                }

                if !metadataCandidates.isEmpty {
                    MetadataCandidateStripView(
                        candidates: metadataCandidates,
                        selectedSongMid: qqMusicSongMid,
                        onSelect: { candidate in
                            selectMetadataCandidate(candidate)
                        }
                    )
                }

                HStack(spacing: 10) {
                    batchLabeledField("流派 / 标签", prompt: "用逗号分隔", text: $genreTagsText)
                    batchLabeledField("语言", prompt: "语言", text: $language)
                }

                HStack(spacing: 10) {
                    batchLabeledField("厂牌 / 公司", prompt: "厂牌或公司", text: $labelOrCompany)
                    batchLabeledField("发行日期", prompt: "YYYY-MM-DD", text: $releaseDateText)
                }

                if hasReadonlyMetadata {
                    VStack(alignment: .leading, spacing: 4) {
                        batchReadonlyRow("QQMusic Song MID", qqMusicSongMid)
                        batchReadonlyRow("来源", metadataSource)
                        batchReadonlyRow("获取时间", metadataFetchedAt.map(formatMetadataDate) ?? "")
                        batchReadonlyRow(
                            "置信度",
                            metadataConfidence.map { String(format: "%.2f", $0) } ?? ""
                        )
                    }
                    .font(.caption)
                    .foregroundStyle(appFgSecondary)
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var lyricsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("歌词导入 / 查找 / 预编辑", systemImage: "text.quote")
                    .font(.headline)

                Spacer()

                Button {
                    openURL(amllDbURL)
                } label: {
                    Label("AMLL DB", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)

                Button {
                    openURL(ttmlToolURL)
                } label: {
                    Label("TTML Tool", systemImage: "hammer.fill")
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)

                Button("导入歌词文件") {
                    showingLyricsPicker = true
                }
                .buttonStyle(.bordered)
                .clipShape(Capsule())
                .font(.caption)
            }

            batchScrollingEditor(
                "歌词文本",
                prompt: "粘贴或应用 TTML / LRC 歌词",
                text: $lyricsText,
                height: 120,
                font: .system(.caption, design: .monospaced)
            )

            Text("TTML 文本区仅用于快速核对/微调；主要操作建议在下方 LDDC 区域完成。")
                .font(.caption2)
                .foregroundStyle(appFgSecondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("歌词时间偏移")
                        .font(.subheadline)
                        .foregroundStyle(appFgSecondary)
                    Spacer()
                    Text(String(format: "%+.2f s", lyricsTimeOffsetMs / 1000.0))
                        .foregroundStyle(appFgSecondary)
                        .monospacedDigit()
                    Button("重置") {
                        lyricsTimeOffsetMs = 0
                    }
                    .buttonStyle(.bordered)
                    .clipShape(Capsule())
                    .font(.caption)
                }

                Slider(value: $lyricsTimeOffsetMs, in: -5000...5000, step: 100)
            }

            Divider()

            if let track = currentTrack {
                LDDCSearchSection(
                    track: track,
                    layoutStyle: .split,
                    includeTranslationDefault: true,
                    autoSearchToken: autoSearchToken
                ) { ttml in
                    lyricsText = ttml
                    _ = saveCurrentTrack(
                        showFailureMessage: true,
                        markProcessedIfUnchanged: false,
                        reason: "LDDC 应用歌词"
                    )
                }
                .frame(maxWidth: .infinity, minHeight: 560)
                .clipped()
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.36))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var hasReadonlyMetadata: Bool {
        !qqMusicSongMid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !metadataSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || metadataFetchedAt != nil
            || metadataConfidence != nil
    }

    private func batchLabeledField(
        _ label: String,
        prompt: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(appFgSecondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func batchReadonlyRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .frame(width: 118, alignment: .leading)
                .foregroundStyle(appFgTertiary)
            Text(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "未记录" : value)
                .lineLimit(1)
                .textSelection(.enabled)
        }
    }

    private func batchScrollingEditor(
        _ label: String,
        prompt: String,
        text: Binding<String>,
        height: CGFloat,
        font: Font
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(appFgSecondary)

            ZStack(alignment: .topLeading) {
                TextEditor(text: text)
                    .font(font)
                    .lineSpacing(4)
                    .padding(8)
                    .frame(height: height)
                    .scrollContentBackground(.hidden)

                if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(prompt)
                        .foregroundStyle(appFgTertiary)
                        .font(.callout)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
            .background(.thinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.22), lineWidth: 1)
            }
            .padding(.trailing, 18)
        }
    }

    private var amllPreviewPanel: some View {
        BatchAMLLPreviewPanel(
            store: batchPreviewStore,
            trackSnapshot: currentPreviewSnapshot,
            lyricsText: lyricsText,
            isDarkMode: colorScheme == .dark,
            secondaryTextColor: themeStore.appForegroundPalette.secondary,
            reloadToken: batchPreviewReloadToken
        )
        .equatable()
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var footerView: some View {
        HStack(spacing: 12) {
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(appFgSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("跳过本首") {
                skipCurrentTrack()
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .disabled(tracks.isEmpty)

            Button("保存当前") {
                _ = saveCurrentTrack(
                    showFailureMessage: true,
                    markProcessedIfUnchanged: true,
                    reason: "手动保存"
                )
            }
            .buttonStyle(.bordered)
            .clipShape(Capsule())
            .disabled(tracks.isEmpty || isSavingCurrent)

            Button(currentIndex >= tracks.count - 1 ? "完成" : "下一首") {
                goNextTrack()
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            .disabled(tracks.isEmpty || isSavingCurrent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    private func prepareTrack(at index: Int, triggerAutoSearch: Bool) {
        guard tracks.indices.contains(index) else { return }

        currentIndex = index
        coverCoordinator?.clear()  // Clear stale candidates from previous track
        metadataCandidates = []
        metadataLookupMessage = nil
        metadataFetchTask?.cancel()
        metadataFetchTask = nil

        loadTrackDraft(from: tracks[index])
        playCurrentTrackForEditing(tracks[index])
        scheduleBatchPreviewRefresh(reason: "track prepared", debounceMilliseconds: 0)

        if triggerAutoSearch {
            autoSearchToken += 1
        }
    }

    private func loadTrackDraft(from track: Track) {
        isLoadingDraft = true
        title = track.title
        artist = track.artist
        album = track.album
        trackDescription = track.userDescription
        genreTagsText = track.genreTags.joined(separator: ", ")
        language = track.language
        labelOrCompany = track.labelOrCompany
        releaseDateText = formatDateForEditing(track.releaseDate)
        qqMusicSongMid = track.qqMusicSongMid ?? ""
        metadataSource = track.metadataSource ?? ""
        metadataFetchedAt = track.metadataFetchedAt
        metadataConfidence = track.metadataConfidence
        lyricsText = LyricsFormatSupport.normalizedTTMLText(track.loadTTMLLyricsIfNeeded()) ?? ""
        artworkData = track.loadArtworkDataIfNeeded()
        lyricsTimeOffsetMs = track.lyricsTimeOffsetMs
        statusMessage = nil
        isLoadingDraft = false
    }

    private func draftDidChange() {
        guard !isLoadingDraft else { return }
        guard let track = currentTrack else { return }
        guard hasDraftChangesComparedToCurrentTrack() else { return }

        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.edited = true
        state.saved = false
        state.skipped = false
        state.saveError = nil
        processStateByTrackID[track.id] = state
    }

    private func finalizeCurrentTrackBeforeSwitch() -> Bool {
        saveCurrentTrack(
            showFailureMessage: true,
            markProcessedIfUnchanged: true,
            reason: "切换到下一首前自动保存"
        )
    }

    private func selectTrack(_ index: Int) {
        guard tracks.indices.contains(index), index != currentIndex else { return }
        guard finalizeCurrentTrackBeforeSwitch() else { return }
        prepareTrack(at: index, triggerAutoSearch: true)
    }

    private func goNextTrack() {
        if currentIndex >= tracks.count - 1 {
            guard finalizeCurrentTrackBeforeSwitch() else { return }
            dismiss()
            return
        }

        guard finalizeCurrentTrackBeforeSwitch() else { return }
        prepareTrack(at: currentIndex + 1, triggerAutoSearch: true)
    }

    private func skipCurrentTrack() {
        guard let track = currentTrack else { return }

        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.skipped = true
        state.saved = false
        state.saveError = nil
        processStateByTrackID[track.id] = state
        statusMessage = "已跳过：\(track.title)"

        // Print diagnostics
        print("[BatchTrackEditSheet] Skipped track '\(track.title)'.")
        let totalCount = tracks.count
        let savedCount = processStateByTrackID.values.filter { $0.saved }.count
        let skippedCount = processStateByTrackID.values.filter { $0.skipped }.count
        let failedCount = processStateByTrackID.values.filter { $0.saveError != nil }.count
        print("[BatchTrackEditSheet] Session Stats -> Total: \(totalCount), Saved: \(savedCount), Skipped: \(skippedCount), Failed: \(failedCount)")

        if currentIndex < tracks.count - 1 {
            prepareTrack(at: currentIndex + 1, triggerAutoSearch: true)
        }
    }

    @discardableResult
    private func saveCurrentTrack(
        showFailureMessage: Bool,
        markProcessedIfUnchanged: Bool,
        reason: String
    ) -> Bool {
        guard let track = currentTrack else {
            print("[BatchTrackEditSheet] Save current track failed: No current track.")
            return false
        }
        guard !isSavingCurrent else {
            print("[BatchTrackEditSheet] Save current track skipped: Already saving.")
            return false
        }

        if let message = LyricsFormatSupport.validateManualTTML(lyricsText) {
            if showFailureMessage {
                statusMessage = message
            }
            var state = processStateByTrackID[track.id] ?? ProcessState()
            state.saveError = message
            processStateByTrackID[track.id] = state
            
            print("[BatchTrackEditSheet] Failed to save track '\(track.title)': \(message)")
            let totalCount = tracks.count
            let savedCount = processStateByTrackID.values.filter { $0.saved }.count
            let skippedCount = processStateByTrackID.values.filter { $0.skipped }.count
            let failedCount = processStateByTrackID.values.filter { $0.saveError != nil }.count
            print("[BatchTrackEditSheet] Session Stats -> Total: \(totalCount), Saved: \(savedCount), Skipped: \(skippedCount), Failed: \(failedCount)")
            
            return false
        }

        let changeSet = draftChangeSet(for: track)
        if !changeSet.hasChanges {
            if markProcessedIfUnchanged {
                markTrackCompleted(track: track, edited: false)
                statusMessage = "已完成：\(track.title)"
                
                print("[BatchTrackEditSheet] Track '\(track.title)' has no changes, marked completed.")
                let totalCount = tracks.count
                let savedCount = processStateByTrackID.values.filter { $0.saved }.count
                let skippedCount = processStateByTrackID.values.filter { $0.skipped }.count
                let failedCount = processStateByTrackID.values.filter { $0.saveError != nil }.count
                print("[BatchTrackEditSheet] Session Stats -> Total: \(totalCount), Saved: \(savedCount), Skipped: \(skippedCount), Failed: \(failedCount)")
            }
            return true
        }

        isSavingCurrent = true
        defer { isSavingCurrent = false }

        track.title = title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        track.artist = artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        track.album = album.trimmingCharacters(in: .whitespacesAndNewlines)
        track.userDescription = trackDescription
        track.genreTags = parsedGenreTags(from: genreTagsText)
        track.language = language.trimmingCharacters(in: .whitespacesAndNewlines)
        track.labelOrCompany = labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines)
        track.releaseDate = parseEditingDate(releaseDateText)
        track.artworkData = artworkData
        track.lyricsTimeOffsetMs = lyricsTimeOffsetMs

        TrackLyricsDraft.assign(editorText: lyricsText, to: track)
        refreshLiveLyricsIfEditingCurrentTrack(track, reason: "\(reason) draft")

        Task {
            await libraryVM.saveTrackEdits(
                track,
                mode: changeSet.persistenceMode,
                reason: persistenceReason(for: changeSet.persistenceMode, preferredReason: reason)
            )
            refreshLiveLyricsIfEditingCurrentTrack(track, reason: reason)
        }
        markTrackCompleted(track: track, edited: true)
        
        // Update snapshot in our array!
        if trackSnapshots.indices.contains(currentIndex) {
            trackSnapshots[currentIndex].title = track.title
            trackSnapshots[currentIndex].artist = track.artist
            trackSnapshots[currentIndex].album = track.album
            trackSnapshots[currentIndex].artworkData = artworkData
        }
        
        statusMessage = "已保存：\(track.title)"
        
        print("[BatchTrackEditSheet] Successfully saved track '\(track.title)'. changes: \(changeSet.persistenceMode)")
        let totalCount = tracks.count
        let savedCount = processStateByTrackID.values.filter { $0.saved }.count
        let skippedCount = processStateByTrackID.values.filter { $0.skipped }.count
        let failedCount = processStateByTrackID.values.filter { $0.saveError != nil }.count
        print("[BatchTrackEditSheet] Session Stats -> Total: \(totalCount), Saved: \(savedCount), Skipped: \(skippedCount), Failed: \(failedCount)")
        
        return true
    }

    private func markTrackCompleted(track: Track, edited: Bool) {
        var state = processStateByTrackID[track.id] ?? ProcessState()
        state.edited = state.edited || edited
        state.saved = true
        state.skipped = false
        state.saveError = nil
        processStateByTrackID[track.id] = state
    }

    private func hasDraftChangesComparedToCurrentTrack() -> Bool {
        guard let track = currentTrack else { return false }
        return draftChangeSet(for: track).hasChanges
    }

    private func draftChangeSet(for track: Track) -> TrackDraftChangeSet {
        let savedTitle =
            title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        let savedArtist =
            artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        let savedAlbum = album.trimmingCharacters(in: .whitespacesAndNewlines)

        let metadataChanged =
            savedTitle != track.title
            || savedArtist != track.artist
            || savedAlbum != track.album
            || trackDescription != track.userDescription
            || parsedGenreTags(from: genreTagsText) != track.genreTags
            || language.trimmingCharacters(in: .whitespacesAndNewlines) != track.language
            || labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines) != track.labelOrCompany
            || parseEditingDate(releaseDateText) != track.releaseDate
            || abs(lyricsTimeOffsetMs - track.lyricsTimeOffsetMs) > 0.000_1

        let lyricsChanged = TrackLyricsDraft.differs(from: track, editorText: lyricsText)
        let artworkChanged = artworkData != track.artworkData
        let hasChanges = metadataChanged || lyricsChanged || artworkChanged

        let persistenceMode: TrackEditPersistenceMode
        if artworkChanged && lyricsChanged {
            persistenceMode = .metaLyricsAndArtwork
        } else if artworkChanged {
            persistenceMode = .metaAndArtwork
        } else if lyricsChanged {
            persistenceMode = .metaAndLyrics
        } else {
            persistenceMode = .metaOnly
        }

        return TrackDraftChangeSet(hasChanges: hasChanges, persistenceMode: persistenceMode)
    }

    private func persistenceReason(
        for mode: TrackEditPersistenceMode,
        preferredReason _: String
    ) -> String {
        switch mode {
        case .metaOnly:
            return "trackEditMetaOnly"
        case .metaAndLyrics:
            return "trackEditLyrics"
        case .metaAndArtwork, .metaLyricsAndArtwork:
            return "trackEditArtwork"
        }
    }

    private func handleArtworkImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            artworkData = try Data(contentsOf: url)
            _ = saveCurrentTrack(
                showFailureMessage: true,
                markProcessedIfUnchanged: false,
                reason: "导入封面后保存"
            )
        } catch {
            statusMessage = "导入封面失败：\(error.localizedDescription)"
        }
    }

    private func fetchCover() {
        coverFetchTask?.cancel()
        coverCoordinator?.clear()

        coverFetchTask = Task {
            guard let coordinator = coverCoordinator else { return }
            let currentArtist = artist
            let currentAlbum = album
            let currentTitle = title
            let currentDuration = tracks.indices.contains(currentIndex) ? tracks[currentIndex].duration : nil
            await coordinator.search(
                artist: currentArtist,
                album: currentAlbum,
                title: currentTitle,
                duration: currentDuration
            )
            // Note: artworkData is updated reactively via onChange
        }
    }

    private func fetchMetadata() {
        guard let track = currentTrack else { return }
        metadataFetchTask?.cancel()
        isMetadataLookupInFlight = true
        metadataLookupMessage = nil
        metadataCandidates = []

        metadataFetchTask = Task {
            let durationVal = track.duration.isFinite && track.duration > 0 ? track.duration : nil
            let candidates = await libraryVM.searchTrackMetadataCandidates(
                title: title,
                artist: artist,
                album: album,
                duration: durationVal
            )

            await MainActor.run {
                self.metadataCandidates = candidates
            }

            if let detail = await libraryVM.fetchTrackMetadataDetail(track) {
                await MainActor.run {
                    let didApply = applyMetadataDetailIntoDraft(detail)
                    isMetadataLookupInFlight = false
                    metadataLookupMessage = didApply ? "已自动应用最佳匹配" : "未发现新匹配字段，请手动选择"
                }
                return
            }

            await MainActor.run {
                isMetadataLookupInFlight = false
                metadataLookupMessage = "未发现匹配，请手动选择"
            }
        }
    }

    @MainActor
    private func applyMetadataDetailIntoDraft(_ detail: TrackMetadataDetail) -> Bool {
        var changed = false
        if LibraryNormalization.isUnknownAlbum(album) {
            updateString(&album, with: detail.album, changed: &changed)
        }
        updateString(&trackDescription, with: detail.description, changed: &changed)

        let newGenreTags = detail.genreTags.joined(separator: ", ")
        if genreTagsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !newGenreTags.isEmpty {
            genreTagsText = newGenreTags
            changed = true
        }
        updateString(&language, with: detail.language, changed: &changed)
        updateString(&labelOrCompany, with: detail.labelOrCompany, changed: &changed)

        let newReleaseDate = detail.releaseDate.map(formatDateForEditing) ?? ""
        if releaseDateText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !newReleaseDate.isEmpty {
            releaseDateText = newReleaseDate
            changed = true
        }

        updateString(&qqMusicSongMid, with: detail.qqMusicSongMid, changed: &changed)
        updateString(&metadataSource, with: detail.source.rawValue, changed: &changed)

        metadataFetchedAt = detail.fetchedAt ?? Date()
        metadataConfidence = detail.confidence
        changed = true

        return changed
    }

    private func selectMetadataCandidate(_ candidate: QQMusicArtworkCandidate) {
        guard let songMid = candidate.songMid else { return }
        guard let track = currentTrack else { return }
        metadataLookupMessage = nil
        isMetadataLookupInFlight = true

        metadataFetchTask?.cancel()
        metadataFetchTask = Task {
            let durationVal = track.duration.isFinite && track.duration > 0 ? track.duration : nil
            if let detail = await libraryVM.fetchTrackMetadataDetailForMid(
                songMid,
                title: title,
                artist: artist,
                album: album,
                duration: durationVal
            ) {
                await MainActor.run {
                    var changed = false
                    updateString(&album, with: detail.album, changed: &changed)
                    updateString(&trackDescription, with: detail.description, changed: &changed)

                    let newGenreTags = detail.genreTags.joined(separator: ", ")
                    if genreTagsText != newGenreTags {
                        genreTagsText = newGenreTags
                        changed = true
                    }
                    updateString(&language, with: detail.language, changed: &changed)
                    updateString(&labelOrCompany, with: detail.labelOrCompany, changed: &changed)

                    let newReleaseDate = detail.releaseDate.map(formatDateForEditing) ?? ""
                    if releaseDateText != newReleaseDate {
                        releaseDateText = newReleaseDate
                        changed = true
                    }

                    updateString(&qqMusicSongMid, with: detail.qqMusicSongMid, changed: &changed)
                    updateString(&metadataSource, with: detail.source.rawValue, changed: &changed)

                    metadataFetchedAt = detail.fetchedAt ?? Date()
                    metadataConfidence = detail.confidence

                    isMetadataLookupInFlight = false
                    metadataLookupMessage = "已应用所选元数据"
                }
            } else {
                await MainActor.run {
                    isMetadataLookupInFlight = false
                    metadataLookupMessage = "元数据获取失败"
                }
            }
        }
    }

    private func updateString(_ target: inout String, with candidate: String?, changed: inout Bool) {
        let candidateVal = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if target != candidateVal {
            target = candidateVal
            changed = true
        }
    }

    private func scheduleBatchPreviewRefresh(reason: String, debounceMilliseconds: Int) {
        batchPreviewRefreshTask?.cancel()
        let snapshot = currentPreviewSnapshot
        let lyricsDraft = lyricsText
        let themePalette = themeStore.palette
        let colorScheme = colorScheme

        batchPreviewRefreshTask = Task { @MainActor in
            if debounceMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(debounceMilliseconds))
            }
            guard !Task.isCancelled else { return }
            applyBatchPreviewSnapshot(
                snapshot,
                lyricsText: lyricsDraft,
                themePalette: themePalette,
                colorScheme: colorScheme,
                reason: reason
            )
        }
    }

    private func applyBatchPreviewSnapshot(
        _ snapshot: BatchEditTrackSnapshot?,
        lyricsText: String,
        themePalette: ThemePalette?,
        colorScheme: ColorScheme,
        reason: String
    ) {
        let store = batchPreviewStore
        let normalizedLyrics = LyricsFormatSupport.normalizedTTMLText(lyricsText) ?? ""
        let playbackState = batchPreviewPlaybackState(for: snapshot?.id)

        if let themePalette {
            store.applyTheme(themePalette)
        }

        let previewConfig = BatchAMLLPreviewPanel.previewConfigJSON(
            settings: settings,
            colorScheme: colorScheme,
            lyricsTimeOffsetMs: lyricsTimeOffsetMs
        )
        store.forceSetConfigJSON(previewConfig, reason: "batchPreview.\(reason)")

        store.applyTrack(
            trackID: snapshot?.id,
            ttml: normalizedLyrics,
            currentTime: playbackState.currentTime,
            isPlaying: playbackState.isPlaying
        )
        store.setCurrentTime(playbackState.currentTime)
        store.setPlaying(playbackState.isPlaying)
        if !normalizedLyrics.isEmpty {
            store.revealExistingLyrics(
                reason: "batchPreview.\(reason)",
                currentTime: playbackState.currentTime
            )
        }
        batchPreviewReloadToken &+= 1
    }

    private func enterBatchPreviewSession() {
        let windowLyricsWasVisible = uiState.lyricsVisible && !uiState.lyricsPanelSuppressedByModal
        restoreWindowLyricsAfterDismiss = windowLyricsWasVisible
        didSuspendWindowLyricsSurface = false

        print(
            "[BatchTrackEditSheet] Enter batch editor. windowLyricsVisibleBefore=\(windowLyricsWasVisible)"
        )

        uiState.lyricsPanelSuppressedByModal = true
        LyricsSurfaceManager.shared.activate(role: .batchPreview)
        batchPreviewStore.onUserSeek = { [playbackCoordinator] seconds in
            playbackCoordinator.seek(to: seconds)
        }

        guard windowLyricsWasVisible else {
            print("[BatchTrackEditSheet] Window lyrics already hidden; no suspension needed.")
            return
        }

        didSuspendWindowLyricsSurface = true
        print("[BatchTrackEditSheet] Suspending window lyrics surface while batch editor is open.")
        LyricsSurfaceManager.shared.reportMainVisible(false)
        LyricsSurfaceManager.shared.mainStore.setPlaying(false)
    }

    private func leaveBatchPreviewSession() {
        batchPreviewStore.onUserSeek = nil
        uiState.lyricsPanelSuppressedByModal = false

        print(
            "[BatchTrackEditSheet] Leave batch editor. windowLyricsWasVisibleBefore=\(restoreWindowLyricsAfterDismiss), didSuspend=\(didSuspendWindowLyricsSurface)"
        )

        guard restoreWindowLyricsAfterDismiss else {
            print("[BatchTrackEditSheet] Not restoring window lyrics because it was not visible before entering batch editor.")
            didSuspendWindowLyricsSurface = false
            return
        }

        print("[BatchTrackEditSheet] Restoring window lyrics surface after batch editor dismissal.")
        LyricsSurfaceManager.shared.reportMainVisible(true)
        lyricsVM.ensureAMLLLoaded(
            track: playerVM.currentTrack,
            currentTime: playerVM.lyricsCurrentTime,
            isPlaying: playerVM.isPlaying,
            reason: "batch editor dismissed restore window lyrics",
            forceLyricsReload: true
        )
        didSuspendWindowLyricsSurface = false
    }

    private func batchPreviewPlaybackState(for trackID: UUID?) -> (currentTime: Double, isPlaying: Bool) {
        guard let trackID, playerVM.currentTrack?.id == trackID else {
            return (0, false)
        }
        return (playerVM.lyricsCurrentTime, playerVM.isPlaying)
    }

    private func handleLyricsImport(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }

        let didStart = url.startAccessingSecurityScopedResource()
        defer {
            if didStart {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let ttml = LyricsFormatSupport.normalizedTTMLText(text) else {
                statusMessage = "仅支持有效 TTML 歌词文件"
                return
            }
            lyricsText = ttml
            _ = saveCurrentTrack(
                showFailureMessage: true,
                markProcessedIfUnchanged: false,
                reason: "导入歌词后保存"
            )
        } catch {
            statusMessage = "导入歌词失败：\(error.localizedDescription)"
        }
    }

    private func playCurrentTrackForEditing(_ track: Track) {
        playbackCoordinator.play(track: track)
    }

    private func refreshLiveLyricsIfEditingCurrentTrack(_ track: Track, reason: String) {
        guard playerVM.currentTrack?.id == track.id else { return }
        lyricsVM.ensureAMLLLoaded(
            track: track,
            currentTime: playerVM.lyricsCurrentTime,
            isPlaying: playerVM.isPlaying,
            reason: reason,
            forceLyricsReload: true
        )
    }

    private func queueStatus(for state: ProcessState?, isCurrent: Bool) -> (text: String, color: Color) {
        if isCurrent {
            return ("处理中", themeStore.accentColor)
        }
        guard let state else {
            return ("未处理", .secondary)
        }
        if state.skipped { return ("已跳过", .orange) }
        if state.saveError != nil { return ("保存失败", .red) }
        if state.saved { return ("已完成", .green) }
        if state.edited { return ("待保存", .yellow) }
        return ("未处理", .secondary)
    }

    private func displayArtist(_ raw: String) -> String {
        raw.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : raw
    }

    private func displayAlbum(_ raw: String) -> String {
        LibraryNormalization.displayAlbum(raw)
    }

    private func parsedGenreTags(from text: String) -> [String] {
        var seen = Set<String>()
        return text
            .split { $0 == "," || $0 == "，" || $0 == ";" || $0 == "；" }
            .compactMap { part in
                let tag = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty, seen.insert(tag).inserted else { return nil }
                return tag
            }
    }

    private func formatDateForEditing(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func parseEditingDate(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: trimmed)
    }

    private func formatMetadataDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

}

private struct BatchAMLLPreviewPanel: View, Equatable {
    private enum PreviewState: Equatable {
        case noTrack
        case noLyrics
        case invalidLyrics(String)
        case ready(String)
    }

    let store: LyricsWebViewStore
    let trackSnapshot: BatchEditTrackSnapshot?
    let lyricsText: String
    let isDarkMode: Bool
    let secondaryTextColor: NSColor
    let reloadToken: Int

    static func == (lhs: BatchAMLLPreviewPanel, rhs: BatchAMLLPreviewPanel) -> Bool {
        lhs.store === rhs.store
            && lhs.trackSnapshot == rhs.trackSnapshot
            && lhs.lyricsText == rhs.lyricsText
            && lhs.isDarkMode == rhs.isDarkMode
            && lhs.secondaryTextColor.isEqual(rhs.secondaryTextColor)
            && lhs.reloadToken == rhs.reloadToken
    }

    static func previewConfigJSON(
        settings: AppSettings,
        colorScheme: ColorScheme,
        lyricsTimeOffsetMs: Double
    ) -> String {
        let themeName = colorScheme == .dark ? "dark" : "light"
        let role = LyricsSurfaceRole.batchPreview
        let overlay = LyricsRuntimeOverlayResolver.overlay(
            context: .mainPanel,
            playbackSource: .local
        )
        let clampedWeight = max(
            100,
            min(900, colorScheme == .dark ? settings.lyricsFontWeightDark : settings.lyricsFontWeightLight)
        )
        let clampedTranslationWeight = max(
            100,
            min(
                900,
                colorScheme == .dark
                    ? settings.lyricsTranslationFontWeightDark
                    : settings.lyricsTranslationFontWeightLight
            )
        )
        let effectiveGlobalAdvanceMs = max(
            -5000,
            min(5000, settings.lyricsGlobalAdvanceMs + overlay.globalAdvanceDeltaMs)
        )
        let combinedOffsetMs = max(
            -20000,
            min(20000, lyricsTimeOffsetMs - effectiveGlobalAdvanceMs)
        )
        let payload: [String: Any] = [
            "theme": themeName,
            "fontSize": settings.lyricsFontSize + overlay.mainFontSizeDeltaPx,
            "fontWeight": clampedWeight,
            "fontFamilyMain": cssFontFamily([
                settings.lyricsFontNameEn,
                settings.lyricsFontNameZh,
            ]),
            "fontFamilyTranslation": cssFontFamily([
                settings.lyricsTranslationFontName
            ]),
            "translationFontSize": settings.lyricsTranslationFontSize + overlay.translationFontSizeDeltaPx,
            "translationFontWeight": clampedTranslationWeight,
            "leadInMs": max(0, settings.lyricsLeadInMs),
            "nearSwitchGapMs": max(0, min(500, settings.lyricsNearSwitchGapMs)),
            "timeOffsetMs": combinedOffsetMs,
            "seekTimeOffsetMs": max(-15000, min(15000, lyricsTimeOffsetMs)),
            "renderScale": role.renderScale,
            "enableBlur": role.enableBlur,
            "enableSpring": role.enableSpring,
            "fpsCap": role.fpsCap,
            "overscanPx": role.overscanPx,
            "wordFadeWidth": role.wordFadeWidth,
            "wordHighlightMode": settings.amllDiscreteWordHighlightEnabled ? "discrete" : "smooth",
            "lineHeight": 1.5,
            "activeScale": role.activeScale,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }
        return colorScheme == .dark
            ? "{\"theme\":\"dark\"}"
            : "{\"theme\":\"light\"}"
    }

    private static func cssFontFamily(_ names: [String]) -> String {
        let sanitized = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { name in
                "\"\(name.replacingOccurrences(of: "\"", with: "\\\""))\""
            }
        return (sanitized + ["-apple-system", "\"Helvetica Neue\"", "sans-serif"])
            .joined(separator: ", ")
    }

    private var backgroundColor: Color {
        isDarkMode
            ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1.0))
            : Color(nsColor: NSColor(calibratedWhite: 0.94, alpha: 1.0))
    }

    private var trimmedLyricsText: String {
        lyricsText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var previewState: PreviewState {
        guard trackSnapshot != nil else { return .noTrack }
        guard !trimmedLyricsText.isEmpty else { return .noLyrics }
        if let message = LyricsFormatSupport.validateManualTTML(lyricsText) {
            return .invalidLyrics(message)
        }
        guard let normalized = LyricsFormatSupport.normalizedTTMLText(lyricsText) else {
            return .invalidLyrics("歌词预览暂不可用")
        }
        return .ready(normalized)
    }

    var body: some View {
        let appFgSecondary = Color(nsColor: secondaryTextColor)
        return VStack(alignment: .leading, spacing: 10) {
            Text("歌词预览")
                .font(.headline)

            Text("编辑态 AMLL surface，跟随当前播放进度并支持滚动与点击跳转。")
                .font(.caption)
                .foregroundStyle(appFgSecondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(backgroundColor)

                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)

                switch previewState {
                case .noTrack:
                    Text("无可预览歌曲")
                        .font(.caption)
                        .foregroundStyle(appFgSecondary)
                case .noLyrics:
                    Text("暂无歌词预览")
                        .font(.caption)
                        .foregroundStyle(appFgSecondary)
                case .invalidLyrics(let message):
                    VStack(spacing: 8) {
                        Text("歌词预览暂不可用")
                            .font(.caption)
                            .foregroundStyle(appFgSecondary)
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(appFgSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                case .ready:
                    BatchAMLLPreviewWebView(store: store, reloadToken: reloadToken)
                        .id(trackSnapshot?.id)
                        .padding(8)
                        .overlay {
                            BatchPreviewPlaybackObserver(
                                store: store,
                                editedTrackID: trackSnapshot?.id
                            )
                            .allowsHitTesting(false)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct BatchAMLLPreviewWebView: View, Equatable {
    let store: LyricsWebViewStore
    let reloadToken: Int

    @State private var didTimeout = false

    static func == (lhs: BatchAMLLPreviewWebView, rhs: BatchAMLLPreviewWebView) -> Bool {
        lhs.store === rhs.store && lhs.reloadToken == rhs.reloadToken
    }

    var body: some View {
        Group {
            if store.hasPreparedWebView || store.isReady {
                AMLLWebView(store: store, animatesAttachment: false)
                    .clipped()
            } else if didTimeout {
                VStack(spacing: 8) {
                    Text("歌词预览暂不可用")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("WebView 初始化失败不会影响批量编辑和保存。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("歌词预览加载中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .task(id: reloadToken) {
                    didTimeout = false
                    _ = store.webView
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled else { return }
                    didTimeout = !store.isReady
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BatchPreviewPlaybackObserver: View {
    @Environment(PlayerViewModel.self) private var playerVM

    let store: LyricsWebViewStore
    let editedTrackID: UUID?

    var body: some View {
        Color.clear
            .onAppear {
                syncPreviewPlaybackState()
            }
            .onChange(of: editedTrackID) { _, _ in
                syncPreviewPlaybackState()
            }
            .onChange(of: playerVM.lyricsCurrentTime) { _, _ in
                syncPreviewPlaybackState()
            }
            .onChange(of: playerVM.isPlaying) { _, _ in
                syncPreviewPlaybackState()
            }
            .onChange(of: playerVM.currentTrack?.id) { _, _ in
                syncPreviewPlaybackState()
            }
    }

    private func syncPreviewPlaybackState() {
        guard let editedTrackID, playerVM.currentTrack?.id == editedTrackID else {
            store.setPlaying(false)
            store.setCurrentTime(0)
            return
        }

        let currentTime = playerVM.lyricsCurrentTime
        if !playerVM.isPlaying {
            store.setCurrentTime(currentTime)
        }
        store.setPlaying(playerVM.isPlaying)
        store.setCurrentTime(currentTime)
    }
}
