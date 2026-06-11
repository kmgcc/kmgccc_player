//
//  PlaylistDetailView.swift
//  myPlayer2
//
//  kmgccc_player - Playlist Detail View
//  Displays tracks in a playlist or all songs.
//
//  Playlist-scoped toolbar content is declared here and surfaced via the window toolbar.
//

import AppKit
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
    @EnvironmentObject private var themeStore: ThemeStore

    let pageController: PlaylistPageController

    // MARK: - State

    @State private var trackToEdit: Track?
    @State private var batchEditRequest: BatchEditRequest?
    @State private var trackScrollFadeState = ScrollEdgeFadeState()
    @State private var detailScrollFadeState = ScrollEdgeFadeState()
    @State private var scrollFadeTopChromeInset: CGFloat = 0
    @State private var lifecycleToken = UUID()

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("PlaylistDetailView.body")
        let _ = TintTimelineProbe.noteRootConsumer("PlaylistDetailView.body")
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.hostBodyUpdate",
            detail: "surface=PlaylistDetailView, selection=\(selectionIdentity)"
        )
        Group {
            if libraryVM.currentSelection == .allSongs {
                if libraryVM.loadingPhase.isLoading && libraryVM.allTracks.isEmpty {
                    loadingView
                } else if libraryVM.loadingPhase.isFailed && libraryVM.allTracks.isEmpty {
                    errorView(message: libraryVM.lastLoadingError ?? "未知错误")
                } else if pageController.isSelectionTransitioning {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if activePage == nil {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if playableSourceTrackCount == 0 {
                    emptyStateView
                } else if currentRows.isEmpty && isFiltering {
                    noResultsView
                } else {
                    trackListView
                        .id("rows-\(selectionIdentity)")
                }
            } else {
                if libraryVM.loadingPhase.isLoading && pageController.page == nil && libraryVM.allTracks.isEmpty {
                    loadingView
                } else if libraryVM.loadingPhase.isFailed && pageController.page == nil {
                    errorView(message: libraryVM.lastLoadingError ?? "未知错误")
                } else if pageController.isSelectionTransitioning
                    || (libraryVM.state == .loading && pageController.page == nil)
                {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if activePage == nil {
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
        .background(
            PlaylistTopChromeInsetReader(topInset: $scrollFadeTopChromeInset)
                .allowsHitTesting(false)
        )
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
        }
        .onAppear {
            let token = FirstUseHitchDiagnostics.begin(
                "PlaylistDetailView.onAppear",
                detail: "selection=\(fallbackSelectionIdentity), tracks=\(libraryVM.allTracks.count)"
            )
            print(
                "[PlaylistDetailView] appear pageController=\(ObjectIdentifier(pageController).hashValue) "
                    + "libraryVM=\(ObjectIdentifier(libraryVM).hashValue) "
                    + "playbackCoord=\(ObjectIdentifier(playbackCoordinator).hashValue) "
                    + "uiState=\(ObjectIdentifier(uiState).hashValue)"
            )
            pageController.bind(libraryVM: libraryVM, playerVM: playerVM, uiState: uiState)
            pageController.appear(token: lifecycleToken)
            FirstUseHitchDiagnostics.end(token)
        }
        .onDisappear {
            pageController.disappear(token: lifecycleToken)
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
            pageController.clearSearchAndRebuildIfNeeded(reason: "search-reset")
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
    }

    // MARK: - Computed Properties

    private var isFiltering: Bool {
        !pageController.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activePage: PlaylistPageModel? {
        guard let page = pageController.page, page.selection == libraryVM.currentSelection else {
            return nil
        }
        return page
    }

    private var selectionIdentity: String {
        activePage?.selectionIdentity ?? fallbackSelectionIdentity
    }

    private var fallbackSelectionIdentity: String {
        switch libraryVM.currentSelection {
        case .home:
            return "home"
        case .allSongs:
            return "allSongs"
        case .allAlbums:
            return "allAlbums"
        case .allArtists:
            return "allArtists"
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
            get: {
                pageController.isManualTrackReorderActive ? nil : pageController.listScrollPositionID
            },
            set: { trackID in
                guard !pageController.isManualTrackReorderActive else { return }
                pageController.updateScrollPosition(trackID)
            }
        )
    }

    private var currentRows: [PlaylistPageRowModel] {
        activePage?.rows ?? []
    }

    private var queueTracks: [Track] {
        activePage?.queueTracks ?? []
    }

    private var detailHeaderModel: PlaylistPageHeaderModel? {
        activePage?.header
    }

    private var playableSourceTrackCount: Int {
        switch libraryVM.currentSelection {
        case .home, .allSongs:
            return libraryVM.allTracks.filter { $0.availability != .missing }.count
        case .playlist(let id):
            return libraryVM.playlists.first(where: { $0.id == id })?.tracks.filter {
                $0.availability != .missing
            }.count ?? 0
        case .artist(let key):
            return libraryVM.allTracks.filter {
                LibraryNormalization.containsArtist(key, in: $0.artist)
                    && $0.availability != .missing
            }.count
        case .album(let key):
            return libraryVM.allTracks.filter {
                $0.albumGroupKey == key
                    && $0.availability != .missing
            }.count
        case .allAlbums, .allArtists:
            return 0
        }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var trackRowsContent: some View {
        PlaylistTrackRowsSection(
            rows: currentRows,
            queueTracks: queueTracks,
            selection: libraryVM.currentSelection,
            selectionIdentity: selectionIdentity,
            currentTrackID: playerVM.currentTrack?.id,
            pageController: pageController,
            menuBuilder: erasedTrackMenu(trackID:),
            rowPrimaryColor: Color(nsColor: themeStore.appForegroundPalette.primary),
            rowSecondaryColor: Color(nsColor: themeStore.appForegroundPalette.secondary),
            rowTertiaryColor: Color(nsColor: themeStore.appForegroundPalette.tertiary)
        )
    }

    private var trackListView: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                trackRowsContent
                .padding(.top, scrollContentTopPadding)
                .padding(.bottom, listBottomPadding)
                .padding(.horizontal)
                .transaction { tx in
                    if !pageController.isManualTrackReorderActive {
                        tx.animation = nil
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height + scrollFadeTopChromeInset)
            .background(PlaylistLayoutPassProbe(key: "PlaylistDetailView.trackList"))
            .onScrollGeometryChange(for: ScrollEdgeFadeState.self) { geometry in
                ScrollEdgeFadeState(
                    geometry: geometry,
                    topFadeDistance: max(topFadeHeight, scrollFadeTopChromeInset),
                    bottomFadeDistance: bottomFadeHeight
                )
            } action: { _, newState in
                trackScrollFadeState = newState
            }
            .scrollEdgeFadeMask(
                trackScrollFadeState,
                topFadeHeight: topFadeHeight,
                bottomFadeHeight: bottomFadeHeight,
                topChromeInset: scrollFadeTopChromeInset
            )
            .offset(y: -scrollFadeTopChromeInset)
            .scrollPosition(id: scrollBinding, anchor: .top)
        }
    }

    private var detailScrollView: some View {
        GeometryReader { proxy in
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
                .padding(.top, scrollContentTopPadding)
                .padding(.bottom, listBottomPadding)
                .padding(.horizontal)
                .transaction { tx in
                    if !pageController.isManualTrackReorderActive {
                        tx.animation = nil
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height + scrollFadeTopChromeInset)
            .background(PlaylistLayoutPassProbe(key: "PlaylistDetailView.detailScroll"))
            .onScrollGeometryChange(for: ScrollEdgeFadeState.self) { geometry in
                ScrollEdgeFadeState(
                    geometry: geometry,
                    topFadeDistance: max(topFadeHeight, scrollFadeTopChromeInset),
                    bottomFadeDistance: bottomFadeHeight
                )
            } action: { _, newState in
                detailScrollFadeState = newState
            }
            .scrollEdgeFadeMask(
                detailScrollFadeState,
                topFadeHeight: topFadeHeight,
                bottomFadeHeight: bottomFadeHeight,
                topChromeInset: scrollFadeTopChromeInset
            )
            .coordinateSpace(name: "detailScroll")
            .offset(y: -scrollFadeTopChromeInset)
            .scrollPosition(id: scrollBinding, anchor: .top)
        }
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
                if case .album = libraryVM.currentSelection {
                    playbackCoordinator.playTracks(
                        queueTracks,
                        libraryQueueSource: .librarySelection(selectionIdentity),
                        startPolicy: .forceSequentialTemporary
                    )
                    return
                }
                playbackCoordinator.playRandomTracks(
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
        .environment(\.libraryPresentedAccentColor, pageController.headerAccentColor)

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
                trackRowsContent
                .padding(.horizontal, 16)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .controlSize(.large)
            Text(libraryVM.loadingPhase.displayText)
                .font(.body)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("加载失败")
                .font(.title3)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") {
                Task {
                    await libraryVM.reloadLibrary()
                }
            }
            .buttonStyle(.borderedProminent)
            .clipShape(Capsule())
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        let displayedCount = activePage?.displayedTrackCount ?? 0
        let filteredCount = activePage?.filteredTrackCount ?? 0
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

    private func trackMenu(trackID: UUID) -> AnyView {
        if let track = pageController.latestTrackFromLibrary(trackID: trackID) {
            if pageController.isMultiselectMode && pageController.selectedTrackIDs.contains(trackID) {
                return AnyView(Group {
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
                    let detail = "mode=batch, selected=\(pageController.selectedTrackIDs.count), playlists=\(libraryVM.playlists.count)"
                    let submenuToken = ContextMenuDiagnostics.beginSubmenuBuild(
                        surface: "TrackContextMenu",
                        detail: detail
                    )
                    let playlistToken = FirstUseHitchDiagnostics.begin(
                        "PlaylistActionSubmenu.build",
                        detail: detail
                    )
                    let hoverToken = FirstUseHitchDiagnostics.begin(
                        "PlaylistActionSubmenu.hoverOpen",
                        detail: detail
                    )
                    let _ = FirstUseHitchDiagnostics.end(hoverToken)
                    let _ = FirstUseHitchDiagnostics.end(playlistToken)
                    let _ = ContextMenuDiagnostics.end(submenuToken)

                    ForEach(libraryVM.playlists) { playlist in
                        if libraryVM.selectedPlaylist?.id != playlist.id {
                            Button {
                                processBatchAction(actionName: "batchAddToPlaylist") { tracks in
                                    await libraryVM.addTracksToPlaylist(tracks, playlist: playlist)
                                }
                            } label: {
                                Label(playlist.name, systemImage: "music.note.list")
                            }
                        }
                    }

                    Divider()

                    Button {
                        processBatchAction(actionName: "batchCreatePlaylistAndAdd") { tracks in
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
                        processBatchAction(actionName: "batchRemoveFromCurrentPlaylist") { tracks in
                            await libraryVM.removeTracksFromPlaylist(tracks, playlist: currentPlaylist)
                        }
                    } label: {
                        Label("从当前播放列表移除", systemImage: "minus.circle")
                    }
                }

                Divider()

                Button(role: .destructive) {
                    processBatchAction(actionName: "batchDeleteTracks") { tracks in
                        await libraryVM.deleteTracks(tracks)
                        await MainActor.run {
                            pageController.selectedTrackIDs.removeAll()
                        }
                    }
                } label: {
                    Label("从资料库删除", systemImage: "trash")
                }
                })
            } else {
                return AnyView(TrackActionMenuContent(
                    track: track,
                    canSelectMultiple: true,
                    selectedPlaylistID: libraryVM.selectedPlaylist?.id,
                    onSelectMultiple: {
                        pageController.beginMultiselectSelection(at: trackID)
                    },
                    onPlay: {
                        if case .album = libraryVM.currentSelection {
                            let startIndex = pageController.queueStartIndex(for: track.id)
                            playbackCoordinator.playTracks(
                                queueTracks,
                                startingAt: startIndex,
                                libraryQueueSource: .librarySelection(selectionIdentity),
                                startPolicy: .forceSequentialTemporary
                            )
                            return
                        }
                        playbackCoordinator.playTrack(
                            track,
                            inQueueFrom: queueTracks,
                            libraryQueueSource: .librarySelection(selectionIdentity)
                        )
                    },
                    onEditTrack: { trackToEdit = $0 },
                    onRemoveFromCurrentPlaylist: libraryVM.selectedPlaylist.map { currentPlaylist in
                        { track in
                            Task {
                                await libraryVM.removeTracksFromPlaylist([track], playlist: currentPlaylist)
                            }
                        }
                    }
                ))
            }
        } else {
            return AnyView(Text("library.track_unavailable"))
        }
    }

    private func processBatchAction(
        actionName: String = "batchAction",
        action: @escaping ([Track]) async -> Void
    ) {
        let selectedTracks = selectedTracksForBatchEditor()
        let token = ContextMenuDiagnostics.beginActionInvoke(
            surface: "TrackContextMenu",
            detail: "action=\(actionName), selected=\(selectedTracks.count)"
        )
        Task {
            await action(selectedTracks)
            await MainActor.run {
                pageController.clearMultiselectState()
            }
            ContextMenuDiagnostics.end(token)
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
        let detail = "track=\(FirstUseHitchDiagnostics.trackIDPrefix(trackID))"
        let opToken = ContextMenuDiagnostics.beginBuild(surface: "TrackContextMenu", detail: detail)
        defer { ContextMenuDiagnostics.end(opToken) }
        return trackMenu(trackID: trackID)
    }

    private var contentTopPadding: CGFloat { 16 }
    private var scrollContentTopPadding: CGFloat { contentTopPadding + scrollFadeTopChromeInset }
    private var listBottomPadding: CGFloat { 16 }
    private var topFadeHeight: CGFloat { 32 }
    private var bottomFadeHeight: CGFloat { 32 }
}

private final class PlaylistTopChromeInsetReaderView: NSView {
    var onTopInsetChange: ((CGFloat) -> Void)?
    private var lastTopInset: CGFloat = -1

    override func layout() {
        super.layout()
        updateTopInsetIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTopInsetIfNeeded()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateTopInsetIfNeeded()
    }

    private func updateTopInsetIfNeeded() {
        guard bounds.width > 0, bounds.height > 0, let contentView = window?.contentView else { return }

        let frameInContent = convert(bounds, to: contentView)
        let topInset = max(0, contentView.bounds.maxY - frameInContent.maxY)
        guard abs(topInset - lastTopInset) >= 0.5 else { return }

        lastTopInset = topInset
        onTopInsetChange?(topInset)
    }
}

private struct PlaylistTopChromeInsetReader: NSViewRepresentable {
    @Binding var topInset: CGFloat

    func makeNSView(context: Context) -> PlaylistTopChromeInsetReaderView {
        let view = PlaylistTopChromeInsetReaderView()
        view.onTopInsetChange = { topInset = $0 }
        return view
    }

    func updateNSView(_ nsView: PlaylistTopChromeInsetReaderView, context: Context) {
        nsView.onTopInsetChange = { topInset = $0 }
        nsView.needsLayout = true
    }
}

private struct PlaylistTrackRowsSection: View {
    @Environment(PlaybackCoordinator.self) private var playbackCoordinator

    let rows: [PlaylistPageRowModel]
    let queueTracks: [Track]
    let selection: LibrarySelection
    let selectionIdentity: String
    let currentTrackID: UUID?
    let pageController: PlaylistPageController
    let menuBuilder: (UUID) -> AnyView
    var rowPrimaryColor: Color = ColorTokens.textPrimary
    var rowSecondaryColor: Color = ColorTokens.textSecondary
    var rowTertiaryColor: Color = ColorTokens.textTertiary

    @Environment(\.colorScheme) private var colorScheme

    @State private var visualOrderIDs: [UUID]?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var dragContainerWidth: CGFloat = 0
    @State private var draggingTrackID: UUID?
    @State private var draggedTrackIDs: [UUID] = []
    @State private var dragStartOrderedIDs: [UUID] = []
    @State private var dragStartAnchorY: CGFloat = 0
    @State private var dragFloatingX: CGFloat = 0
    @State private var dragFloatingY: CGFloat = 0
    @State private var dragLastTargetIndex: Int = 0
    @State private var dragInsertionIndex: Int?
    @State private var dragCardYOffsetByID: [UUID: CGFloat] = [:]
    @State private var dragPointerYOffset: CGFloat = 0
    @State private var dragGlassOpacity: Double = 0
    @State private var dragDidReorder = false
    @State private var isFinishingDrag = false
    @State private var enclosingScrollView: NSScrollView?
    @State private var reorderCoordinateView: NSView?
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var autoScrollVelocity: CGFloat = 0

    private let trackReorderSpace = "playlistTrackReorderSpace"
    private let dragHorizontalDamping: CGFloat = 0.45
    private let dragHorizontalLimit: CGFloat = 28
    private let autoScrollEdgeThreshold: CGFloat = 118
    private let autoScrollBottomEdgeThreshold: CGFloat = 176
    private let autoScrollMaxVelocity: CGFloat = 500
    private let autoScrollMinVelocity: CGFloat = 22
    private let autoScrollFrameInterval: UInt64 = 16_000_000
    private let maxVisibleDraggedCards = 5
    private let pileCardOverlap: CGFloat = 12
    private let pileHorizontalJitter: CGFloat = 5

    private var dragReorderAnimation: Animation {
        .spring(response: 0.30, dampingFraction: 0.88, blendDuration: 0.04)
    }

    private var dragSettleAnimation: Animation {
        .spring(response: 0.38, dampingFraction: 0.90, blendDuration: 0.04)
    }

    var body: some View {
        let _ = LyricsRuntimeProfile.markBody("PlaylistTrackRowsSection.body")
        let _ = ContextMenuDiagnostics.markBodyUpdate(
            "contextMenu.hostBodyUpdate",
            detail: "surface=PlaylistTrackRowsSection, rows=\(rows.count), current=\(FirstUseHitchDiagnostics.trackIDPrefix(currentTrackID))"
        )
        ZStack(alignment: .topLeading) {
            selectedTrackRunBackgrounds
                .allowsHitTesting(false)

            LazyVStack(spacing: 0) {
                ForEach(displayRows) { row in
                    trackRowContainer(row)
                        .background(rowFrameReporter(for: row.id))
                }
                Color.clear.frame(height: 160)
            }
            .scrollTargetLayout()
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { dragContainerWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, newValue in
                            dragContainerWidth = newValue
                        }
                }
            )
            .coordinateSpace(name: trackReorderSpace)
            .background(
                EnclosingScrollViewReader { scrollView, coordinateView in
                    enclosingScrollView = scrollView
                    reorderCoordinateView = coordinateView
                }
            )
                .onPreferenceChange(TrackRowFramePreferenceKey.self) { frames in
                    rowFrames = frames
                }

            if let rect = dragPlaceholderRect, !isFinishingDrag {
                RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.cornerRadius + 2)
                    .strokeBorder(
                        Color.accentColor.opacity(0.72),
                        style: StrokeStyle(
                            lineWidth: 2.2,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: [8, 6]
                        )
                    )
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .zIndex(5)
            }

            if draggingTrackID != nil {
                floatingDragGroup
                    .frame(width: dragContainerWidth, alignment: .topLeading)
                    .offset(x: dragFloatingX, y: dragFloatingY)
                    .allowsHitTesting(false)
                    .zIndex(10)
            }
        }
        .background(
            MultiselectExitKeyMonitor(
                isEnabled: pageController.isMultiselectMode,
                onEscape: {
                    if pageController.isManualTrackReorderActive {
                        cancelDrag()
                    } else {
                        pageController.clearMultiselectState()
                    }
                },
                onReturn: {
                    guard !pageController.isManualTrackReorderActive else { return }
                    pageController.clearMultiselectState()
                }
            )
        )
        .onExitCommand {
            if draggingTrackID != nil {
                cancelDrag()
            } else if pageController.isMultiselectMode {
                pageController.clearMultiselectState()
            }
        }
        .onDisappear {
            cancelDrag()
            stopAutoScroll()
        }
        .onChange(of: rows.map(\.id)) { _, _ in
            if draggingTrackID == nil {
                visualOrderIDs = nil
            } else if !isFinishingDrag {
                cancelDrag()
            }
        }
        .onChange(of: pageController.isMultiselectMode) { _, isEnabled in
            if !isEnabled {
                cancelDrag()
            }
        }
        .onChange(of: pageController.isSearchFilteringTracks) { _, isFiltering in
            if isFiltering {
                cancelDrag()
            }
        }
    }

    private var isReorderEnabled: Bool {
        pageController.isMultiselectMode
            && pageController.canManuallyReorderCurrentTracks
            && !pageController.isSearchFilteringTracks
            && rows.count > 1
    }

    private var rowLookup: [UUID: PlaylistPageRowModel] {
        Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    private var displayedOrderIDs: [UUID] {
        let source = rows.map(\.id)
        guard let visualOrderIDs else { return source }
        let validIDs = Set(source)
        let ordered = visualOrderIDs.filter { validIDs.contains($0) }
        guard ordered.count == source.count else { return source }
        return ordered
    }

    private var displayRows: [PlaylistPageRowModel] {
        let lookup = rowLookup
        return displayedOrderIDs.compactMap { lookup[$0] }
    }

    private var draggedRows: [PlaylistPageRowModel] {
        let lookup = rowLookup
        return draggedTrackIDs.compactMap { lookup[$0] }
    }

    private var visibleDraggedRows: [PlaylistPageRowModel] {
        Array(draggedRows.prefix(maxVisibleDraggedCards))
    }

    private var floatingDraggedRows: [PlaylistPageRowModel] {
        draggedRows
    }

    private var draggedTrackIDSet: Set<UUID> {
        Set(draggedTrackIDs)
    }

    private var selectedTrackBackgroundFill: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.15)
    }

    private var selectedTrackRuns: [(first: UUID, ids: [UUID])] {
        guard pageController.isMultiselectMode else { return [] }
        var selectedIDs = pageController.selectedTrackIDs
        if draggingTrackID != nil {
            selectedIDs.subtract(draggedTrackIDSet)
        }
        guard !selectedIDs.isEmpty else { return [] }

        var runs: [(first: UUID, ids: [UUID])] = []
        var currentRun: [UUID] = []
        for id in displayedOrderIDs {
            if selectedIDs.contains(id) {
                currentRun.append(id)
            } else if !currentRun.isEmpty {
                runs.append((first: currentRun[0], ids: currentRun))
                currentRun = []
            }
        }
        if !currentRun.isEmpty {
            runs.append((first: currentRun[0], ids: currentRun))
        }
        return runs
    }

    private var dragPlaceholderRect: CGRect? {
        guard draggingTrackID != nil, !draggedTrackIDs.isEmpty else { return nil }
        let frames = draggedTrackIDs.compactMap { rowFrames[$0] }
        guard let firstFrame = frames.first else { return nil }
        let union = frames.dropFirst().reduce(firstFrame) { partial, frame in
            partial.union(frame)
        }
        let insetX: CGFloat = 4
        let insetY: CGFloat = 5
        return CGRect(
            x: insetX,
            y: union.minY + insetY,
            width: max(0, dragContainerWidth - insetX * 2),
            height: max(0, union.height - insetY * 2)
        )
    }

    private var dragGroupHeight: CGFloat {
        guard !visibleDraggedRows.isEmpty else { return 0 }
        let visibleCount = max(1, min(draggedRows.count, maxVisibleDraggedCards))
        let maxRowHeight = visibleDraggedRows.map(rowHeight(for:)).max() ?? Constants.Layout.TrackRow.height
        return maxRowHeight + CGFloat(visibleCount - 1) * pileCardOverlap + 16
    }

    private var insertionIndicatorY: CGFloat? {
        guard draggingTrackID != nil, let dragInsertionIndex else { return nil }
        let remaining = displayedOrderIDs.filter { !draggedTrackIDSet.contains($0) }
        if remaining.isEmpty {
            return dragFloatingY
        }
        if dragInsertionIndex < remaining.count,
           let frame = rowFrames[remaining[dragInsertionIndex]] {
            return frame.minY
        }
        if dragInsertionIndex > 0,
           let frame = rowFrames[remaining[dragInsertionIndex - 1]] {
            return frame.maxY
        }
        if let first = remaining.first,
           let frame = rowFrames[first] {
            return frame.minY
        }
        return nil
    }

    private var floatingDragGroup: some View {
        ZStack(alignment: .topTrailing) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(floatingDraggedRows.enumerated()), id: \.element.id) { depth, row in
                    let settling = isFinishingDrag
                    let pileDepth = min(depth, maxVisibleDraggedCards - 1)
                    let pileX = settling ? 0 : pileXOffset(for: row.id, depth: pileDepth)
                    let pileY = settling ? 0 : pileYOffset(pileDepth)
                    floatingTrackCard(row)
                        .frame(
                            width: dragContainerWidth,
                            height: rowHeight(for: row),
                            alignment: .topLeading
                        )
                        .offset(
                            x: pileX,
                            y: pileY
                        )
                        .offset(y: dragCardYOffsetByID[row.id] ?? 0)
                        .rotationEffect(
                            .degrees(settling ? 0 : pileRotationDegrees(for: row.id, depth: pileDepth)),
                            anchor: .center
                        )
                        .opacity(settling || depth < maxVisibleDraggedCards ? 1 : 0)
                        .zIndex(Double(floatingDraggedRows.count - depth))
                }
            }
            .frame(height: dragGroupHeight, alignment: .topLeading)
            .shadow(
                color: GlassStyleTokens.subtleShadowColor,
                radius: GlassStyleTokens.subtleShadowRadius + 5,
                x: 0,
                y: 5
            )

            if draggedTrackIDs.count > 1 && !isFinishingDrag {
                Text("\(draggedTrackIDs.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
                    .offset(x: 5, y: -6)
            }
        }
    }

    private func floatingTrackCard(_ row: PlaylistPageRowModel) -> some View {
        let shape = RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.cornerRadius)
        return TrackRowView(
            model: row.trackRowModel,
            isPlaying: currentTrackID == row.id,
            isSelected: true,
            enableSecondaryInteractions: false,
            enableArtworkLoading: pageController.areRowArtworkLoadsEnabled,
            onTap: { _ in },
            rowPrimaryColor: rowPrimaryColor,
            rowSecondaryColor: rowSecondaryColor,
            rowTertiaryColor: rowTertiaryColor
        ) {
            EmptyView()
        }
        .equatable()
        .frame(
            width: dragContainerWidth,
            height: rowHeight(for: row),
            alignment: .topLeading
        )
        .background(
            shape
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                .glassEffect(.regular, in: shape)
                .opacity(dragGlassOpacity)
        )
        .overlay(
            shape
                .strokeBorder(Color.white.opacity(0.16 * dragGlassOpacity), lineWidth: 0.8)
        )
        .clipShape(shape)
    }

    private func trackRowContainer(_ row: PlaylistPageRowModel) -> some View {
        let isDragged = draggingTrackID != nil && draggedTrackIDSet.contains(row.id)
        return ZStack {
            trackRowPlaceholder()
                .opacity(isDragged ? 1 : 0)
            trackRow(row)
                .opacity(isDragged ? 0 : 1)
        }
        .contentShape(Rectangle())
        .playlistTrackReorderGesture(
            isReorderEnabled,
            reorderGesture(for: row)
        )
        .contextMenu {
            if pageController.areRowSecondaryInteractionsEnabled {
                menuBuilder(row.id)
            }
        }
    }

    private func trackRow(_ row: PlaylistPageRowModel) -> some View {
        TrackRowView(
            model: row.trackRowModel,
            isPlaying: currentTrackID == row.id,
            isSelected: pageController.isMultiselectMode && pageController.selectedTrackIDs.contains(row.id),
            selectionContinuity: selectionContinuity(for: row.id),
            showsSelectionBackground: false,
            enableSecondaryInteractions: pageController.areRowSecondaryInteractionsEnabled,
            enableArtworkLoading: pageController.areRowArtworkLoadsEnabled,
            onTap: { isShiftPressed in
                if pageController.isMultiselectMode {
                    pageController.handleMultiselectRowTap(
                        trackID: row.id,
                        extendingRange: isShiftPressed
                    )
                } else {
                    guard let track = pageController.latestTrackFromLibrary(trackID: row.id) else { return }
                    if case .album = selection {
                        let startIndex = pageController.queueStartIndex(for: row.id)
                        playbackCoordinator.playTracks(
                            queueTracks,
                            startingAt: startIndex,
                            libraryQueueSource: .librarySelection(selectionIdentity),
                            startPolicy: .forceSequentialTemporary
                        )
                        return
                    }
                    playbackCoordinator.playTrack(
                        track,
                        inQueueFrom: queueTracks,
                        libraryQueueSource: .librarySelection(selectionIdentity)
                    )
                }
            },
            onRowAppear: {
                pageController.prefetchAroundTrackID(row.id)
            },
            rowPrimaryColor: rowPrimaryColor,
            rowSecondaryColor: rowSecondaryColor,
            rowTertiaryColor: rowTertiaryColor
        ) {
            menuBuilder(row.id)
        }
        .equatable()
    }

    private var selectedTrackRunBackgrounds: some View {
        ZStack(alignment: .topLeading) {
            ForEach(selectedTrackRuns, id: \.first) { run in
                if let rect = selectedRunRect(run) {
                    RoundedRectangle(cornerRadius: Constants.Layout.TrackRow.cornerRadius)
                        .fill(selectedTrackBackgroundFill)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }

    private func selectedRunRect(_ run: (first: UUID, ids: [UUID])) -> CGRect? {
        guard
            let firstID = run.ids.first,
            let lastID = run.ids.last,
            let firstFrame = rowFrames[firstID],
            let lastFrame = rowFrames[lastID]
        else { return nil }

        return CGRect(
            x: 0,
            y: firstFrame.minY,
            width: dragContainerWidth,
            height: max(0, lastFrame.maxY - firstFrame.minY)
        )
    }

    private func trackRowPlaceholder() -> some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
    }

    private func rowFrameReporter(for trackID: UUID) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: TrackRowFramePreferenceKey.self,
                value: [trackID: proxy.frame(in: .named(trackReorderSpace))]
            )
        }
    }

    private func reorderGesture(for row: PlaylistPageRowModel) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(trackReorderSpace))
            .onChanged { value in
                if draggingTrackID != row.id {
                    beginDrag(from: row.id, initialLocationY: value.location.y)
                }
                guard draggingTrackID == row.id else { return }

                dragFloatingY = floatingTopY(for: value)
                dragFloatingX = max(
                    -dragHorizontalLimit,
                    min(dragHorizontalLimit, value.translation.width * dragHorizontalDamping)
                )

                let centerY = dragFloatingY + dragGroupHeight / 2
                updateAutoScroll(forCenterY: centerY)
                updateDragTarget(forCenterY: centerY)
            }
            .onEnded { _ in
                endDrag()
            }
    }

    private func beginDrag(from trackID: UUID, initialLocationY: CGFloat?) {
        let startOrder = displayedOrderIDs
        guard startOrder.contains(trackID) else { return }

        let selectedIDs = pageController.selectedTrackIDs
        let groupIDs: [UUID]
        if selectedIDs.contains(trackID) {
            groupIDs = startOrder.filter { selectedIDs.contains($0) }
        } else {
            groupIDs = [trackID]
        }
        guard !groupIDs.isEmpty else { return }

        pageController.beginManualTrackReorderInteraction()
        visualOrderIDs = startOrder
        draggingTrackID = trackID
        draggedTrackIDs = groupIDs
        dragStartOrderedIDs = startOrder
        dragStartAnchorY = rowFrames[trackID]?.minY ?? 0
        let initialPointerY = currentMouseYInReorderSpace()
            ?? initialLocationY
            ?? dragStartAnchorY + Constants.Layout.TrackRow.height / 2
        dragPointerYOffset = initialPointerY - dragStartAnchorY
        dragFloatingY = dragStartAnchorY
        dragFloatingX = 0
        dragGlassOpacity = 0
        dragDidReorder = false
        isFinishingDrag = false

        let remaining = startOrder.filter { !Set(groupIDs).contains($0) }
        let originalTarget = insertionIndexForCurrentGroup(
            groupIDs: groupIDs,
            in: startOrder,
            remaining: remaining
        )
        dragLastTargetIndex = originalTarget
        dragInsertionIndex = originalTarget

        var gatherOffsets: [UUID: CGFloat] = [:]
        for (depth, id) in groupIDs.enumerated() {
            let pileDepth = min(depth, maxVisibleDraggedCards - 1)
            let sourceY = rowFrames[id]?.minY ?? dragStartAnchorY + pileYOffset(pileDepth)
            gatherOffsets[id] = sourceY - dragStartAnchorY - pileYOffset(pileDepth)
        }
        dragCardYOffsetByID = gatherOffsets
        withAnimation(dragReorderAnimation) {
            dragCardYOffsetByID = [:]
            dragGlassOpacity = 1
        }
    }

    private func moveDraggedRows(to targetIndex: Int) {
        guard let visualOrderIDs else { return }
        let draggedSet = Set(draggedTrackIDs)
        var remaining = visualOrderIDs.filter { !draggedSet.contains($0) }
        let index = max(0, min(remaining.count, targetIndex))
        remaining.insert(contentsOf: draggedTrackIDs, at: index)
        guard remaining != visualOrderIDs else { return }
        dragDidReorder = true
        withAnimation(dragReorderAnimation) {
            self.visualOrderIDs = remaining
        }
    }

    private func endDrag() {
        guard draggingTrackID != nil else { return }
        stopAutoScroll()
        let finalOrder = visualOrderIDs ?? rows.map(\.id)
        let shouldCommit = dragDidReorder && finalOrder != dragStartOrderedIDs

        if shouldCommit {
            pageController.commitManualTrackOrder(
                orderedTrackIDs: finalOrder,
                reason: "manual-track-reorder"
            )
        }

        settleDrag(commitSucceeded: shouldCommit)
    }

    private func settleDrag(commitSucceeded: Bool) {
        guard let draggingTrackID else { return }
        let settledOrder = visualOrderIDs
        let finalY = finalDraggedGroupTopY() ?? insertionIndicatorY ?? dragFloatingY
        let settleOffsets = finalDraggedCardYOffsets(groupTopY: finalY)
        withAnimation(dragSettleAnimation) {
            isFinishingDrag = true
            dragFloatingX = 0
            dragFloatingY = finalY
            dragCardYOffsetByID = settleOffsets
            dragGlassOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard isFinishingDrag, self.draggingTrackID == draggingTrackID else { return }
            let keepVisualOrder = commitSucceeded
                && settledOrder != nil
                && rows.map(\.id) != settledOrder
            clearDragState(keepVisualOrder: keepVisualOrder)
        }
    }

    private func cancelDrag() {
        guard draggingTrackID != nil else { return }
        stopAutoScroll()
        withAnimation(dragSettleAnimation) {
            visualOrderIDs = dragStartOrderedIDs.isEmpty ? nil : dragStartOrderedIDs
            dragFloatingX = 0
            dragFloatingY = dragStartAnchorY
            dragGlassOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            guard !isFinishingDrag else { return }
            clearDragState(keepVisualOrder: false)
        }
    }

    private func clearDragState(keepVisualOrder: Bool) {
        if !keepVisualOrder {
            visualOrderIDs = nil
        }
        draggingTrackID = nil
        draggedTrackIDs = []
        dragStartOrderedIDs = []
        dragStartAnchorY = 0
        dragPointerYOffset = 0
        dragFloatingX = 0
        dragFloatingY = 0
        dragLastTargetIndex = 0
        dragInsertionIndex = nil
        dragCardYOffsetByID = [:]
        dragGlassOpacity = 0
        dragDidReorder = false
        isFinishingDrag = false
        stopAutoScroll()
        pageController.endManualTrackReorderInteraction()
    }

    private func targetInsertionIndex(forCenterY centerY: CGFloat) -> Int {
        let remaining = displayedOrderIDs.filter { !draggedTrackIDSet.contains($0) }
        guard !remaining.isEmpty else { return 0 }

        let visibleRows = remaining.enumerated().compactMap { index, id -> (index: Int, frame: CGRect)? in
            guard let frame = rowFrames[id] else { return nil }
            return (index, frame)
        }
        guard let firstVisible = visibleRows.first else {
            return max(0, min(remaining.count, dragLastTargetIndex))
        }

        if centerY < firstVisible.frame.midY {
            return firstVisible.index
        }

        for visible in visibleRows where centerY < visible.frame.midY {
            return visible.index
        }

        if let lastVisible = visibleRows.last {
            return min(remaining.count, lastVisible.index + 1)
        }
        return remaining.count
    }

    private func insertionIndexForCurrentGroup(
        groupIDs: [UUID],
        in order: [UUID],
        remaining: [UUID]
    ) -> Int {
        guard let firstDraggedIndex = order.firstIndex(where: { groupIDs.contains($0) }) else {
            return 0
        }
        let removedBefore = order[..<firstDraggedIndex].filter { groupIDs.contains($0) }.count
        return max(0, min(remaining.count, firstDraggedIndex - removedBefore))
    }

    private func updateDragTarget(forCenterY centerY: CGFloat) {
        let target = targetInsertionIndex(forCenterY: centerY)
        dragInsertionIndex = target
        guard target != dragLastTargetIndex else { return }
        dragLastTargetIndex = target
        moveDraggedRows(to: target)
    }

    private func updateAutoScroll(forCenterY centerY: CGFloat) {
        let velocity = autoScrollVelocity(forCenterY: centerY)
        autoScrollVelocity = velocity
        if abs(velocity) > 0.5 {
            startAutoScrollIfNeeded()
        } else {
            stopAutoScroll()
        }
    }

    private func autoScrollVelocity(forCenterY centerY: CGFloat) -> CGFloat {
        guard
            let viewport = visibleTrackViewportInReorderSpace(),
            let scrollBounds = autoScrollOriginBounds()
        else { return 0 }

        let canScrollUp = scrollBounds.originY > scrollBounds.minY + 0.5
        let canScrollDown = scrollBounds.originY < scrollBounds.maxY - 0.5

        let topRatio = max(0, min(1, (autoScrollEdgeThreshold - (centerY - viewport.minY)) / autoScrollEdgeThreshold))
        let bottomRatio = max(0, min(1, (autoScrollBottomEdgeThreshold - (viewport.maxY - centerY)) / autoScrollBottomEdgeThreshold))

        if canScrollUp, topRatio > bottomRatio, topRatio > 0 {
            return -scaledAutoScrollVelocity(for: topRatio)
        }
        if canScrollDown, bottomRatio > 0 {
            return scaledAutoScrollVelocity(for: bottomRatio)
        }
        return 0
    }

    private func scaledAutoScrollVelocity(for ratio: CGFloat) -> CGFloat {
        let eased = pow(Double(ratio), 1.7)
        return autoScrollMinVelocity
            + (autoScrollMaxVelocity - autoScrollMinVelocity) * CGFloat(eased)
    }

    private func startAutoScrollIfNeeded() {
        guard autoScrollTask == nil else { return }
        autoScrollTask = Task { @MainActor in
            while !Task.isCancelled {
                performAutoScrollStep()
                try? await Task.sleep(nanoseconds: autoScrollFrameInterval)
            }
        }
    }

    private func stopAutoScroll() {
        autoScrollTask?.cancel()
        autoScrollTask = nil
        autoScrollVelocity = 0
    }

    private func performAutoScrollStep() {
        guard draggingTrackID != nil, abs(autoScrollVelocity) > 0.5 else {
            stopAutoScroll()
            return
        }

        let delta = scrollEnclosingScrollView(by: autoScrollVelocity / 60)
        guard abs(delta) > 0.05 else {
            stopAutoScroll()
            return
        }

        if let mouseY = currentMouseYInReorderSpace() {
            dragFloatingY = mouseY - dragPointerYOffset
        }
        let centerY = dragFloatingY + dragGroupHeight / 2
        updateDragTarget(forCenterY: centerY)
        updateAutoScroll(forCenterY: centerY)
    }

    @discardableResult
    private func scrollEnclosingScrollView(by delta: CGFloat) -> CGFloat {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        else { return 0 }

        let clipView = scrollView.contentView
        let oldOrigin = clipView.bounds.origin
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let minY = delta < 0 ? min(maxY, minimumAutoScrollOriginY(in: documentView)) : 0
        guard delta >= 0 || oldOrigin.y > minY + 0.05 else { return 0 }
        let newY = max(minY, min(maxY, oldOrigin.y + delta))
        guard abs(newY - oldOrigin.y) > 0.05 else { return 0 }

        clipView.scroll(to: NSPoint(x: oldOrigin.x, y: newY))
        scrollView.reflectScrolledClipView(clipView)
        return newY - oldOrigin.y
    }

    private func visibleTrackViewportInReorderSpace() -> CGRect? {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView,
            let coordinateView = reorderCoordinateView
        else { return nil }

        let viewport = coordinateView
            .convert(scrollView.contentView.documentVisibleRect, from: documentView)
            .standardized
        let clippedViewport = viewport.intersection(coordinateView.bounds).standardized
        guard !clippedViewport.isNull, clippedViewport.height > 0 else { return nil }
        return clippedViewport
    }

    private func autoScrollOriginBounds() -> (originY: CGFloat, minY: CGFloat, maxY: CGFloat)? {
        guard
            let scrollView = enclosingScrollView,
            let documentView = scrollView.documentView
        else { return nil }

        let clipView = scrollView.contentView
        let maxY = max(0, documentView.bounds.height - clipView.bounds.height)
        let minY = min(maxY, minimumAutoScrollOriginY(in: documentView))
        return (clipView.bounds.origin.y, minY, maxY)
    }

    private func finalDraggedGroupTopY() -> CGFloat? {
        guard let firstDraggedID = draggedTrackIDs.first else { return nil }
        return rowFrames[firstDraggedID]?.minY
    }

    private func finalDraggedCardYOffsets(groupTopY: CGFloat) -> [UUID: CGFloat] {
        var offsets: [UUID: CGFloat] = [:]
        for id in draggedTrackIDs {
            if let frame = rowFrames[id] {
                offsets[id] = frame.minY - groupTopY
            }
        }
        return offsets
    }

    private func floatingTopY(for value: DragGesture.Value) -> CGFloat {
        let pointerY = currentMouseYInReorderSpace() ?? value.location.y
        return pointerY - dragPointerYOffset
    }

    private func currentMouseYInReorderSpace() -> CGFloat? {
        guard
            let coordinateView = reorderCoordinateView,
            let window = coordinateView.window
        else { return nil }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return coordinateView.convert(windowPoint, from: nil).y
    }

    private func minimumAutoScrollOriginY(in documentView: NSView) -> CGFloat {
        guard let coordinateView = reorderCoordinateView else { return 0 }
        let trackRect = coordinateView.convert(coordinateView.bounds, to: documentView)
        return max(0, trackRect.minY)
    }

    private func selectionContinuity(for trackID: UUID) -> TrackRowSelectionContinuity {
        let selectedIDs = pageController.selectedTrackIDs
        guard pageController.isMultiselectMode, selectedIDs.contains(trackID) else {
            return .isolated
        }
        let order = displayedOrderIDs
        guard let index = order.firstIndex(of: trackID) else { return .isolated }
        let connectsToPrevious = index > 0 && selectedIDs.contains(order[index - 1])
        let connectsToNext = index + 1 < order.count && selectedIDs.contains(order[index + 1])
        return TrackRowSelectionContinuity(
            connectsToPrevious: connectsToPrevious,
            connectsToNext: connectsToNext
        )
    }

    private func pileYOffset(_ depth: Int) -> CGFloat {
        CGFloat(depth) * pileCardOverlap
    }

    private func pileXOffset(for id: UUID, depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        let seed = pileSeed(for: id)
        let normalized = CGFloat((seed % 7) - 3) / 3
        return normalized * pileHorizontalJitter
    }

    private func pileRotationDegrees(for id: UUID, depth: Int) -> Double {
        guard depth > 0 else { return 0 }
        let seed = pileSeed(for: id)
        let sign: Double = seed.isMultiple(of: 2) ? 1 : -1
        return sign * (1.2 + Double(seed % 11) * 0.18)
    }

    private func pileSeed(for id: UUID) -> Int {
        id.uuidString.unicodeScalars.reduce(0) { partial, scalar in
            partial &+ Int(scalar.value)
        }
    }

    private func rowHeight(for row: PlaylistPageRowModel) -> CGFloat {
        let snippet = row.lyricSnippetLine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return snippet.isEmpty
            ? Constants.Layout.TrackRow.height
            : Constants.Layout.TrackRow.lyricSnippetHeight
    }
}

