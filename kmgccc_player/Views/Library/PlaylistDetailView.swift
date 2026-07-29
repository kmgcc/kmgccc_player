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
    @Environment(LibraryCacheServices.self) private var cacheServices
    @Environment(UIStateViewModel.self) private var uiState
    @EnvironmentObject private var themeStore: ThemeStore

    let pageController: PlaylistPageController


    @State private var trackToEdit: Track?
    @State private var trackDeletionRequest: TrackDeletionConfirmationRequest?
    @State private var batchEditRequest: BatchEditRequest?
    @State private var trackScrollFadeState = ScrollEdgeFadeState()
    @State private var detailScrollFadeState = ScrollEdgeFadeState()
    @State private var scrollFadeTopChromeInset: CGFloat = 0
    @State private var lifecycleToken = UUID()

    private let revealScrollAnchor = UnitPoint(x: 0.5, y: 0.18)

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
        .trackDeletionConfirmation(item: $trackDeletionRequest) { tracks in
            confirmTrackDeletion(tracks)
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
            pageController.bind(
                libraryVM: libraryVM,
                playerVM: playerVM,
                uiState: uiState,
                cacheServices: cacheServices
            )
            pageController.appear(token: lifecycleToken)
            FirstUseHitchDiagnostics.end(token)
        }
        .onDisappear {
            pageController.disappear(token: lifecycleToken)
            pageController.clearMultiselectState()
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
        .onChange(of: themeStore.colorScheme) { _, newScheme in
            pageController.colorSchemeDidChange(to: newScheme)
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
        libraryVM.currentSelection.selectionIdentity(in: libraryVM)
    }

    private var scrollBinding: Binding<UUID?> {
        Binding(
            get: {
                pageController.isManualTrackReorderActive ? nil : pageController.listScrollPositionID
            },
            set: { trackID in
                guard !pageController.isManualTrackReorderActive else { return }
                // While a reveal scroll is armed/animating, ignore position
                // updates from the scroll view. A freshly-created ScrollView
                // (after a playlist switch) can report nil or the first visible
                // row before the target is scrolled to, which would clobber the
                // reveal target.
                if pageController.isRevealScrollArmed { return }
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
        case .allPlaylists, .allAlbums, .allArtists:
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
            rowPrimaryColor: themeStore.appForegroundPalette.primaryColor,
            rowSecondaryColor: themeStore.appForegroundPalette.secondaryColor,
            rowTertiaryColor: themeStore.appForegroundPalette.tertiaryColor
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
            .scrollPosition(id: scrollBinding, anchor: revealScrollAnchor)
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
            .scrollPosition(id: scrollBinding, anchor: revealScrollAnchor)
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
            isColorReady: pageController.isHeaderColorReady,
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
        .environment(\.libraryHeaderSemanticPalette, pageController.headerSemanticPalette)
        .environment(\.libraryHeaderForegroundPalette, pageController.headerForegroundPalette)

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
                    await libraryVM.importToCurrentContext(contentMode: uiState.contentMode)
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

                if playbackCoordinator.canInsertTracksAfterCurrent {
                    Button {
                        processBatchAction(actionName: "batchPlayNext") { tracks in
                            insertTracksAfterCurrent(tracks)
                        }
                    } label: {
                        Label("下一首播放", systemImage: "text.line.first.and.arrowtriangle.forward")
                    }

                    Divider()
                }

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
                    requestTrackDeletion(selectedTracksForBatchEditor())
                } label: {
                    Label("从资料库删除", systemImage: "trash")
                }
                })
            } else {
                return AnyView(TrackActionMenuContent(
                    track: track,
                    canSelectMultiple: !pageController.isSearchFilteringTracks,
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
                    onPlayNext: playbackCoordinator.canInsertTracksAfterCurrent
                        ? { playbackCoordinator.insertTracksAfterCurrent([track]) }
                        : nil,
                    onEditTrack: { trackToEdit = $0 },
                    onDeleteFromLibraryRequest: { track in
                        requestTrackDeletion([track])
                    },
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

    private func requestTrackDeletion(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        trackDeletionRequest = TrackDeletionConfirmationRequest(tracks: tracks)
    }

    private func confirmTrackDeletion(_ tracks: [Track]) {
        let token = ContextMenuDiagnostics.beginActionInvoke(
            surface: "TrackContextMenu",
            detail: "action=deleteTracksAfterConfirmation, selected=\(tracks.count)"
        )
        Task {
            await libraryVM.deleteTracks(tracks)
            await MainActor.run {
                pageController.clearMultiselectState()
            }
            ContextMenuDiagnostics.end(token)
        }
    }

    @MainActor
    private func insertTracksAfterCurrent(_ tracks: [Track]) {
        if playbackCoordinator.insertTracksAfterCurrent(tracks) > 0 {
            uiState.showSidebarNotice("已加入下一首")
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

final class PlaylistTopChromeInsetReaderView: NSView {
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

struct PlaylistTopChromeInsetReader: NSViewRepresentable {
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
            appleMusicAdapter: AppleMusicPlaybackAdapter(previewLibraryVM: libraryVM),
            systemNowPlayingProvider: SystemNowPlayingProvider(previewLibraryVM: libraryVM)
        ))
        .environment(UIStateViewModel())
        .environmentObject(ThemeStore.shared)
        .frame(width: 500, height: 400)
        .task {
            await libraryVM.load()
        }
}
