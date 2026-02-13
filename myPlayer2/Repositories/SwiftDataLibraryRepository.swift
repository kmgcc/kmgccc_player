//
//  SwiftDataLibraryRepository.swift
//  myPlayer2
//
//  kmgccc_player - SwiftData Library Repository
//  Implements LibraryRepositoryProtocol using SwiftData.
//

import Foundation
import SwiftData

/// SwiftData implementation of LibraryRepositoryProtocol.
/// Provides persistent storage for tracks and playlists.
@MainActor
final class SwiftDataLibraryRepository: LibraryRepositoryProtocol {

    // MARK: - Properties

    private let modelContext: ModelContext
    private let libraryService: LocalLibraryService

    // MARK: - Initialization

    init(modelContext: ModelContext, libraryService: LocalLibraryService? = nil) {
        self.modelContext = modelContext
        self.libraryService = libraryService ?? LocalLibraryService.shared
        print("🗄️ SwiftDataLibraryRepository initialized with context: \(modelContext)")
    }

    // MARK: - Track Operations

    func fetchTracks(in playlist: Playlist?) async -> [Track] {
        if let playlist = playlist {
            print("📋 fetchTracks: in playlist '\(playlist.name)', count=\(playlist.tracks.count)")
            return playlist.tracks
        }

        // Fetch all tracks sorted by addedAt (newest first)
        let descriptor = FetchDescriptor<Track>(
            sortBy: [SortDescriptor(\.addedAt, order: .reverse)]
        )

        do {
            let tracks = try modelContext.fetch(descriptor)
            print("📋 fetchTracks: all tracks, count=\(tracks.count)")
            return tracks
        } catch {
            print("❌ Failed to fetch tracks: \(error)")
            return []
        }
    }

    func addTrack(_ track: Track) async {
        print("➕ addTrack: '\(track.title)', bookmarkData=\(track.fileBookmarkData.count) bytes")
        modelContext.insert(track)
        print("   ↳ inserted into context")
        saveContext()
        libraryService.writeSidecar(for: track)
    }

    func addTracks(_ tracks: [Track]) async {
        print("➕ addTracks: \(tracks.count) tracks")
        for track in tracks {
            modelContext.insert(track)
        }
        print("   ↳ all inserted into context")
        saveContext()
        for track in tracks {
            libraryService.writeSidecar(for: track)
        }
    }

    func addPlaylist(_ playlist: Playlist) async {
        modelContext.insert(playlist)
        saveContext()
        libraryService.writePlaylist(playlist)
    }

    func deleteTrack(_ track: Track) async {
        let playlists = await fetchPlaylists()
        for playlist in playlists {
            playlist.tracks.removeAll { $0.id == track.id }
        }
        modelContext.delete(track)
        saveContext()
        libraryService.deleteTrackFiles(track)
        libraryService.writeAllPlaylists(playlists)
    }

    func updateTrack(_ track: Track) async {
        // SwiftData automatically tracks changes, just save
        saveContext()
        libraryService.writeSidecar(for: track)
    }

    func trackExists(filePath: String) async -> Bool {
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate { $0.originalFilePath == filePath }
        )

        do {
            let count = try modelContext.fetchCount(descriptor)
            print("🔍 trackExists: '\(filePath)' -> \(count > 0)")
            return count > 0
        } catch {
            print("❌ Failed to check track existence: \(error)")
            return false
        }
    }

    func trackExists(title: String, artist: String) async -> Bool {
        let descriptor = FetchDescriptor<Track>(
            predicate: #Predicate<Track> { track in
                track.title == title && track.artist == artist
            }
        )

        do {
            let count = try modelContext.fetchCount(descriptor)
            print("🔍 trackExists: title='\(title)', artist='\(artist)' -> \(count > 0)")
            return count > 0
        } catch {
            print("❌ Failed to check track existence by title+artist: \(error)")
            return false
        }
    }

    // MARK: - Playlist Operations

    func fetchPlaylists() async -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\.createdAt, order: .forward)]
        )

        do {
            let playlists = try modelContext.fetch(descriptor)
            print("📚 fetchPlaylists: count=\(playlists.count)")
            return playlists
        } catch {
            print("❌ Failed to fetch playlists: \(error)")
            return []
        }
    }

    func createPlaylist(name: String) async -> Playlist {
        print("➕ createPlaylist: '\(name)'")
        let playlist = Playlist(name: name)
        modelContext.insert(playlist)
        saveContext()
        libraryService.writePlaylist(playlist)
        print("   ↳ playlist created with id=\(playlist.id)")
        return playlist
    }

    func renamePlaylist(_ playlist: Playlist, name: String) async {
        playlist.name = name
        saveContext()
        libraryService.writePlaylist(playlist)
    }

    func deletePlaylist(_ playlist: Playlist) async {
        modelContext.delete(playlist)
        saveContext()
        libraryService.deletePlaylist(playlist)
    }

    func addTracks(_ tracks: [Track], to playlist: Playlist) async {
        print("🔗 addTracks: \(tracks.count) tracks to playlist '\(playlist.name)'")
        for track in tracks {
            if !playlist.tracks.contains(where: { $0.id == track.id }) {
                playlist.tracks.append(track)
                print("   ↳ appended '\(track.title)' to playlist.tracks")
            }
        }
        print("   ↳ playlist.tracks.count = \(playlist.tracks.count)")
        saveContext()
        libraryService.writePlaylist(playlist)
    }

    func removeTracks(_ tracks: [Track], from playlist: Playlist) async {
        playlist.tracks.removeAll { track in
            tracks.contains { $0.id == track.id }
        }
        saveContext()
        libraryService.writePlaylist(playlist)
    }

    // MARK: - Statistics

    func totalTrackCount() async -> Int {
        let descriptor = FetchDescriptor<Track>()
        do {
            let count = try modelContext.fetchCount(descriptor)
            print("📊 totalTrackCount: \(count)")
            return count
        } catch {
            print("❌ Failed to count tracks: \(error)")
            return 0
        }
    }

    // MARK: - Metadata Listing

    func fetchUniqueArtists() async -> [String] {
        // Fetch all tracks to extract unique artists.
        // Optimization: In a larger app, this should be a direct query if SwiftData supports distinct properties efficiently.
        let descriptor = FetchDescriptor<Track>(sortBy: [SortDescriptor(\.artist)])
        do {
            let tracks = try modelContext.fetch(descriptor)
            let artists = Set(tracks.map { $0.artist }.filter { !$0.isEmpty })
            return Array(artists).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        } catch {
            print("❌ Failed to fetch unique artists: \(error)")
            return []
        }
    }

    func fetchUniqueAlbums() async -> [String] {
        let descriptor = FetchDescriptor<Track>(sortBy: [SortDescriptor(\.album)])
        do {
            let tracks = try modelContext.fetch(descriptor)
            let albums = Set(tracks.map { $0.album }.filter { !$0.isEmpty })
            return Array(albums).sorted {
                $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
        } catch {
            print("❌ Failed to fetch unique albums: \(error)")
            return []
        }
    }

    // MARK: - Private Helpers

    private func saveContext() {
        do {
            try modelContext.save()
            print("💾 Context saved successfully")
        } catch {
            print("❌ Failed to save context: \(error)")
        }
    }

    func save() async {
        saveContext()
    }
}