private struct EnclosingScrollViewReader: NSViewRepresentable {
    let onResolve: (NSScrollView?, NSView?) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveSoon()
    }

    final class ResolverView: NSView {
        var onResolve: ((NSScrollView?, NSView?) -> Void)?

        override var isFlipped: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveSoon()
        }

        func resolveSoon() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                onResolve?(enclosingScrollView(), self)
            }
        }

        private func enclosingScrollView() -> NSScrollView? {
            var view = superview
            while let current = view {
                if let scrollView = current as? NSScrollView {
                    return scrollView
                }
                view = current.superview
            }
            return nil
        }
    }
}

private struct MultiselectExitKeyMonitor: NSViewRepresentable {
    let isEnabled: Bool
    let onEscape: () -> Void
    let onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.update(
            isEnabled: isEnabled,
            onEscape: onEscape,
            onReturn: onReturn
        )
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(
            isEnabled: isEnabled,
            onEscape: onEscape,
            onReturn: onReturn
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        private var monitor: Any?
        private var isEnabled = false
        private var onEscape: () -> Void = {}
        private var onReturn: () -> Void = {}

        func update(
            isEnabled: Bool,
            onEscape: @escaping () -> Void,
            onReturn: @escaping () -> Void
        ) {
            self.isEnabled = isEnabled
            self.onEscape = onEscape
            self.onReturn = onReturn
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handle(event) ?? event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            guard isEnabled, !isTextInputActive(for: event) else { return event }
            switch event.keyCode {
            case 36, 76:
                onReturn()
                return nil
            case 53:
                onEscape()
                return nil
            default:
                return event
            }
        }

        private func isTextInputActive(for event: NSEvent) -> Bool {
            guard let responder = event.window?.firstResponder else { return false }
            if responder is NSTextView || responder is NSTextField {
                return true
            }
            return String(describing: type(of: responder)).contains("FieldEditor")
        }
    }
}

private struct TrackRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private extension View {
    @ViewBuilder
    func playlistTrackReorderGesture<G: Gesture>(_ enabled: Bool, _ gesture: G) -> some View {
        if enabled {
            highPriorityGesture(gesture)
        } else {
            self
        }
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
    @State private var lastReportUptime: TimeInterval = 0

    private let reportEpsilon: CGFloat = 18.0
    private let minReportInterval: TimeInterval = 1.0 / 30.0

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
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastReportUptime >= minReportInterval else { return }
        lastReportedOffset = offset
        lastReportUptime = now
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
            appleMusicAdapter: AppleMusicPlaybackAdapter(libraryVM: libraryVM),
            systemNowPlayingProvider: SystemNowPlayingProvider(libraryVM: libraryVM)
        ))
        .environment(UIStateViewModel())
        .environmentObject(ThemeStore.shared)
        .frame(width: 500, height: 400)
        .task {
            await libraryVM.load()
        }
}
