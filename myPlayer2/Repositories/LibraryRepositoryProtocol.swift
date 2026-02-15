//
//  LibraryRepositoryProtocol.swift
//  myPlayer2
//
//  kmgccc_player - Library Repository Protocol
//  Defines CRUD operations for tracks and playlists.
//

import Foundation

/// Protocol for library data access (tracks and playlists).
/// Implemented by SwiftDataLibraryRepository for persistence.
@MainActor
protocol LibraryRepositoryProtocol: AnyObject {
    /// Reload repository state from authoritative Music Library on disk.
    func reloadFromLibrary() async

    // MARK: - Track Operations

    /// Fetch all tracks, optionally filtered by playlist.
    /// - Parameter playlist: If nil, returns all tracks. Otherwise, returns tracks in the playlist.
    func fetchTracks(in playlist: Playlist?) async -> [Track]

    /// Add a new track to the library.
    func addTrack(_ track: Track) async

    /// Add multiple tracks to the library.
    func addTracks(_ tracks: [Track]) async

    /// Add a playlist (used for bootstrap from disk).
    func addPlaylist(_ playlist: Playlist) async

    /// Delete a track from the library.
    func deleteTrack(_ track: Track) async

    /// Update track metadata.
    func updateTrack(_ track: Track) async

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
}
