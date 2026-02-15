//
//  StubLibraryRepository.swift
//  myPlayer2
//
//  kmgccc_player - Stub Library Repository
//  Provides fake data for UI development and previews.
//

import Foundation

/// Stub implementation for UI development and previews.
/// Uses in-memory data instead of SwiftData.
@MainActor
final class StubLibraryRepository: LibraryRepositoryProtocol {

    // MARK: - In-Memory Storage

    private var playlists: [Playlist] = []
    private var allTracks: [Track] = []

    // MARK: - Initialization

    init() {
        setupFakeData()
    }

    func reloadFromLibrary() async {
        // No-op for stub
    }

    // MARK: - Track Operations

    func fetchTracks(in playlist: Playlist?) async -> [Track] {
        if let playlist = playlist {
            return playlist.tracks
        }
        return allTracks
    }

    func addTrack(_ track: Track) async {
        allTracks.append(track)
    }

    func addTracks(_ tracks: [Track]) async {
        allTracks.append(contentsOf: tracks)
    }

    func addPlaylist(_ playlist: Playlist) async {
        playlists.append(playlist)
    }

    func deleteTrack(_ track: Track) async {
        allTracks.removeAll { $0.id == track.id }
    }

    func updateTrack(_ track: Track) async {
        // No-op for stub
    }

    func trackExists(filePath: String) async -> Bool {
        allTracks.contains { $0.originalFilePath == filePath }
    }

    func trackExists(title: String, artist: String) async -> Bool {
        allTracks.contains { $0.title == title && $0.artist == artist }
    }

    func dedupMatchCount(title: String, artist: String) async -> Int {
        allTracks.filter {
            LibraryNormalization.normalizedDedupKey(title: $0.title, artist: $0.artist)
                == LibraryNormalization.normalizedDedupKey(title: title, artist: artist)
        }.count
    }

    // MARK: - Playlist Operations

    func fetchPlaylists() async -> [Playlist] {
        playlists
    }

    func createPlaylist(name: String) async -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        return playlist
    }

    func renamePlaylist(_ playlist: Playlist, name: String) async {
        playlist.name = name
    }

    func deletePlaylist(_ playlist: Playlist) async {
        playlists.removeAll { $0.id == playlist.id }
    }

    func addTracks(_ tracks: [Track], to playlist: Playlist) async {
        playlist.tracks.append(contentsOf: tracks)
    }

    func removeTracks(_ tracks: [Track], from playlist: Playlist) async {
        let trackIds = Set(tracks.map { $0.id })
        playlist.tracks.removeAll { trackIds.contains($0.id) }
    }

    // MARK: - Statistics

    func totalTrackCount() async -> Int {
        allTracks.count
    }

    // MARK: - Metadata Listing

    func fetchUniqueArtists() async -> [String] {
        let artists = Set(allTracks.map { $0.artist }.filter { !$0.isEmpty })
        return Array(artists).sorted()
    }

    func fetchUniqueAlbums() async -> [String] {
        let albums = Set(allTracks.map { $0.album }.filter { !$0.isEmpty })
        return Array(albums).sorted()
    }

    func fetchArtistSections() async -> [ArtistSection] {
        Dictionary(grouping: allTracks, by: { LibraryNormalization.normalizeArtist($0.artist) })
            .map { key, tracks in
                ArtistSection(
                    key: key,
                    name: LibraryNormalization.displayArtist(tracks.first?.artist),
                    trackCount: tracks.count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchAlbumSections() async -> [AlbumSection] {
        Dictionary(
            grouping: allTracks,
            by: { LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist) }
        )
        .map { key, tracks in
            AlbumSection(
                key: key,
                name: LibraryNormalization.displayAlbum(tracks.first?.album),
                artistName: LibraryNormalization.displayArtist(tracks.first?.artist),
                trackCount: tracks.count
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func fetchPlaylistItemAddedAtMap() async -> [UUID: [UUID: Date]] {
        Dictionary(uniqueKeysWithValues: playlists.map { playlist in
            (
                playlist.id,
                Dictionary(uniqueKeysWithValues: playlist.tracks.map { ($0.id, $0.addedAt) })
            )
        })
    }

    func clearIndexCacheAndRebuild() async {
        // No-op for stub
    }

    func save() async {
        // No-op for stub
    }

    // MARK: - Fake Data Setup

    private func setupFakeData() {
        // Create fake tracks with empty bookmark data (for UI preview only)
        let tracks = [
            Track(
                title: "Blinding Lights", artist: "The Weeknd", album: "After Hours", duration: 203,
                fileBookmarkData: Data(), originalFilePath: "/fake/blinding_lights.mp3"),
            Track(
                title: "Bohemian Rhapsody", artist: "Queen", album: "A Night at the Opera",
                duration: 354, fileBookmarkData: Data(), originalFilePath: "/fake/bohemian.mp3"),
            Track(
                title: "Shape of You", artist: "Ed Sheeran", album: "÷", duration: 234,
                fileBookmarkData: Data(), originalFilePath: "/fake/shape.mp3"),
            Track(
                title: "Hotel California", artist: "Eagles", album: "Hotel California",
                duration: 391, fileBookmarkData: Data(), originalFilePath: "/fake/hotel.mp3"),
            Track(
                title: "Stairway to Heaven", artist: "Led Zeppelin", album: "Led Zeppelin IV",
                duration: 480, fileBookmarkData: Data(), originalFilePath: "/fake/stairway.mp3"),
            Track(
                title: "Billie Jean", artist: "Michael Jackson", album: "Thriller", duration: 294,
                fileBookmarkData: Data(), originalFilePath: "/fake/billie.mp3"),
            Track(
                title: "Sweet Child O' Mine", artist: "Guns N' Roses",
                album: "Appetite for Destruction", duration: 356, fileBookmarkData: Data(),
                originalFilePath: "/fake/sweet.mp3"),
            Track(
                title: "Smells Like Teen Spirit", artist: "Nirvana", album: "Nevermind",
                duration: 301, fileBookmarkData: Data(), originalFilePath: "/fake/smells.mp3"),
        ]

        allTracks = tracks

        // Create fake playlists
        let favorites = Playlist(name: "Favorites ❤️")
        favorites.tracks = Array(tracks.prefix(3))

        let rock = Playlist(name: "Classic Rock 🎸")
        rock.tracks = [tracks[3], tracks[4], tracks[6], tracks[7]]

        let chill = Playlist(name: "Chill Vibes 🌊")
        chill.tracks = [tracks[0], tracks[2], tracks[5]]

        playlists = [favorites, rock, chill]
    }
}
