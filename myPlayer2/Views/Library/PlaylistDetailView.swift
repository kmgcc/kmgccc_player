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
struct PlaylistDetailView: View {

    @Environment(LibraryViewModel.self) private var libraryVM
    @Environment(PlayerViewModel.self) private var playerVM
    @Environment(\.modelContext) private var modelContext

    /// Query all tracks (sorted by addedAt, newest first).
    /// This automatically updates when SwiftData changes.
    @Query(sort: \Track.addedAt, order: .reverse) private var allTracks: [Track]

    // MARK: - State

    @State private var trackToEdit: Track?
    @State private var showingTrackEditSheet = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerView

            Divider()

            // Track list
            if displayedTracks.isEmpty {
                emptyStateView
            } else {
                trackListView
            }
        }
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
            return playlist.tracks
        } else {
            // Show all tracks
            return allTracks
        }
    }

    // MARK: - Subviews

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(libraryVM.currentTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text("\(displayedTracks.count) songs")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Import button (per-playlist import)
            Button {
                print("🔘 Import button tapped")
                Task {
                    await libraryVM.importToCurrentPlaylist()
                }
            } label: {
                Label("Import", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .help("Import music to this playlist")

            // Play all button
            if !displayedTracks.isEmpty {
                Button {
                    playerVM.playTracks(displayedTracks)
                } label: {
                    Label("Play All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding()
    }

    private var trackListView: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(displayedTracks.enumerated()), id: \.element.id) { index, track in
                    TrackRowView(
                        track: track,
                        isPlaying: playerVM.currentTrack?.id == track.id,
                        onTap: {
                            playerVM.playTracks(displayedTracks, startingAt: index)
                        }
                    )
                    .contextMenu {
                        // Play
                        Button {
                            playerVM.playTracks(displayedTracks, startingAt: index)
                        } label: {
                            Label("Play", systemImage: "play")
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
                                Label("New Playlist", systemImage: "plus")
                            }
                        } label: {
                            Label("Add to Playlist", systemImage: "plus.circle")
                        }

                        // Remove from Playlist (if in one)
                        if let currentPlaylist = libraryVM.selectedPlaylist {
                            Button {
                                Task {
                                    await libraryVM.removeTracksFromPlaylist(
                                        [track], playlist: currentPlaylist)
                                }
                            } label: {
                                Label("Remove from Playlist", systemImage: "minus.circle")
                            }
                        }

                        Divider()

                        // Edit Metadata
                        Button {
                            trackToEdit = track
                        } label: {
                            Label("Get Info", systemImage: "info.circle")
                        }

                        Divider()

                        // Delete from Library
                        Button(role: .destructive) {
                            Task {
                                await libraryVM.deleteTrack(track)
                            }
                        } label: {
                            Label("Delete from Library", systemImage: "trash")
                        }
                    }

                    if index < displayedTracks.count - 1 {
                        Divider()
                            .padding(.leading, Constants.Layout.artworkSmallSize + 20)
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "music.note.list")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Songs")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Click \"Import\" to add music to this playlist")
                .font(.subheadline)
                .foregroundStyle(.tertiary)

            // Import button in empty state
            Button {
                print("🔘 Import button (empty state) tapped")
                Task {
                    await libraryVM.importToCurrentPlaylist()
                }
            } label: {
                Label("Import Music", systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .modelContainer(container)
        .frame(width: 500, height: 400)
        .task {
            await libraryVM.load()
        }
}
