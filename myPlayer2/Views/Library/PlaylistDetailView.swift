//
//  PlaylistDetailView.swift
//  myPlayer2
//
//  TrueMusic - Playlist Detail View
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
    @FocusState private var isSearchFocused: Bool

    // MARK: - Init

    init(
        @ViewBuilder headerAccessory: () -> HeaderAccessory = { EmptyView() }
    ) {
        self.headerAccessory = headerAccessory()
    }

    var body: some View {
        Group {
            if displayedTracks.isEmpty {
                emptyStateView
            } else if filteredTracks.isEmpty {
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
    }

    // MARK: - Computed Properties

    /// Tracks to display based on selected playlist.
    private var displayedTracks: [Track] {
        if let playlist = libraryVM.selectedPlaylist {
            // Show only tracks in this playlist
            return playlist.tracks.filter { $0.availability != .missing }
        } else {
            // Show all tracks
            return allTracks.filter { $0.availability != .missing }
        }
    }

    private var filteredTracks: [Track] {
        let term = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return displayedTracks }
        return displayedTracks.filter { $0.title.localizedCaseInsensitiveContains(term) }
    }

    private var sortedTracks: [Track] {
        libraryVM.sortedTracks(filteredTracks)
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sortedTrackIndexMap: [UUID: Int] {
        Dictionary(
            uniqueKeysWithValues: sortedTracks.enumerated().map { ($0.element.id, $0.offset) })
    }

    private var sortedTrackIDs: [UUID] {
        sortedTracks.map(\.id)
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(libraryVM.currentTitle)
                    .font(.headline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text(songCountText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: GlassStyleTokens.headerControlSpacing) {
                sortMenu

                // Skills: $macos-appkit-liquid-glass-toolbar + $macos-appkit-liquid-glass-controls
                // Group Play + Import into one pill while preserving separate hit targets.
                GlassToolbarPlayImportPill(
                    canPlay: !sortedTracks.isEmpty,
                    onPlay: {
                        guard !sortedTracks.isEmpty else { return }
                        playerVM.playTracks(sortedTracks)
                    },
                    onImport: {
                        print("🔘 Import button tapped")
                        Task {
                            await libraryVM.importToCurrentPlaylist()
                        }
                    }
                )

                GlassToolbarSearchField(
                    placeholder: "library.search_placeholder",
                    text: $searchText,
                    focused: $isSearchFocused
                ) {
                    searchText = ""
                }

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
                ForEach(sortedTracks, id: \.id) { track in
                    TrackRowView(
                        track: track,
                        isPlaying: playerVM.currentTrack?.id == track.id,
                        onTap: {
                            playerVM.playTracks(
                                sortedTracks,
                                startingAt: sortedTrackIndexMap[track.id] ?? 0
                            )
                        }
                    ) {
                        trackMenu(track: track, index: sortedTrackIndexMap[track.id] ?? 0)
                    }
                    .equatable()
                    .contextMenu {
                        trackMenu(track: track, index: sortedTrackIndexMap[track.id] ?? 0)
                    }

                }

                // Bottom placeholder for MiniPlayer/Controls
                Color.clear.frame(height: 160)
            }
            .scrollTargetLayout()
            .padding(.top, listTopPadding)
            .padding(.bottom, listBottomPadding)
            .padding(.horizontal)
        }
        .scrollPosition(id: $listScrollPositionID, anchor: .top)
        .onAppear {
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracks)
        }
        .onChange(of: listScrollPositionID) { _, _ in
            updateLibrarySnapshot()
        }
        .onChange(of: libraryVM.selectedPlaylist?.id) { _, _ in
            restoreScrollIfNeeded()
            updateLibrarySnapshot()
            playerVM.updateQueueTracks(sortedTracks)
        }
        .onChange(of: sortedTrackIDs) { _, _ in
            playerVM.updateQueueTracks(sortedTracks)
        }
        .onTapGesture { clearSearchFocus() }
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
                filteredTracks.count, displayedTracks.count)
        }
        let format =
            displayedTracks.count == 1
            ? NSLocalizedString("library.song_count_one", comment: "")
            : NSLocalizedString("library.song_count", comment: "")
        return String(format: format, displayedTracks.count)
    }

    @ViewBuilder
    private func trackMenu(track: Track, index: Int) -> some View {
        // Play
        Button {
            playerVM.playTracks(filteredTracks, startingAt: index)
        } label: {
            Label("context.play", systemImage: "play")
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
                Label("context.new_playlist", systemImage: "plus")
            }
        } label: {
            Label(
                "context.add_to_playlist",
                systemImage: "plus.circle")
        }

        // Remove from Playlist (if in one)
        if let currentPlaylist = libraryVM.selectedPlaylist {
            Button {
                Task {
                    await libraryVM.removeTracksFromPlaylist(
                        [track], playlist: currentPlaylist)
                }
            } label: {
                Label(
                    "context.remove_from_playlist",
                    systemImage: "minus.circle")
            }
        }

        Divider()

        // Edit Metadata
        Button {
            trackToEdit = track
        } label: {
            Label("context.get_info", systemImage: "info.circle")
        }

        Divider()

        // Delete from Library
        Button(role: .destructive) {
            Task {
                await libraryVM.deleteTrack(track)
            }
        } label: {
            Label(
                "context.delete_from_library", systemImage: "trash")
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
            sortedTracks.contains(where: { $0.id == restoreID })
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
        let firstID = sortedTracks.first?.id
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
