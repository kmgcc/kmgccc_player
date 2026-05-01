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

    /// Minimum time between hero rerolls (runtime only, not persisted).
    private static let heroRefreshInterval: TimeInterval = 6 * 60 * 60

    private(set) var heroTrack: Track?
    private var selectedHeroTrackID: UUID?
    private var selectedHeroGeneratedAt: Date?

    // MARK: - Sections

    private(set) var albums: [AlbumEntry] = []
    private(set) var artists: [ArtistEntry] = []
    private(set) var playlists: [Playlist] = []

    // MARK: - Stats

    private(set) var totalTrackCount: Int = 0
    private(set) var totalPlayCount: Int = 0
    private(set) var totalListeningSeconds: Double = 0
    private(set) var weeklyPlayCount: Int = 0
    private(set) var weeklyListeningSeconds: Double = 0
    private(set) var favoriteArtistName: String?
    private(set) var favoriteArtistAlbumCount: Int = 0
    private(set) var weeklyFavoriteArtistName: String?
    private(set) var weeklyFavoriteArtistPlayCount: Int = 0
    private(set) var preferenceRanking: [PreferenceRankItem] = []
    private(set) var dailyListeningMap: [Date: Int] = [:]

    struct PreferenceRankItem: Identifiable {
        let id: UUID
        let track: Track
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

        heroTrack = resolveHeroTrack(in: allTracks)

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
        var weekPlays = 0
        var weekSeconds: Double = 0
        var artistPlayCounts: [String: Int] = [:]
        var weeklyArtistPlayCounts: [String: Int] = [:]
        var ranked: [(track: Track, stats: TrackPreferenceStats)] = []
        let calendar = Calendar.current
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: Date())

        for track in allTracks {
            let stats = statsService.getStats(for: track.id)
            totalPlays += stats.playCount
            totalSeconds += stats.totalPlayedSeconds

            let artistKey = track.artist
            artistPlayCounts[artistKey, default: 0] += stats.playCount

            if let lastPlayedAt = stats.lastPlayedAt,
               let weekInterval,
               weekInterval.contains(lastPlayedAt)
            {
                weekPlays += stats.playCount
                weekSeconds += stats.totalPlayedSeconds
                weeklyArtistPlayCounts[artistKey, default: 0] += stats.playCount
            }

            if stats.playCount > 0 {
                ranked.append((track, stats))
            }
        }

        totalPlayCount = totalPlays
        totalListeningSeconds = totalSeconds
        weeklyPlayCount = weekPlays
        weeklyListeningSeconds = weekSeconds

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

        if let topWeeklyArtist = weeklyArtistPlayCounts.max(by: { $0.value < $1.value }) {
            weeklyFavoriteArtistName = topWeeklyArtist.key
            weeklyFavoriteArtistPlayCount = topWeeklyArtist.value
        } else {
            weeklyFavoriteArtistName = nil
            weeklyFavoriteArtistPlayCount = 0
        }

        // Preference ranking (top 30, by preference score)
        preferenceRanking = ranked
            .sorted { $0.stats.preferenceScoreCache > $1.stats.preferenceScoreCache }
            .prefix(30)
            .map { item in
                PreferenceRankItem(
                    id: item.track.id,
                    track: item.track,
                    title: item.track.title,
                    artist: item.track.artist,
                    score: item.stats.preferenceScoreCache,
                    playCount: item.stats.playCount
                )
            }

        // Daily listening map: aggregate by day from lastPlayedAt
        var dayMap: [Date: Int] = [:]
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
        selectedHeroTrackID = nil
        selectedHeroGeneratedAt = nil
        albums = []
        artists = []
        playlists = []
        totalTrackCount = 0
        totalPlayCount = 0
        totalListeningSeconds = 0
        weeklyPlayCount = 0
        weeklyListeningSeconds = 0
        favoriteArtistName = nil
        favoriteArtistAlbumCount = 0
        weeklyFavoriteArtistName = nil
        weeklyFavoriteArtistPlayCount = 0
        preferenceRanking = []
        dailyListeningMap = [:]
    }

    /// Reuse the previously chosen hero unless it disappeared, the cooldown
    /// elapsed, or no hero has been chosen yet.
    private func resolveHeroTrack(in allTracks: [Track]) -> Track? {
        let now = Date()
        if let id = selectedHeroTrackID,
           let pickedAt = selectedHeroGeneratedAt,
           now.timeIntervalSince(pickedAt) < Self.heroRefreshInterval,
           let existing = allTracks.first(where: { $0.id == id })
        {
            return existing
        }

        let tracksWithArt = allTracks.filter { $0.artworkFileName != nil }
        let pick = tracksWithArt.randomElement() ?? allTracks.randomElement()
        selectedHeroTrackID = pick?.id
        selectedHeroGeneratedAt = pick == nil ? nil : now
        return pick
    }
}
