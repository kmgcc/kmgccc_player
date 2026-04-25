//
//  BatchTrackEditSheet.swift
//  myPlayer2
//
//  Queue-based batch metadata + lyrics processing sheet.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(LyricsViewModel.self) private var lyricsVM
    @Environment(CoverDownloadService.self) private var coverDownloadService
    @Environment(NetEaseCoverService.self) private var netEaseCoverService
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore

    let tracks: [Track]

    @State private var currentIndex = 0
    @State private var autoSearchToken = 0

    @State private var title = ""
    @State private var artist = ""
    @State private var album = ""
    @State private var lyricsText = ""
    @State private var artworkData: Data?
    @State private var lyricsTimeOffsetMs: Double = 0

    @State private var showingArtworkPicker = false
    @State private var showingLyricsPicker = false
    @State private var statusMessage: String?
    @State private var isSavingCurrent = false
    @State private var isLoadingDraft = false
    @State private var processStateByTrackID: [UUID: ProcessState] = [:]
    @State private var coverFetchTask: Task<Void, Never>?
    @State private var previewLyricsVM: LyricsViewModel?

    // MARK: - Cover Search Coordinator

    @State private var coverCoordinator: CoverSearchCoordinator?

    private let amllDbURL = URL(string: "https://github.com/amll-dev/amll-ttml-db")!
    private let ttmlToolURL = URL(string: "https://amll-ttml-tool.stevexmh.net/")!

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
        .frame(minWidth: 1120, minHeight: 780)
        .tint(themeStore.accentColor)
        .accentColor(themeStore.accentColor)
        .background(
            WindowToolbarAccessor { window in
                window.styleMask.insert(.resizable)
                let minSize = NSSize(width: 1120, height: 780)
                if window.minSize.width < minSize.width || window.minSize.height < minSize.height {
                    window.minSize = minSize
                }
            }
        )
        .onAppear {
            ensurePreviewLyricsViewModel()
            uiState.lyricsPanelSuppressedByModal = true
            // Initialize cover coordinator with injected services
            coverCoordinator = CoverSearchCoordinator(
                coverDownloadService: coverDownloadService,
                netEaseCoverService: netEaseCoverService
            )
            guard !tracks.isEmpty else { return }
            prepareTrack(at: 0, triggerAutoSearch: true)
        }
        .onDisappear {
            uiState.lyricsPanelSuppressedByModal = false
            LyricsSurfaceManager.shared.deactivate(role: .batchPreview)
            previewLyricsVM = nil
            coverFetchTask?.cancel()
            coverFetchTask = nil
            coverCoordinator?.cancelSearch()
            lyricsVM.ensureAMLLLoaded(
                track: playerVM.currentTrack,
                currentTime: playerVM.currentTime,
                isPlaying: playerVM.isPlaying,
                reason: "batch editor dismissed",
                forceLyricsReload: true
            )
        }
        .onChange(of: title) { _, _ in draftDidChange() }
        .onChange(of: artist) { _, _ in draftDidChange() }
        .onChange(of: album) { _, _ in draftDidChange() }
        .onChange(of: lyricsText) { _, _ in draftDidChange() }
        .onChange(of: artworkData) { _, _ in draftDidChange() }
        .onChange(of: lyricsTimeOffsetMs) { _, _ in draftDidChange() }
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
                .plainText,
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
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.tertiary)
            Text("未传入批量处理歌曲")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var queuePanel: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    queueRow(track: track, index: index)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func queueRow(track: Track, index: Int) -> some View {
        let state = processStateByTrackID[track.id]
        let isCurrent = index == currentIndex
        let status = queueStatus(for: state, isCurrent: isCurrent)

        return Button {
            selectTrack(index)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                queueArtwork(track: track, index: index)

                VStack(alignment: .leading, spacing: 4) {
                    Text(track.title)
                        .font(.subheadline)
                        .lineLimit(1)

                    Text(displayArtist(track.artist))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(displayAlbum(track.album))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
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

    private func queueArtwork(track: Track, index: Int) -> some View {
        let rowArtworkData = index == currentIndex ? artworkData : track.artworkData

        return Group {
            if let data = rowArtworkData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note")
                    .font(.body)
                    .foregroundStyle(.secondary)
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
                Group {
                    if let data = artworkData, let nsImage = NSImage(data: data) {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 84, height: 84)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))

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

                    if coverCoordinator?.isLoading == true {
                        ProgressView()
                            .controlSize(.small)
                    }

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
                        .foregroundStyle(.secondary)
                    TextField("标题", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("艺人")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("艺人", text: $artist)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("专辑")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("专辑", text: $album)
                        .textFieldStyle(.roundedBorder)
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

            TextEditor(text: $lyricsText)
                .font(.system(.caption, design: .monospaced))
                .frame(height: 120)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
                }

            Text("TTML 文本区仅用于快速核对/微调；主要操作建议在下方 LDDC 区域完成。")
                .font(.caption2)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("歌词时间偏移")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.2f s", lyricsTimeOffsetMs / 1000.0))
                        .foregroundStyle(.secondary)
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

    private var amllPreviewPanel: some View {
        BatchAMLLPreviewPanel(
            previewLyricsVM: previewLyricsVM,
            editedTrack: currentTrack,
            isDarkMode: colorScheme == .dark
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
                    .foregroundStyle(.secondary)
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
        loadTrackDraft(from: tracks[index])
        playCurrentTrackForEditing(tracks[index])
        syncAMLLPreview(reason: "切换编辑歌曲", forceLyricsReload: true)

        if triggerAutoSearch {
            autoSearchToken += 1
        }
    }

    private func loadTrackDraft(from track: Track) {
        isLoadingDraft = true
        title = track.title
        artist = track.artist
        album = track.album
        lyricsText = track.loadTTMLLyricsIfNeeded() ?? track.loadLyricsIfNeeded() ?? ""
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
        guard let track = currentTrack else { return false }
        guard !isSavingCurrent else { return false }

        let changeSet = draftChangeSet(for: track)
        if !changeSet.hasChanges {
            if markProcessedIfUnchanged {
                markTrackCompleted(track: track, edited: false)
                statusMessage = "已完成：\(track.title)"
            }
            return true
        }

        isSavingCurrent = true
        defer { isSavingCurrent = false }

        track.title = title.isEmpty ? NSLocalizedString("library.unknown_title", comment: "") : title
        track.artist = artist.isEmpty ? NSLocalizedString("library.unknown_artist", comment: "") : artist
        track.album = album.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : album
        track.artworkData = artworkData
        track.lyricsTimeOffsetMs = lyricsTimeOffsetMs

        TrackLyricsDraft.assign(editorText: lyricsText, to: track)

        Task {
            await libraryVM.saveTrackEdits(
                track,
                mode: changeSet.persistenceMode,
                reason: persistenceReason(for: changeSet.persistenceMode, preferredReason: reason)
            )
        }
        markTrackCompleted(track: track, edited: true)
        statusMessage = "已保存：\(track.title)"
        syncAMLLPreview(reason: reason, forceLyricsReload: true)
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
        let savedAlbum =
            album.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : album

        let metadataChanged =
            savedTitle != track.title
            || savedArtist != track.artist
            || savedAlbum != track.album
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
            await coordinator.search(artist: currentArtist, album: currentAlbum)
            // Note: artworkData is updated reactively via onChange
        }
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
            lyricsText = try String(contentsOf: url, encoding: .utf8)
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

    private func syncAMLLPreview(reason: String, forceLyricsReload: Bool) {
        previewLyricsVM?.ensureAMLLLoaded(
            track: currentTrack,
            currentTime: playerVM.currentTime,
            isPlaying: playerVM.isPlaying,
            reason: reason,
            forceLyricsReload: forceLyricsReload
        )
    }

    private func handlePlaybackTrackChange(_ newTrackID: UUID?) {
        guard let track = currentTrack, newTrackID == track.id else { return }
        syncAMLLPreview(reason: "播放轨道更新", forceLyricsReload: false)
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
        raw.isEmpty ? NSLocalizedString("library.unknown_album", comment: "") : raw
    }

    private func ensurePreviewLyricsViewModel() {
        if previewLyricsVM == nil {
            previewLyricsVM = LyricsViewModel(settings: AppSettings.shared)
        }
        previewLyricsVM?.onSeekRequest = { [weak playbackCoordinator] seconds in
            playbackCoordinator?.seek(to: seconds)
        }
        LyricsSurfaceManager.shared.activate(role: .batchPreview)
    }
}

private struct BatchPreviewPlaybackObserver: View {
    @Environment(PlayerViewModel.self) private var playerVM

    let previewLyricsVM: LyricsViewModel
    let editedTrack: Track?

    var body: some View {
        Color.clear
            .onChange(of: playerVM.currentTime) { _, newTime in
                previewLyricsVM.syncTime(newTime)
            }
            .onChange(of: playerVM.isPlaying) { _, newValue in
                previewLyricsVM.setPlaying(newValue)
            }
            .onChange(of: playerVM.currentTrack?.id) { oldValue, newValue in
                guard oldValue != newValue, let editedTrack, newValue == editedTrack.id else { return }
                previewLyricsVM.ensureAMLLLoaded(
                    track: editedTrack,
                    currentTime: playerVM.currentTime,
                    isPlaying: playerVM.isPlaying,
                    reason: "播放轨道更新",
                    forceLyricsReload: false
                )
            }
    }
}

private struct BatchAMLLPreviewPanel: View, Equatable {
    let previewLyricsVM: LyricsViewModel?
    let editedTrack: Track?
    let isDarkMode: Bool

    static func == (lhs: BatchAMLLPreviewPanel, rhs: BatchAMLLPreviewPanel) -> Bool {
        lhs.previewIdentity == rhs.previewIdentity
            && lhs.editedTrack?.id == rhs.editedTrack?.id
            && lhs.isDarkMode == rhs.isDarkMode
    }

    private var previewIdentity: Int {
        previewLyricsVM.map { ObjectIdentifier($0).hashValue } ?? 0
    }

    private var backgroundColor: Color {
        isDarkMode
            ? Color(nsColor: NSColor(calibratedWhite: 0.16, alpha: 1.0))
            : Color(nsColor: NSColor(calibratedWhite: 0.94, alpha: 1.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("AMLL 渲染预览")
                .font(.headline)

            Text("当前编辑歌曲的 AMLL 实际渲染效果")
                .font(.caption)
                .foregroundStyle(.secondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(backgroundColor)

                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)

                if editedTrack == nil {
                    Text("无可预览歌曲")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let previewLyricsVM {
                    AMLLWebView(store: previewLyricsVM.webViewStore)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 10)
                        .overlay {
                            BatchPreviewPlaybackObserver(
                                previewLyricsVM: previewLyricsVM,
                                editedTrack: editedTrack
                            )
                            .allowsHitTesting(false)
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
