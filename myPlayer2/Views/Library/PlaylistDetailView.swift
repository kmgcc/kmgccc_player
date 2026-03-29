//
//  PlaylistDetailView.swift
//  myPlayer2
//
//  kmgccc_player - Playlist Detail View
//  Displays tracks in a playlist or all songs.
//
//  Import button is HERE (per-playlist), NOT in main toolbar.
//

import SwiftUI

/// View displaying tracks in the selected playlist or all songs.
struct PlaylistDetailView<HeaderAccessory: View>: View {

    private struct BatchEditRequest: Identifiable {
        let id = UUID()
        let tracks: [Track]
    }

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(\.colorScheme) private var colorScheme

    private let headerAccessory: HeaderAccessory

    // MARK: - State

    @State private var trackToEdit: Track?
    @State private var searchText: String = ""
    @State private var listScrollPositionID: UUID?
    @State private var displayedTracksCache: [Track] = []
    @State private var filteredTracksCache: [Track] = []
    @State private var sortedTracksCache: [Track] = []
    @State private var parentSortedTracksCache: [Track] = []
    @State private var viewSnapshot: PlaylistViewSnapshot = .empty
    @State private var sortedTrackIndexMapCache: [UUID: Int] = [:]
    @State private var parentSortedTrackIndexMapCache: [UUID: Int] = [:]
    @State private var trackByIDCache: [UUID: Track] = [:]
    @State private var prefetchTask: Task<Void, Never>?
    @State private var rebuildTask: Task<Void, Never>?
    @State private var snapshotUpdateTask: Task<Void, Never>?
    @State private var activeRebuildToken = UUID()
    @State private var isRebuilding = false
    @State private var lastQueueTrackIDs: [UUID] = []
    @State private var lastPrefetchBucket: Int?
    @FocusState private var isSearchFocused: Bool
    @State private var isMultiselectMode = false
    @State private var selectedTrackIDs: Set<UUID> = []
    @State private var sortSymbolEffectTrigger = 0
    @State private var batchEditRequest: BatchEditRequest?

    // MARK: - Init

    init(
        @ViewBuilder headerAccessory: () -> HeaderAccessory = { EmptyView() }
    ) {
        self.headerAccessory = headerAccessory()
    }

