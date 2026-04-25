//
//  HomeViewModel.swift
//  myPlayer2
//
//  Home page data aggregation.
//  Reads from LibraryViewModel and PreferenceStatsService.
//

import Foundation
import SwiftUI

@Observable
@MainActor
final class HomeViewModel {

    // MARK: - Hero

    private(set) var heroTrack: Track?

    // MARK: - Sections

    private(set) var albums: [AlbumEntry] = []
    private(set) var artists: [ArtistEntry] = []
    private(set) var playlists: [Playlist] = []

    // MARK: - Stats

    private(set) var totalTrackCount: Int = 0
    private(set) var totalPlayCount: Int = 0
    private(set) var totalListeningSeconds: Double = 0
    private(set) var favoriteArtistName: String?
    private(set) var favoriteArtistAlbumCount: Int = 0
    private(set) var preferenceRanking: [PreferenceRankItem] = []
    private(set) var dailyListeningMap: [Date: Int] = [:]

    struct PreferenceRankItem: Identifiable {
        let id: UUID
        let title: String
        let artist: String
        let score: Double
        let playCount: Int
    }

    // MARK: - Refresh

    /// Lightweight refresh — reads from in-memory LibraryViewModel data.
    /// IMPORTANT: Does NOT call loadArtworkDataIfNeeded() in batch.
    /// Artwork loading is deferred to individual card views.
    func refresh(from libraryVM: LibraryViewModel) {
        let allTracks = libraryVM.allTracks
        guard !allTracks.isEmpty else {
            clearAll()
            return
        }

        // Hero: pick a random track (prefer one that has an artwork file reference)
        let tracksWithArt = allTracks.filter { $0.artworkFileName != nil }
        heroTrack = tracksWithArt.randomElement() ?? allTracks.randomElement()

        // Albums (up to 20, sorted by track count)
        albums = libraryVM.albumEntries
            .filter { !$0.isOrphaned }
            .sorted { $0.trackCount > $1.trackCount }
            .prefix(20)
            .map { $0 }

        // Artists (up to 15, sorted by track count)
        artists = libraryVM.artistEntries
            .filter { !$0.isOrphaned }
            .sorted { $0.trackCount > $1.trackCount }
            .prefix(15)
            .map { $0 }

        // Playlists
        playlists = libraryVM.playlists

        // Stats from PreferenceStatsService
        let statsService = PreferenceStatsService.shared
        totalTrackCount = allTracks.count

        var totalPlays = 0
        var totalSeconds: Double = 0
        var artistPlayCounts: [String: Int] = [:]
        var ranked: [(id: UUID, title: String, artist: String, stats: TrackPreferenceStats)] = []

        for track in allTracks {
            let stats = statsService.getStats(for: track.id)
            totalPlays += stats.playCount
            totalSeconds += stats.totalPlayedSeconds

            let artistKey = track.artist
            artistPlayCounts[artistKey, default: 0] += stats.playCount

            if stats.playCount > 0 {
                ranked.append((track.id, track.title, track.artist, stats))
            }
        }

        totalPlayCount = totalPlays
        totalListeningSeconds = totalSeconds

        // Favorite artist
        if let topArtist = artistPlayCounts.max(by: { $0.value < $1.value }) {
            favoriteArtistName = topArtist.key
            let entry = libraryVM.artistEntries.first {
                $0.displayName == topArtist.key || $0.canonicalName == topArtist.key
            }
            favoriteArtistAlbumCount = entry?.albumCount ?? 0
        } else {
            favoriteArtistName = nil
            favoriteArtistAlbumCount = 0
        }

        // Preference ranking (top 8, by preference score)
        preferenceRanking = ranked
            .sorted { $0.stats.preferenceScoreCache > $1.stats.preferenceScoreCache }
            .prefix(8)
            .map { item in
                PreferenceRankItem(
                    id: item.id,
                    title: item.title,
                    artist: item.artist,
                    score: item.stats.preferenceScoreCache,
                    playCount: item.stats.playCount
                )
            }

        // Daily listening map: aggregate by day from lastPlayedAt
        var dayMap: [Date: Int] = [:]
        let calendar = Calendar.current
        for track in allTracks {
            let stats = statsService.getStats(for: track.id)
            if let lastPlayed = stats.lastPlayedAt {
                let day = calendar.startOfDay(for: lastPlayed)
                dayMap[day, default: 0] += stats.playCount
            }
        }
        dailyListeningMap = dayMap
    }

    private func clearAll() {
        heroTrack = nil
        albums = []
        artists = []
        playlists = []
        totalTrackCount = 0
        totalPlayCount = 0
        totalListeningSeconds = 0
        favoriteArtistName = nil
        favoriteArtistAlbumCount = 0
        preferenceRanking = []
        dailyListeningMap = [:]
    }
}
