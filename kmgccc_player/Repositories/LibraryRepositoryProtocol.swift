//
//  LibraryRepositoryProtocol.swift
//  myPlayer2
//
//  kmgccc_player - Library Repository Protocol
//  Defines CRUD operations for tracks and playlists.
//

import Foundation

enum LibraryRepositoryChange: Sendable {
    case trackUpdated(UUID)
    case tracksUpdated([UUID])
    case tracksDeleted([UUID])
}

typealias LibraryRepositoryChangeHandler = @MainActor @Sendable (LibraryRepositoryChange) -> Void

struct LibraryTrackPersistenceResult: Sendable {
    let persistedTrackIDs: [UUID]
    let failedTrackIDs: [UUID]
}

/// Protocol for library data access (tracks and playlists).
/// Implemented by SwiftDataLibraryRepository for persistence.
@MainActor
protocol LibraryRepositoryProtocol: AnyObject {
    func setChangeHandler(_ handler: LibraryRepositoryChangeHandler?)

    /// Reload repository state from authoritative Music Library on disk.
    func reloadFromLibrary() async

    // MARK: - Track Operations

    /// Fetch all tracks, optionally filtered by playlist.
    /// - Parameter playlist: If nil, returns all tracks. Otherwise, returns tracks in the playlist.
    func fetchTracks(in playlist: Playlist?) async -> [Track]

    /// Fetch only specific tracks from the in-memory repository cache.
    func fetchTracks(ids: [UUID]) async -> [Track]

    /// Add a newly imported track to the library and persist its full resource sidecar.
    /// Ordinary metadata/artwork/lyrics updates must use the explicit persistence APIs below.
    func addTrack(_ track: Track) async

    /// Add newly imported tracks to the library and persist their full resource sidecars.
    /// Ordinary metadata/artwork/lyrics updates must use the explicit persistence APIs below.
    func addTracks(_ tracks: [Track]) async

    /// Add a playlist (used for bootstrap from disk).
    func addPlaylist(_ playlist: Playlist) async

    /// Delete a track from the library.
    func deleteTrack(_ track: Track) async

    /// Delete multiple tracks from the library in one pass.
    func deleteTracks(_ tracks: [Track]) async

    /// Persist track sidecar metadata only, preserving existing artwork/lyrics file references.
    func persistTrackMetaOnly(_ track: Track, reason: String) async

    /// Persist track sidecar metadata only for multiple tracks, preserving existing asset references.
    func persistTrackMetaOnly(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult

    /// Persist track metadata plus lyric assets.
    func persistTrackMetaAndLyrics(_ track: Track, reason: String) async

    /// Persist track metadata plus lyric assets for multiple tracks.
    func persistTrackMetaAndLyrics(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult

    /// Persist track metadata plus artwork asset.
    func persistTrackMetaAndArtwork(_ track: Track, reason: String) async

    /// Persist track metadata plus artwork asset for multiple tracks.
    func persistTrackMetaAndArtwork(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult

    /// Persist track metadata plus both lyric and artwork assets.
    func persistTrackMetaLyricsAndArtwork(_ track: Track, reason: String) async

    /// Persist track metadata plus both lyric and artwork assets for multiple tracks.
    func persistTrackMetaLyricsAndArtwork(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult

    /// Reload just the specified tracks from the on-disk library sidecars into repository caches.
    func refreshTracks(ids: [UUID]) async -> [Track]

    /// Check if a track with the given file path already exists.
    func trackExists(filePath: String) async -> Bool

    /// Check if a track with the same title and artist already exists.
    func trackExists(title: String, artist: String) async -> Bool

    /// Number of tracks matching normalized title+artist dedup key.
    func dedupMatchCount(title: String, artist: String) async -> Int

    // MARK: - Playlist Operations

    /// Fetch all playlists.
    func fetchPlaylists() async -> [Playlist]

    /// Create a new playlist.
    func createPlaylist(name: String) async -> Playlist

    /// Rename a playlist.
    func renamePlaylist(_ playlist: Playlist, name: String) async

    /// Persist playlist header metadata in one write path.
    func updatePlaylistDetails(_ playlist: Playlist, name: String, description: String) async

    /// Delete a playlist.
    func deletePlaylist(_ playlist: Playlist) async

    /// Add tracks to a playlist.
    func addTracks(_ tracks: [Track], to playlist: Playlist) async

    /// Remove tracks from a playlist.
    func removeTracks(_ tracks: [Track], from playlist: Playlist) async

    // MARK: - Statistics

    /// Get total track count in library.
    func totalTrackCount() async -> Int

    // MARK: - Metadata Listing

    /// Fetch all unique artist names.
    func fetchUniqueArtists() async -> [String]

    /// Fetch all unique album names.
    func fetchUniqueAlbums() async -> [String]

    /// Runtime-only artist sections (derived on each load).
    func fetchArtistSections() async -> [ArtistSection]

    /// Runtime-only album sections (derived on each load).
    func fetchAlbumSections() async -> [AlbumSection]

    /// Per-playlist track added-at map: [playlistID: [trackID: addedAt]].
    func fetchPlaylistItemAddedAtMap() async -> [UUID: [UUID: Date]]

    /// Clear index cache and rebuild runtime/index state from Music Library.
    func clearIndexCacheAndRebuild() async

    // MARK: - Persistence

    /// Save any pending changes to the persistent store without writing sidecars to disk.
    /// Used by sync operations that read FROM disk to avoid feedback loops.
    func save() async

    // MARK: - Artist/Album Entries

    func fetchArtistEntries() async -> [ArtistEntry]
    func fetchAlbumEntries() async -> [AlbumEntry]
    func updateArtistEntry(_ entry: ArtistEntry) async
    func updateAlbumEntry(_ entry: AlbumEntry) async
    func applyArtistEdits(original: ArtistEntry, updated: ArtistEntry) async
    func applyAlbumEdits(original: AlbumEntry, updated: AlbumEntry) async
    func deleteArtist(_ entry: ArtistEntry) async
    func deleteAlbum(_ entry: AlbumEntry) async

    // MARK: - Playlist Description

    func updatePlaylistDescription(_ playlist: Playlist, description: String) async
}