    var body: some View {
        Group {
            if libraryVM.state == .loading
                || (isRebuilding && displayedTracksCache.isEmpty && viewSnapshot.isEmpty)
            {
                ProgressView()
                    .controlSize(.large)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayedTracksCache.isEmpty {
                emptyStateView
            } else if filteredTracksCache.isEmpty {
                noResultsView
            } else {
                trackListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .top) {
            headerView
                .ignoresSafeArea(.container, edges: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 400)
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
            scheduleRebuild(reason: "appear", restoreScroll: true)
        }
        .onDisappear {
            prefetchTask?.cancel()
            prefetchTask = nil
            rebuildTask?.cancel()
            rebuildTask = nil
            snapshotUpdateTask?.cancel()
            snapshotUpdateTask = nil
            Task {
                await LibraryTrackSnapshotBuilder.shared.cancelBuild()
            }
        }
        .onChange(of: libraryVM.selectedPlaylist?.id) { _, _ in
            scheduleRebuild(reason: "playlist", restoreScroll: true)
        }
        .onChange(of: libraryVM.selectedArtistKey) { _, _ in
            scheduleRebuild(reason: "artist", restoreScroll: true)
        }
        .onChange(of: libraryVM.selectedAlbumKey) { _, _ in
            scheduleRebuild(reason: "album", restoreScroll: true)
        }
        .onChange(of: searchText) { _, _ in
            scheduleRebuild(reason: "search", debounceNanoseconds: 150_000_000)
        }
        .onChange(of: libraryVM.trackSortKey) { _, _ in
            sortSymbolEffectTrigger += 1
            scheduleRebuild(reason: "sortKey")
        }
        .onChange(of: libraryVM.trackSortOrder) { _, _ in
            sortSymbolEffectTrigger += 1
            scheduleRebuild(reason: "sortOrder")
        }
        .onChange(of: libraryVM.totalTrackCount) { _, _ in
            scheduleRebuild(reason: "trackCount", restoreScroll: true)
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            scheduleRebuild(reason: "refresh", restoreScroll: true)
        }
        .onChange(of: libraryVM.searchResetTrigger) { _, _ in
            searchText = ""
            isSearchFocused = false
        }
    }

    // MARK: - Computed Properties

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                if isMultiselectMode {
                    Text("已选择")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Text("\(selectedTrackIDs.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Button {
                            if selectedTrackIDs.count == sortedTracksCache.count {
                                selectedTrackIDs.removeAll()
                            } else {
                                selectedTrackIDs = Set(sortedTracksCache.map(\.id))
                            }
                        } label: {
                            Text(
                                totalSelectionCount == sortedTracksCache.count
                                    ? "取消全选" : "全选"
                            )
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text(libraryVM.currentTitle)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .lineLimit(1)

                    Text(songCountText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 12) {
                sortMenu

                // Skills: $macos-appkit-liquid-glass-toolbar + $macos-appkit-liquid-glass-controls
                // Group Multiselect + Play + Import into one pill
                GlassToolbarTriplePill(
                    isMultiselectActive: isMultiselectMode,
                    onToggleMultiselect: {
                        isMultiselectMode.toggle()
                        if !isMultiselectMode {
                            selectedTrackIDs.removeAll()
                        }
                    },
                    canPlay: !sortedTracksCache.isEmpty,
                    onPlay: {
                        if isMultiselectMode && !selectedTrackIDs.isEmpty {
                            // Play selected
                            let selected = sortedTracksCache.filter {
                                selectedTrackIDs.contains($0.id)
                            }
                            playerVM.playTracks(selected)
                        } else {
                            guard !sortedTracksCache.isEmpty else { return }
                            playerVM.playTracks(sortedTracksCache)
                        }
                    },
                    onImport: {
                        print("🔘 Import button tapped")
                        Task {
                            await libraryVM.importToCurrentPlaylist()
                        }
                    }
                )

                GlassToolbarSearchField(
                    placeholder: "搜索",
                    text: $searchText,
                    focused: $isSearchFocused
                ) {
                    searchText = ""
                }
                .frame(width: 140)

                headerAccessory
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .cornerAvoidingHorizontalPadding(GlassStyleTokens.headerHorizontalPadding)
        .frame(height: GlassStyleTokens.headerBarHeight)
        .background(alignment: .top) {
            headerBackground
        }
    }

    private var sortMenu: some View {
        GlassToolbarMenuButton(
            systemImage: "arrow.up.arrow.down",
            help: "sort.help",
            style: .standard
        ) {
            Section("sort.by") {
                ForEach(TrackSortKey.allCases) { key in
                    Button {
                        libraryVM.trackSortKey = key
                    } label: {
                        if libraryVM.trackSortKey == key {
                            Label(key.title, systemImage: "checkmark")
                        } else {
                            Text(key.title)
                        }
                    }
                }
            }

            Section("sort.order") {
                ForEach(TrackSortOrder.allCases) { order in
                    Button {
                        libraryVM.trackSortOrder = order
                    } label: {
                        if libraryVM.trackSortOrder == order {
                            Label(order.title, systemImage: "checkmark")
                        } else {
                            Text(order.title)
                        }
                    }
                }
            }
        }
        .symbolEffect(.bounce, value: sortSymbolEffectTrigger)
        .simultaneousGesture(
            TapGesture().onEnded {
                sortSymbolEffectTrigger += 1
            }
        )
    }

    private var trackListView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(viewSnapshot.trackIDs, id: \.self) { trackID in
                    if
                        let rowSnapshot = viewSnapshot.snapshot(for: trackID),
                        let track = trackByIDCache[trackID]
                    {
                        TrackRowView(
                            model: trackRowModel(for: rowSnapshot),
                            isPlaying: playerVM.currentTrack?.id == trackID,
                            isSelected: isMultiselectMode && selectedTrackIDs.contains(trackID),
                            onTap: {
                                if isMultiselectMode {
                                    if selectedTrackIDs.contains(trackID) {
                                        selectedTrackIDs.remove(trackID)
                                    } else {
                                        selectedTrackIDs.insert(trackID)
                                    }
                                } else {
                                    let startIndex =
                                        parentSortedTrackIndexMapCache[trackID] ?? 0
                                    playerVM.playTracks(
                                        parentSortedTracksCache,
                                        startingAt: startIndex
                                    )
                                }
                            },
                            onRowAppear: {
                                prefetchAroundTrackID(trackID)
                            }
                        ) {
                            trackMenu(track: track)
                        }
                        .contextMenu {
                            trackMenu(track: track)
                        }
                    }
                }

                // Bottom placeholder for MiniPlayer/Controls
                Color.clear.frame(height: 160)
            }
            .scrollTargetLayout()
            .padding(.top, listTopPadding)
            .padding(.bottom, listBottomPadding)
            .padding(.horizontal)
            .transaction { tx in
                tx.animation = nil
            }
        }
        .scrollPosition(id: $listScrollPositionID, anchor: .top)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .onChange(of: listScrollPositionID) { _, _ in
            scheduleSnapshotUpdate()
        }
        .onTapGesture {
            clearSearchFocus()
            // Verify if we should clear selection on background tap?
            // User didn't specify, but usually background tap doesn't clear multiselect mode itself,
            // maybe just selection? For now, keep it simple.
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

            // Import button in empty state
            Button {
                print("🔘 Import button (empty state) tapped")
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
        .onTapGesture { clearSearchFocus() }
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

            Text(String(format: NSLocalizedString("library.no_matches", comment: ""), searchText))
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onTapGesture { clearSearchFocus() }
    }

    private var songCountText: String {
        if isFiltering {
            return String(
                format: NSLocalizedString("library.song_count_filtered", comment: ""),
                filteredTracksCache.count, displayedTracksCache.count)
        }
        let format =
            displayedTracksCache.count == 1
            ? NSLocalizedString("library.song_count_one", comment: "")
            : NSLocalizedString("library.song_count", comment: "")
        return String(format: format, displayedTracksCache.count)
    }

    private var totalSelectionCount: Int {
        selectedTrackIDs.count
    }

    @ViewBuilder
    private func trackMenu(track: Track) -> some View {
        if isMultiselectMode && selectedTrackIDs.contains(track.id) {
            // Batch Actions
            Text("已选择 \(selectedTrackIDs.count) 首歌曲")
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
                    for track in tracks {
                        await libraryVM.deleteTrack(track)
                    }
                    // Clear selection after delete
                    await MainActor.run {
                        // Selection will be cleared by cache rebuild or logic
                        selectedTrackIDs.removeAll()
                    }
                }
            } label: {
                Label("从资料库删除", systemImage: "trash")
            }

        } else {
            // SINGLE TRACK ACTIONS (Keep existing)

            // Enter multiselect mode
            Button {
                isMultiselectMode = true
                selectedTrackIDs.insert(track.id)
            } label: {
                Label("多选歌曲…", systemImage: "checkmark.circle")
            }

            Divider()

            // Play
            Button {
                let startIndex = parentSortedTrackIndexMapCache[track.id] ?? 0
                playerVM.playTracks(parentSortedTracksCache, startingAt: startIndex)
            } label: {
                Label("播放", systemImage: "play")
            }

            Divider()

            // Add to Playlist
            Menu {
                ForEach(libraryVM.playlists) { playlist in
                    // Don't show current playlist if we are in it
                    if libraryVM.selectedPlaylist?.id != playlist.id {
                        Button {
                            Task {
                                await libraryVM.addTracksToPlaylist(
                                    [track], playlist: playlist)
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

            // Remove from Playlist (if in one)
            if let currentPlaylist = libraryVM.selectedPlaylist {
                Button {
                    Task {
                        await libraryVM.removeTracksFromPlaylist(
                            [track], playlist: currentPlaylist)
                    }
                } label: {
                    Label("从当前播放列表移除", systemImage: "minus.circle")
                }
            }

            Divider()

            // Edit Metadata
            Button {
                trackToEdit = track
            } label: {
                Label("编辑歌曲信息", systemImage: "info.circle")
            }

            Divider()

            // Delete from Library
            Button(role: .destructive) {
                Task {
                    await libraryVM.deleteTrack(track)
                }
            } label: {
                Label("从资料库删除", systemImage: "trash")
            }
        }
    }

    private func processBatchAction(action: @escaping ([Track]) async -> Void) {
        let selectedTracks = sortedTracksCache.filter { selectedTrackIDs.contains($0.id) }
        Task {
            await action(selectedTracks)
            await MainActor.run {
                isMultiselectMode = false
                selectedTrackIDs.removeAll()
            }
        }
    }

    private func selectedTracksForBatchEditor() -> [Track] {
        sortedTracksCache.filter { selectedTrackIDs.contains($0.id) }
    }

    private func openBatchEditor() {
        let selectedTracks = selectedTracksForBatchEditor()
        guard !selectedTracks.isEmpty else { return }
        uiState.lyricsPanelSuppressedByModal = true
        batchEditRequest = BatchEditRequest(
            tracks: selectedTracks
        )
    }

    private func clearMultiselectState() {
        uiState.lyricsPanelSuppressedByModal = false
        isMultiselectMode = false
        selectedTrackIDs.removeAll()
    }

    private var listTopPadding: CGFloat { GlassStyleTokens.headerBarHeight + 16 }

    private var listBottomPadding: CGFloat { 16 }

    private var headerBackground: some View {
        // Progressive Blur (Variable Blur)
        // Strictly confined and made significantly smaller as requested.
        ZStack(alignment: .top) {
            Rectangle()
                .fill(.regularMaterial)
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),  // Full blur at top
                            .init(color: .clear, location: 0.8),  // Fade out earlier (80% of bar)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            // Subtle theme-tinted scrim: even tighter fade
            Rectangle()
                .fill(
                    Color(nsColor: .windowBackgroundColor).opacity(
                        colorScheme == .dark ? 0.2 : 0.05)
                )
                .mask {
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .clear, location: 0.6),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }
        }
        .frame(height: GlassStyleTokens.headerBarHeight)
        .allowsHitTesting(false)
    }

    private func clearSearchFocus() {
        if isSearchFocused {
            isSearchFocused = false
        }
    }

    private func restoreScrollIfNeeded() {
        let playlistID = libraryVM.selectedPlaylist?.id
        let restoreID = uiState.consumeLibraryRestoreTarget(for: playlistID)

        guard
            let restoreID,
            sortedTracksCache.contains(where: { $0.id == restoreID })
        else {
            // No restore target (or missing in current dataset): keep default initial position.
            listScrollPositionID = nil
            return
        }

        // Defer one runloop to ensure scroll container has mounted.
        Task { @MainActor in
            listScrollPositionID = restoreID
        }
    }

    private func updateLibrarySnapshot() {
        let firstID = sortedTracksCache.first?.id
        let userScrolled = {
            guard let position = listScrollPositionID, let firstID else { return false }
            return position != firstID
        }()

        uiState.rememberLibraryContext(
            playlistID: libraryVM.selectedPlaylist?.id,
            scrollTrackID: listScrollPositionID,
            userScrolled: userScrolled
        )
    }

    private func scheduleSnapshotUpdate() {
        snapshotUpdateTask?.cancel()
        snapshotUpdateTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            updateLibrarySnapshot()
        }
    }

    private func scheduleRebuild(
        reason: String,
        debounceNanoseconds: UInt64 = 0,
        restoreScroll: Bool = false
    ) {
        rebuildTask?.cancel()
        let token = UUID()
        activeRebuildToken = token
        rebuildTask = Task { @MainActor in
            if debounceNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: debounceNanoseconds)
            }
            guard !Task.isCancelled else { return }
            isRebuilding = true
            await performRebuild(
                reason: reason,
                restoreScroll: restoreScroll,
                token: token
            )
        }
    }

    private func performRebuild(
        reason: String,
        restoreScroll: Bool,
        token: UUID
    ) async {
        let rebuildStart = ProcessInfo.processInfo.systemUptime
        let displayedTracks = currentDisplayedTracks()
        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredTracks: [Track] = {
            guard !trimmedSearch.isEmpty else { return displayedTracks }
            return displayedTracks.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }()

        let sortedTracks = libraryVM.sortedTracks(filteredTracks)
        let parentSortedTracks = libraryVM.sortedTracks(displayedTracks)
        let rowScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rowPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * rowScale,
            height: Constants.Layout.artworkSmallSize * rowScale
        )
        let inputs = sortedTracks.map {
            TrackRowBuildInput(
                trackID: $0.id,
                title: $0.title,
                artist: $0.artist,
                album: $0.album,
                duration: $0.duration,
                artworkData: $0.artworkData,
                isMissing: $0.availability == .missing
            )
        }
        let snapshot = await LibraryTrackSnapshotBuilder.shared.buildSnapshot(
            playlistID: libraryVM.selectedPlaylist?.id ?? UUID(),
            tracks: inputs,
            targetPixelSize: rowPixels
        )

        guard !Task.isCancelled, activeRebuildToken == token else {
            if activeRebuildToken == token {
                isRebuilding = false
            }
            return
        }

        prefetchTask?.cancel()
        prefetchTask = nil
        lastPrefetchBucket = nil
        displayedTracksCache = displayedTracks
        filteredTracksCache = filteredTracks
        sortedTracksCache = sortedTracks
        parentSortedTracksCache = parentSortedTracks
        sortedTrackIndexMapCache = Dictionary(
            uniqueKeysWithValues: snapshot.trackIDs.enumerated().map { ($0.element, $0.offset) })
        parentSortedTrackIndexMapCache = Dictionary(
            uniqueKeysWithValues: parentSortedTracks.enumerated().map { ($0.element.id, $0.offset) }
        )
        trackByIDCache = Dictionary(uniqueKeysWithValues: sortedTracks.map { ($0.id, $0) })
        viewSnapshot = snapshot
        selectedTrackIDs.formIntersection(Set(sortedTracks.map(\.id)))
        if restoreScroll {
            restoreScrollIfNeeded()
        }
        updateLibrarySnapshot()
        syncPlayerQueueIfNeeded(with: parentSortedTracks)
        isRebuilding = false
        let rebuildDurationMs = (ProcessInfo.processInfo.systemUptime - rebuildStart) * 1000
        PlaylistPerfDiagnostics.markListRebuild(
            reason: reason,
            trackCount: snapshot.trackCount,
            durationMs: rebuildDurationMs
        )
    }

