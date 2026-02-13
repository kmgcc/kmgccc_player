//
//  PlaylistDetailView.swift
//  myPlayer2
//
//  kmgccc_player - Playlist Detail View
//  Displays tracks in a playlist or all songs.
//
//  Uses @Query for automatic SwiftData refresh (方案 A).
//  Import button is HERE (per-playlist), NOT in main toolbar.
//

import SwiftData
import SwiftUI

/// View displaying tracks in the selected playlist or all songs.
/// Uses @Query for automatic data refresh when tracks are added.
struct PlaylistDetailView<HeaderAccessory: View>: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(UIStateViewModel.self) private var uiState
    @Environment(\.colorScheme) private var colorScheme

    private let headerAccessory: HeaderAccessory

    /// Query all tracks (sorted by addedAt, newest first).
    /// This automatically updates when SwiftData changes.
    @Query(sort: \Track.addedAt, order: .reverse) private var allTracks: [Track]

    // MARK: - State

    @State private var trackToEdit: Track?
    @State private var searchText: String = ""
    @State private var listScrollPositionID: UUID?
    @State private var displayedTracksCache: [Track] = []
    @State private var filteredTracksCache: [Track] = []
    @State private var sortedTracksCache: [Track] = []
    @State private var rowModelsCache: [TrackRowModel] = []
    @State private var sortedTrackIndexMapCache: [UUID: Int] = [:]
    @State private var trackByIDCache: [UUID: Track] = [:]
    @State private var prefetchTask: Task<Void, Never>?
    @State private var snapshotUpdateTask: Task<Void, Never>?
    @FocusState private var isSearchFocused: Bool
    @State private var isMultiselectMode = false
    @State private var selectedTrackIDs: Set<UUID> = []

    // MARK: - Init

    init(
        @ViewBuilder headerAccessory: () -> HeaderAccessory = { EmptyView() }
    ) {
        self.headerAccessory = headerAccessory()
    }

    var body: some View {
        Group {
            if displayedTracksCache.isEmpty {
                emptyStateView
            } else if filteredTracksCache.isEmpty {
                noResultsView
            } else {
                trackListView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaInset(edge: .top, spacing: 0) {
            headerView
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 400)
        .sheet(item: $trackToEdit) { track in
            TrackEditSheet(track: track)
        }
        .onAppear {
            rebuildTrackCaches(reason: "appear")
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onDisappear {
            prefetchTask?.cancel()
            prefetchTask = nil
            snapshotUpdateTask?.cancel()
            snapshotUpdateTask = nil
        }
        .onChange(of: libraryVM.selectedPlaylist?.id) { _, _ in
            rebuildTrackCaches(reason: "playlist")
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onChange(of: libraryVM.selectedArtist) { _, _ in
            rebuildTrackCaches(reason: "artist")
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onChange(of: libraryVM.selectedAlbum) { _, _ in
            rebuildTrackCaches(reason: "album")
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onChange(of: searchText) { _, _ in
            rebuildTrackCaches(reason: "search")
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onChange(of: libraryVM.trackSortKey) { _, _ in
            rebuildTrackCaches(reason: "sortKey")
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onChange(of: libraryVM.trackSortOrder) { _, _ in
            rebuildTrackCaches(reason: "sortOrder")
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onChange(of: allTracks.count) { _, _ in
            rebuildTrackCaches(reason: "trackCount")
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
        }
        .onChange(of: libraryVM.refreshTrigger) { _, _ in
            rebuildTrackCaches(reason: "refresh")
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracksCache)
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
        .background(headerBackground)
        .clipped()
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
    }

    private var trackListView: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(rowModelsCache, id: \.id) { rowModel in
                    if let track = trackByIDCache[rowModel.id] {
                        let rowIndex = sortedTrackIndexMapCache[rowModel.id] ?? 0
                        TrackRowView(
                            model: rowModel,
                            isPlaying: playerVM.currentTrack?.id == rowModel.id,
                            isSelected: isMultiselectMode && selectedTrackIDs.contains(rowModel.id),
                            onTap: {
                                if isMultiselectMode {
                                    if selectedTrackIDs.contains(rowModel.id) {
                                        selectedTrackIDs.remove(rowModel.id)
                                    } else {
                                        selectedTrackIDs.insert(rowModel.id)
                                    }
                                } else {
                                    playerVM.playTracks(
                                        sortedTracksCache,
                                        startingAt: rowIndex
                                    )
                                }
                            },
                            onRowAppear: {
                                prefetchAroundTrackID(rowModel.id)
                            }
                        ) {
                            trackMenu(track: track, index: rowIndex)
                        }
                        .equatable()
                        .contextMenu {
                            trackMenu(track: track, index: rowIndex)
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
    private func trackMenu(track: Track, index: Int) -> some View {
        if isMultiselectMode && selectedTrackIDs.contains(track.id) {
            // Batch Actions
            Text("已选择 \(selectedTrackIDs.count) 首歌曲")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)

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
            // Play
            Button {
                playerVM.playTracks(sortedTracksCache, startingAt: index)
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
                Label("显示简介", systemImage: "info.circle")
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

    private var listTopPadding: CGFloat { 12 }

    private var listBottomPadding: CGFloat { 16 }

    private var headerBackground: some View {
        // Avoid glass-on-glass: toolbar controls already use `.glassEffect`.
        // The header background should be a simple scrim to separate content.
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor)
                    .opacity(colorScheme == .dark ? 0.55 : 0.78),
                Color(nsColor: .windowBackgroundColor).opacity(0.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
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

    private func rebuildTrackCaches(reason: String) {
        let rebuildStart = ProcessInfo.processInfo.systemUptime

        let displayedTracks: [Track] = {
            if let playlist = libraryVM.selectedPlaylist {
                return playlist.tracks.filter { $0.availability != .missing }
            } else if let artist = libraryVM.selectedArtist {
                return allTracks.filter { $0.artist == artist && $0.availability != .missing }
            } else if let album = libraryVM.selectedAlbum {
                return allTracks.filter { $0.album == album && $0.availability != .missing }
            }
            return allTracks.filter { $0.availability != .missing }
        }()

        let trimmedSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredTracks: [Track] = {
            guard !trimmedSearch.isEmpty else { return displayedTracks }
            return displayedTracks.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedSearch)
            }
        }()

        let sortedTracks = libraryVM.sortedTracks(filteredTracks)
        let rowScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rowPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * rowScale,
            height: Constants.Layout.artworkSmallSize * rowScale
        )

        displayedTracksCache = displayedTracks
        filteredTracksCache = filteredTracks
        sortedTracksCache = sortedTracks
        sortedTrackIndexMapCache = Dictionary(
            uniqueKeysWithValues: sortedTracks.enumerated().map { ($0.element.id, $0.offset) })
        trackByIDCache = Dictionary(uniqueKeysWithValues: sortedTracks.map { ($0.id, $0) })
        rowModelsCache = sortedTracks.map { track in
            let checksum = ArtworkLoader.checksum(for: track.artworkData)
            let cacheKey = ArtworkLoader.cacheKey(
                trackID: track.id,
                checksum: checksum,
                targetPixelSize: rowPixels
            )
            return TrackRowModel(
                id: track.id,
                title: track.title,
                artist: track.artist,
                durationText: formatDuration(track.duration),
                artworkData: track.artworkData,
                artworkCacheKey: cacheKey,
                isMissing: track.availability == .missing
            )
        }
        let rebuildDurationMs = (ProcessInfo.processInfo.systemUptime - rebuildStart) * 1000
        PlaylistPerfDiagnostics.markListRebuild(
            reason: reason,
            trackCount: rowModelsCache.count,
            durationMs: rebuildDurationMs
        )
    }

    private func prefetchAroundTrackID(_ trackID: UUID) {
        guard let startIndex = sortedTrackIndexMapCache[trackID] else { return }
        guard startIndex % 3 == 0 else { return }
        let rowScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let rowPixels = CGSize(
            width: Constants.Layout.artworkSmallSize * rowScale,
            height: Constants.Layout.artworkSmallSize * rowScale
        )
        let start = min(startIndex + 1, rowModelsCache.count)
        let end = min(rowModelsCache.count, startIndex + 9)
        guard start < end else { return }

        let requests = rowModelsCache[start..<end].map { model in
            ArtworkPrefetchRequest(
                cacheKey: model.artworkCacheKey,
                artworkData: model.artworkData,
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

#Preview("Playlist Detail") {
    let container = try! ModelContainer(
        for: Track.self, Playlist.self, configurations: .init(isStoredInMemoryOnly: true))
    let repository = SwiftDataLibraryRepository(modelContext: container.mainContext)
    let libraryVM = LibraryViewModel(repository: repository)
    let playbackService = StubAudioPlaybackService()
    let levelMeter = StubAudioLevelMeter()
    let playerVM = PlayerViewModel(playbackService: playbackService, levelMeter: levelMeter)

    PlaylistDetailView()
        .environment(libraryVM)
        .environment(playerVM)
        .environmentObject(ThemeStore.shared)
        .modelContainer(container)
        .frame(width: 500, height: 400)
        .task {
            await libraryVM.load()
        }
}
