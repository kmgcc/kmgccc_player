//
//  PlaylistDetailView.swift
//  myPlayer2
//
//  kmgccc_player - Playlist Detail View
//  Displays tracks in a playlist or all songs.
//
//  Playlist-scoped toolbar content is declared here and surfaced via the window toolbar.
//

import SwiftUI

// MARK: - Playlist Detail View

/// View displaying tracks in the selected playlist or all songs.
struct PlaylistDetailView: View {

    private struct BatchEditRequest: Identifiable {
        let id = UUID()
        let tracks: [Track]
    }

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator
    @Environment(UIStateViewModel.self) private var uiState

    let pageController: PlaylistPageController

    // MARK: - State

    @State private var trackToEdit: Track?
    @State private var batchEditRequest: BatchEditRequest?

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("PlaylistDetailView.body")
        let _ = TintTimelineProbe.noteRootConsumer("PlaylistDetailView.body")
        Group {
            if libraryVM.currentSelection == .allSongs {
                if libraryVM.state == .loading
                    || pageController.isSelectionTransitioning
                {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if (pageController.page?.displayedTrackCount ?? 0) == 0 {
                    emptyStateView
                } else if (pageController.page?.rows.isEmpty ?? true) {
                    noResultsView
                } else {
                    trackListView
                        .id("rows-\(selectionIdentity)")
                }
            } else {
                if pageController.isSelectionTransitioning
                    || (libraryVM.state == .loading && pageController.page == nil)
                {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    detailScrollView
                        .id("rows-\(selectionIdentity)")
                }
            }
        }
        // Fill available space, anchor content to top
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(PlaylistLayoutPassProbe(key: "PlaylistDetailView.root"))
        .frame(minWidth: 320)
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
        }
        .sheet(
            item: $batchEditRequest,
            onDismiss: {
                clearMultiselectState()
            }
        ) { request in
            BatchTrackEditSheet(
                tracks: request.tracks
            )
            .presentationSizing(.page)
        }
        .onAppear {
            print(
                "[PlaylistDetailView] appear pageController=\(ObjectIdentifier(pageController).hashValue) "
                    + "libraryVM=\(ObjectIdentifier(libraryVM).hashValue) "
                    + "playbackCoord=\(ObjectIdentifier(playbackCoordinator).hashValue) "
                    + "uiState=\(ObjectIdentifier(uiState).hashValue)"
            )
            pageController.bind(libraryVM: libraryVM, playerVM: playerVM, uiState: uiState)
            pageController.appear()
        }
        .onDisappear {
            pageController.disappear()
        }
        .onChange(of: pageController.searchText) { _, _ in
            pageController.handleSearchChange()
        }
        .onChange(of: libraryVM.trackSortKey) { _, _ in
            pageController.handleSortChange(reason: "sortKey")
        }
        .onChange(of: libraryVM.trackSortOrder) { _, _ in
            pageController.handleSortChange(reason: "sortOrder")
        }
        .onChange(of: libraryVM.totalTrackCount) { _, _ in
            pageController.handleLibraryRefresh(reason: "trackCount", restoreScroll: true)
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            pageController.handleLibraryRefresh(reason: "refresh", restoreScroll: true)
        }
        .onChange(of: libraryVM.searchResetTrigger) { _, _ in
            pageController.searchText = ""
        }
        .onChange(of: libraryVM.state) { _, newVal in
            if newVal == .loaded {
                pageController.handleLibraryRefresh(reason: "state_loaded", restoreScroll: true)
            }
        }
        .onChange(of: libraryVM.currentSelection) { _, newVal in
            pageController.handleSelectionChange(newVal)
        }
        .onReceive(NotificationCenter.default.publisher(for: .libraryTrackDidUpdate)) { notification in
            guard let trackID = notification.userInfo?["trackID"] as? UUID else { return }
            pageController.applyTargetedTrackRefresh(trackID: trackID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .playbackTrackDidChange)) { _ in
            pageController.notePlaybackTrackDidChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: .toggleMultiselectMode)) { _ in
            // Only enable multi-select if there are tracks to select
            guard let page = pageController.page, !page.rows.isEmpty else { return }
            pageController.isMultiselectMode.toggle()
            if !pageController.isMultiselectMode {
                pageController.selectedTrackIDs.removeAll()
            }
        }
    }

    // MARK: - Computed Properties

    private var isFiltering: Bool {
        !pageController.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectionIdentity: String {
        pageController.page?.selectionIdentity ?? fallbackSelectionIdentity
    }

    private var fallbackSelectionIdentity: String {
        switch libraryVM.currentSelection {
        case .allSongs:
            return "allSongs"
        case .playlist(let id):
            return "playlist-\(id.uuidString)"
        case .artist(let key):
            return "artist-\(key)"
        case .album(let key):
            return "album-\(key)"
        }
    }

    private var scrollBinding: Binding<UUID?> {
        Binding(
            get: { pageController.listScrollPositionID },
            set: { pageController.updateScrollPosition($0) }
        )
    }

    private var currentRows: [PlaylistPageRowModel] {
        pageController.page?.rows ?? []
    }

    private var queueTracks: [Track] {
        pageController.page?.queueTracks ?? []
    }

    private var detailHeaderModel: PlaylistPageHeaderModel? {
        pageController.page?.header
    }

    // MARK: - Subviews

    @ViewBuilder
    private var trackRowsContent: some View {
        PlaylistTrackRowsSection(
            rows: currentRows,
            queueTracks: queueTracks,
            selectionIdentity: selectionIdentity,
            pageController: pageController,
            menuBuilder: erasedTrackMenu(trackID:)
        )
    }

    private var trackListView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                trackRowsContent
            }
            .scrollTargetLayout()
            .padding(.top, contentTopPadding)
            .padding(.bottom, listBottomPadding)
            .padding(.horizontal)
            .transaction { tx in tx.animation = nil }
        }
        .background(PlaylistLayoutPassProbe(key: "PlaylistDetailView.trackList"))
        .scrollPosition(id: scrollBinding, anchor: .top)
    }

    private var detailScrollView: some View {
        ScrollView(.vertical) {
            VStack(spacing: 0) {
                if pageController.isHeaderEffectsEnabled {
                    if pageController.rendersHeaderBackgroundInWindowLayer {
                        haloScrollTrackingLayer
                    } else {
                        haloLayer
                    }
                } else {
                    Color.clear
                        .frame(height: 0)
                        .allowsHitTesting(false)
                }

                if let header = detailHeaderModel {
                    headerContentSection(model: header)
                }

                trackContentSection
            }
            .padding(.top, contentTopPadding)
            .padding(.bottom, listBottomPadding)
            .padding(.horizontal)
            .transaction { tx in tx.animation = nil }
        }
        .background(PlaylistLayoutPassProbe(key: "PlaylistDetailView.detailScroll"))
        .coordinateSpace(name: "detailScroll")
        .scrollPosition(id: scrollBinding, anchor: .top)
    }

    private var haloScrollTrackingLayer: some View {
        Color.clear
            .frame(height: 0)
            .background(
                ScrollOffsetSensor { offset in
                    pageController.updateHaloScroll(offset: offset)
                }
            )
            .allowsHitTesting(false)
    }

    private var haloLayer: some View {
        HeaderHaloBackgroundView(
            state: pageController.haloState,
            currentSource: pageController.haloCurrentImage,
            incomingSource: pageController.haloIncomingImage,
            sourceBlendOpacity: pageController.haloSourceBlendOpacity,
            presentationOpacity: pageController.haloPresentationOpacity
        )
        .background(
            ScrollOffsetSensor { offset in
                pageController.updateHaloScroll(offset: offset)
            }
        )
    }

    @ViewBuilder
    private func headerContentSection(model: PlaylistPageHeaderModel) -> some View {
        LibraryDetailHeaderView(
            config: model.config,
            artworkIdentity: model.artworkIdentity,
            currentArtwork: pageController.headerCurrentArtwork,
            incomingArtwork: pageController.headerIncomingArtwork,
            incomingOpacity: pageController.headerIncomingOpacity,
            onPlay: {
                guard !queueTracks.isEmpty else { return }
                playbackCoordinator.playTracks(
                    queueTracks,
                    libraryQueueSource: .librarySelection(selectionIdentity)
                )
            },
            canPlay: !queueTracks.isEmpty,
            onArtworkFrameChange: { bounds in
                pageController.updateHeaderArtworkBounds(
                    bounds,
                    selectionIdentity: model.config.selectionIdentity
                )
            },
            onArtworkMutation: {
                pageController.refreshHeaderArtwork()
            }
        )

        Spacer().frame(height: 12)
    }

    private var trackContentSection: some View {
        let _ = LyricsRuntimeProfile.markBody("PlaylistDetailView.trackContentSection")
        return Group {
            if libraryVM.state == .loading && pageController.page == nil {
                ProgressView()
                    .controlSize(.large)
                    .padding(.vertical, 40)
                    .frame(maxWidth: .infinity)
            } else if currentRows.isEmpty && isFiltering {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("library.no_results")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 40)
                .frame(maxWidth: .infinity)
            } else {
                LazyVStack(spacing: 0) {
                    trackRowsContent
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("library.no_songs")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("library.import_desc")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Button {
                Task {
                    await libraryVM.importToCurrentPlaylist()
                }
            } label: {
                Label(
                    "library.import_btn",
                    systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: "magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)

            Text("library.no_results")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(String(format: NSLocalizedString("library.no_matches", comment: ""), pageController.searchText))
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var songCountText: String {
        let displayedCount = pageController.page?.displayedTrackCount ?? 0
        let filteredCount = pageController.page?.filteredTrackCount ?? 0
        if isFiltering {
            return String(
                format: NSLocalizedString("library.song_count_filtered", comment: ""),
                filteredCount,
                displayedCount
            )
        }
        let format =
            displayedCount == 1
            ? NSLocalizedString("library.song_count_one", comment: "")
            : NSLocalizedString("library.song_count", comment: "")
        return String(format: format, displayedCount)
    }

    @ViewBuilder
    private func trackMenu(trackID: UUID) -> some View {
        if let track = pageController.latestTrackFromLibrary(trackID: trackID) {
            if pageController.isMultiselectMode && pageController.selectedTrackIDs.contains(trackID) {
                Text("已选择 \(pageController.selectedTrackIDs.count) 首歌曲")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                Divider()

                Button {
                    openBatchEditor()
                } label: {
                    Label("批量编辑歌曲信息…", systemImage: "square.stack.3d.forward.dottedline")
                }

                Divider()

                Menu {
                    ForEach(libraryVM.playlists) { playlist in
                        if libraryVM.selectedPlaylist?.id != playlist.id {
                            Button {
                                processBatchAction { tracks in
                                    await libraryVM.addTracksToPlaylist(tracks, playlist: playlist)
                                }
                            } label: {
                                Label(playlist.name, systemImage: "music.note.list")
                            }
                        }
                    }

                    Divider()

                    Button {
                        processBatchAction { tracks in
                            let playlist = await libraryVM.createNewPlaylist()
                            await libraryVM.addTracksToPlaylist(tracks, playlist: playlist)
                        }
                    } label: {
                        Label("新建播放列表", systemImage: "plus")
                    }
                } label: {
                    Label("添加到播放列表...", systemImage: "plus.circle")
                }
                .id("batch_add_to_playlist_\(libraryVM.playlists.count)")

                if let currentPlaylist = libraryVM.selectedPlaylist {
                    Button {
                        processBatchAction { tracks in
                            await libraryVM.removeTracksFromPlaylist(tracks, playlist: currentPlaylist)
                        }
                    } label: {
                        Label("从当前播放列表移除", systemImage: "minus.circle")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    processBatchAction { tracks in
                        await libraryVM.deleteTracks(tracks)
                        await MainActor.run {
                            pageController.selectedTrackIDs.removeAll()
                        }
                    }
                } label: {
                    Label("从资料库删除", systemImage: "trash")
                }

            } else {
                Button {
                    pageController.isMultiselectMode = true
                    pageController.selectedTrackIDs.insert(trackID)
                } label: {
                    Label("多选歌曲…", systemImage: "checkmark.circle")
                }

                Divider()

                Button {
                    let startIndex = pageController.queueStartIndex(for: track.id)
                    playbackCoordinator.playTracks(
                        queueTracks,
                        startingAt: startIndex,
                        libraryQueueSource: .librarySelection(selectionIdentity)
                    )
                } label: {
                    Label("播放", systemImage: "play")
                }

                Divider()

                Menu {
                    ForEach(libraryVM.playlists) { playlist in
                        if libraryVM.selectedPlaylist?.id != playlist.id {
                            Button {
                                Task {
                                    await libraryVM.addTracksToPlaylist([track], playlist: playlist)
                                }
                            } label: {
                                Label(playlist.name, systemImage: "music.note.list")
                            }
                        }
                    }

                    Divider()

                    Button {
                        Task {
                            let playlist = await libraryVM.createNewPlaylist()
                            await libraryVM.addTracksToPlaylist([track], playlist: playlist)
                        }
                    } label: {
                        Label("新建播放列表", systemImage: "plus")
                    }
                } label: {
                    Label("添加到播放列表...", systemImage: "plus.circle")
                }
                .id("single_add_to_playlist_\(libraryVM.playlists.count)")

                if let currentPlaylist = libraryVM.selectedPlaylist {
                    Button {
                        Task {
                            await libraryVM.removeTracksFromPlaylist([track], playlist: currentPlaylist)
                        }
                    } label: {
                        Label("从当前播放列表移除", systemImage: "minus.circle")
                    }
                }

                Divider()

                Button {
                    trackToEdit = track
                } label: {
                    Label("编辑歌曲信息", systemImage: "info.circle")
                }

                Divider()

                Button(role: .destructive) {
                    Task {
                        await libraryVM.deleteTrack(track)
                    }
                } label: {
                    Label("从资料库删除", systemImage: "trash")
                }
            }
        } else {
            Text("library.track_unavailable")
        }
    }

    private func processBatchAction(action: @escaping ([Track]) async -> Void) {
        let selectedTracks = selectedTracksForBatchEditor()
        Task {
            await action(selectedTracks)
            await MainActor.run {
                pageController.clearMultiselectState()
            }
        }
    }

    private func selectedTracksForBatchEditor() -> [Track] {
        currentRows.compactMap { row in
            guard pageController.selectedTrackIDs.contains(row.id) else { return nil }
            return pageController.latestTrackFromLibrary(trackID: row.id)
        }
    }

    private func openBatchEditor() {
        let selectedTracks = selectedTracksForBatchEditor()
        guard !selectedTracks.isEmpty else { return }
        uiState.lyricsPanelSuppressedByModal = true
        batchEditRequest = BatchEditRequest(tracks: selectedTracks)
    }

    private func clearMultiselectState() {
        pageController.clearMultiselectState()
    }

    private func erasedTrackMenu(trackID: UUID) -> AnyView {
        AnyView(trackMenu(trackID: trackID))
    }

    private var contentTopPadding: CGFloat { 16 }
    private var listBottomPadding: CGFloat { 16 }
}

private struct PlaylistTrackRowsSection: View {
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let rows: [PlaylistPageRowModel]
    let queueTracks: [Track]
    let selectionIdentity: String
    let pageController: PlaylistPageController
    let menuBuilder: (UUID) -> AnyView

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("PlaylistTrackRowsSection.body")
        ForEach(rows) { row in
            TrackRowView(
                model: row.trackRowModel,
                isPlaying: playerVM.currentTrack?.id == row.id,
                isSelected: pageController.isMultiselectMode && pageController.selectedTrackIDs.contains(row.id),
                enableSecondaryInteractions: pageController.areRowSecondaryInteractionsEnabled,
                enableArtworkLoading: pageController.areRowArtworkLoadsEnabled,
                onTap: {
                    if pageController.isMultiselectMode {
                        if pageController.selectedTrackIDs.contains(row.id) {
                            pageController.selectedTrackIDs.remove(row.id)
                        } else {
                            pageController.selectedTrackIDs.insert(row.id)
                        }
                    } else {
                        let startIndex = pageController.queueStartIndex(for: row.id)
                        playbackCoordinator.playTracks(
                            queueTracks,
                            startingAt: startIndex,
                            libraryQueueSource: .librarySelection(selectionIdentity)
                        )
                    }
                },
                onRowAppear: {
                    pageController.prefetchAroundTrackID(row.id)
                }
            ) {
                menuBuilder(row.id)
            }
            .contextMenu {
                if pageController.areRowSecondaryInteractionsEnabled {
                    menuBuilder(row.id)
                }
            }
        }
        Color.clear.frame(height: 160)
    }
}

private struct PlaylistLayoutPassProbe: NSViewRepresentable {
    let key: String

    func makeNSView(context: Context) -> PlaylistLayoutPassProbeView {
        PlaylistLayoutPassProbeView(key: key)
    }

    func updateNSView(_ nsView: PlaylistLayoutPassProbeView, context: Context) {
        LyricsRuntimeProfile.increment("\(key).updateNSView")
    }
}

private final class PlaylistLayoutPassProbeView: NSView {
    private let key: String

    init(key: String) {
        self.key = key
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        LyricsRuntimeProfile.increment("\(key).layout")
    }

    override func setFrameSize(_ newSize: NSSize) {
        let previous = frame
        super.setFrameSize(newSize)
        LyricsRuntimeProfile.recordFrameWrite(key: "\(key).frame", previous: previous, next: frame)
    }
}

private struct ScrollOffsetSensor: View {
    let onChange: (CGFloat) -> Void
    @State private var lastReportedOffset: CGFloat?

    private let reportEpsilon: CGFloat = 6.0

    var body: some View {
        GeometryReader { geo in
            let offset = geo.frame(in: .named("detailScroll")).minY
            Color.clear
                .onAppear {
                    report(offset)
                }
                .onChange(of: offset) { _, newOffset in
                    report(newOffset)
                }
        }
    }

    private func report(_ offset: CGFloat) {
        if let lastReportedOffset, abs(offset - lastReportedOffset) < reportEpsilon {
            return
        }
        lastReportedOffset = offset
        LyricsRuntimeProfile.increment("ScrollOffsetSensor.callback")
        onChange(offset)
    }
}

#Preview("Playlist Detail") { @MainActor in
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)

    PlaylistDetailView(pageController: PlaylistPageController())
        .environment(libraryVM)
        .environment(playerVM)
        .environment(PlaybackCoordinator(
            playerVM: playerVM,
            appleMusicAdapter: AppleMusicPlaybackAdapter(libraryVM: libraryVM)
        ))
        .environment(UIStateViewModel())
        .environmentObject(ThemeStore.shared)
        .frame(width: 500, height: 400)
        .task {
            await libraryVM.load()
        }
}