    private func currentDisplayedTracks() -> [Track] {
        if let playlist = libraryVM.selectedPlaylist {
            return playlist.tracks.filter { $0.availability != .missing }
        } else if let artistKey = libraryVM.selectedArtistKey {
            return libraryVM.allTracks.filter {
                LibraryNormalization.normalizeArtist($0.artist) == artistKey
                    && $0.availability != .missing
            }
        } else if let albumKey = libraryVM.selectedAlbumKey {
            return libraryVM.allTracks.filter {
                LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
                    == albumKey && $0.availability != .missing
            }
        }
        return libraryVM.allTracks.filter { $0.availability != .missing }
    }

    private func syncPlayerQueueIfNeeded(with tracks: [Track]) {
        let trackIDs = tracks.map(\.id)
        guard trackIDs != lastQueueTrackIDs else { return }
        lastQueueTrackIDs = trackIDs
        playerVM.updateQueueTracks(tracks)
    }

    private func trackRowModel(for snapshot: TrackRowSnapshot) -> TrackRowModel {
        TrackRowModel(
            id: snapshot.trackID,
            title: snapshot.title,
            artist: snapshot.artist,
            durationText: snapshot.durationText,
            artworkData: snapshot.artworkData,
            artworkCacheKey: snapshot.artworkCacheKey,
            isMissing: snapshot.isMissing
        )
    }

