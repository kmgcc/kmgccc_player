//
//  SwiftDataLibraryRepository.swift
//  myPlayer2
//
//  TrueMusic - SwiftData Library Repository
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

    // MARK: - Initialization

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
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
    }

    func addTracks(_ tracks: [Track]) async {
        print("➕ addTracks: \(tracks.count) tracks")
        for track in tracks {
            modelContext.insert(track)
        }
        print("   ↳ all inserted into context")
        saveContext()
    }

    func deleteTrack(_ track: Track) async {
        modelContext.delete(track)
        saveContext()
    }

    func updateTrack(_ track: Track) async {
        // SwiftData automatically tracks changes, just save
        saveContext()
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

    // MARK: - Playlist Operations

    func fetchPlaylists() async -> [Playlist] {
        let descriptor = FetchDescriptor<Playlist>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
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
        print("   ↳ playlist created with id=\(playlist.id)")
        return playlist
    }

    func renamePlaylist(_ playlist: Playlist, name: String) async {
        playlist.name = name
        saveContext()
    }

    func deletePlaylist(_ playlist: Playlist) async {
        modelContext.delete(playlist)
        saveContext()
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
    }

    func removeTracks(_ tracks: [Track], from playlist: Playlist) async {
        playlist.tracks.removeAll { track in
            tracks.contains { $0.id == track.id }
        }
        saveContext()
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

    // MARK: - Private Helpers

    private func saveContext() {
        do {
            try modelContext.save()
            print("💾 Context saved successfully")
        } catch {
            print("❌ Failed to save context: \(error)")
        }
    }
}