    private func prefetchAroundTrackID(_ trackID: UUID) {
        guard let startIndex = sortedTrackIndexMapCache[trackID] else { return }
        let bucket = startIndex / 3
        guard bucket != lastPrefetchBucket else { return }
        lastPrefetchBucket = bucket
        let rowScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rowPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * rowScale,
            height: Constants.Layout.artworkSmallSize * rowScale
        )
        let start = min(startIndex + 1, viewSnapshot.trackIDs.count)
        let end = min(viewSnapshot.trackIDs.count, startIndex + 9)
        guard start < end else { return }

        let requests: [ArtworkPrefetchRequest] = Array(viewSnapshot.trackIDs[start..<end]).compactMap {
            trackID in
            guard let snapshot = viewSnapshot.snapshot(for: trackID) else { return nil }
            return ArtworkPrefetchRequest(
                cacheKey: snapshot.artworkCacheKey,
                artworkData: snapshot.artworkData,
                targetPixelSize: rowPixels
            )
        }
        prefetchTask?.cancel()
        prefetchTask = ArtworkLoader.prefetch(Array(requests))
    }

    private func formatDuration(_ duration: Double) -> String {
        guard duration.isFinite, duration > 0 else { return "0:00" }
        let totalSeconds = Int(duration.rounded(.down))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Preview

#Preview("Playlist Detail") { @MainActor in
    let repository = StubLibraryRepository()
    let libraryVM = LibraryViewModel(repository: repository)
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)

    PlaylistDetailView()
        .environment(libraryVM)
        .environment(playerVM)
        .environmentObject(ThemeStore.shared)
        .frame(width: 500, height: 400)
        .task {
            await libraryVM.load()
        }
}
