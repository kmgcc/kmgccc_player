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

    private var trackIdentitySignature = 0
    private var trackMetadataSignature = 0
    private var playlistSignature = 0
    private var artistSignature = 0
    private var albumSignature = 0

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

        albums = topAlbums(from: libraryVM)
        artists = topArtists(from: libraryVM)

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
        var dayMap: [Date: Int] = [:]
        let calendar = Calendar.current
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: Date())

        for track in allTracks {
            let stats = statsService.getStats(for: track.id)
            totalPlays += stats.playCount
            totalSeconds += stats.totalPlayedSeconds

            let artistKey = track.artist
            artistPlayCounts[artistKey, default: 0] += stats.playCount

            if let lastPlayedAt = stats.lastPlayedAt {
                let day = calendar.startOfDay(for: lastPlayedAt)
                dayMap[day, default: 0] += stats.playCount

                if let weekInterval, weekInterval.contains(lastPlayedAt) {
                    weekPlays += stats.playCount
                    weekSeconds += stats.totalPlayedSeconds
                    weeklyArtistPlayCounts[artistKey, default: 0] += stats.playCount
                }
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

        dailyListeningMap = dayMap
        updateCachedSignatures(from: libraryVM, allTracks: allTracks)
    }

    /// Incremental refresh for ordinary visible-state changes. This avoids
    /// reassigning stable Home sections when only playlists or one track's
    /// metadata changed.
    func refreshChangedSections(from libraryVM: LibraryViewModel) {
        let allTracks = libraryVM.allTracks
        guard !allTracks.isEmpty else {
            clearAll()
            return
        }

        let newTrackIdentitySignature = makeTrackIdentitySignature(allTracks)
        guard newTrackIdentitySignature == trackIdentitySignature else {
            refresh(from: libraryVM)
            return
        }

        refreshHeroReference(in: allTracks)

        let newPlaylistSignature = makePlaylistSignature(libraryVM.playlists)
        if newPlaylistSignature != playlistSignature {
            playlists = libraryVM.playlists
            playlistSignature = newPlaylistSignature
        }

        let newArtistSignature = makeArtistSignature(libraryVM.artistEntries)
        if newArtistSignature != artistSignature {
            artists = topArtists(from: libraryVM)
            artistSignature = newArtistSignature
        }

        let newAlbumSignature = makeAlbumSignature(libraryVM.albumEntries)
        if newAlbumSignature != albumSignature {
            albums = topAlbums(from: libraryVM)
            albumSignature = newAlbumSignature
        }

        let newTrackMetadataSignature = makeTrackMetadataSignature(allTracks)
        if newTrackMetadataSignature != trackMetadataSignature {
            refreshStats(from: libraryVM, allTracks: allTracks)
            trackMetadataSignature = newTrackMetadataSignature
        }
    }

    func applyTrackUpdates(from libraryVM: LibraryViewModel, trackIDs: [UUID]) {
        let allTracks = libraryVM.allTracks
        guard !allTracks.isEmpty else {
            clearAll()
            return
        }

        let newTrackIdentitySignature = makeTrackIdentitySignature(allTracks)
        guard newTrackIdentitySignature == trackIdentitySignature else {
            refresh(from: libraryVM)
            return
        }

        let changedIDs = Set(trackIDs)
        let updatedByID = Dictionary(uniqueKeysWithValues: allTracks.map { ($0.id, $0) })
        if let heroID = heroTrack?.id, changedIDs.contains(heroID), let updatedHero = updatedByID[heroID] {
            heroTrack = updatedHero
        }

        let newTrackMetadataSignature = makeTrackMetadataSignature(allTracks)
        if newTrackMetadataSignature != trackMetadataSignature
            || preferenceRanking.contains(where: { changedIDs.contains($0.id) })
        {
            refreshStats(from: libraryVM, allTracks: allTracks)
        }

        let newArtistSignature = makeArtistSignature(libraryVM.artistEntries)
        if newArtistSignature != artistSignature {
            artists = topArtists(from: libraryVM)
            artistSignature = newArtistSignature
        }

        let newAlbumSignature = makeAlbumSignature(libraryVM.albumEntries)
        if newAlbumSignature != albumSignature {
            albums = topAlbums(from: libraryVM)
            albumSignature = newAlbumSignature
        }

        trackMetadataSignature = newTrackMetadataSignature
    }

    func refreshArtistAlbumSort(from libraryVM: LibraryViewModel) {
        artists = topArtists(from: libraryVM)
        albums = topAlbums(from: libraryVM)
        artistSignature = makeArtistSignature(libraryVM.artistEntries)
        albumSignature = makeAlbumSignature(libraryVM.albumEntries)
    }

    func switchHeroTrack(from libraryVM: LibraryViewModel) {
        let allTracks = libraryVM.allTracks
        guard !allTracks.isEmpty else {
            heroTrack = nil
            selectedHeroTrackID = nil
            selectedHeroGeneratedAt = nil
            return
        }

        let tracksWithArt = allTracks.filter { $0.artworkFileName != nil }
        let preferredPool = tracksWithArt.isEmpty ? allTracks : tracksWithArt
        let currentID = heroTrack?.id ?? selectedHeroTrackID
        let candidates = preferredPool.filter { $0.id != currentID }
        let fallbackCandidates = allTracks.filter { $0.id != currentID }
        let pick = PlaybackCoordinator.smartRandomQueue(
            from: candidates.isEmpty ? fallbackCandidates : candidates
        ).first ?? fallbackCandidates.first ?? allTracks.first

        selectedHeroTrackID = pick?.id
        selectedHeroGeneratedAt = pick == nil ? nil : Date()
        heroTrack = pick
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
        trackIdentitySignature = 0
        trackMetadataSignature = 0
        playlistSignature = 0
        artistSignature = 0
        albumSignature = 0
    }

    private func topAlbums(from libraryVM: LibraryViewModel) -> [AlbumEntry] {
        libraryVM.albumEntries
            .filter { !$0.isOrphaned }
            .sorted { compareAlbums($0, $1, libraryVM: libraryVM) }
            .prefix(20)
            .map { $0 }
    }

    private func topArtists(from libraryVM: LibraryViewModel) -> [ArtistEntry] {
        libraryVM.artistEntries
            .filter { !$0.isOrphaned }
            .sorted { compareArtists($0, $1, libraryVM: libraryVM) }
            .prefix(15)
            .map { $0 }
    }

    private func compareArtists(
        _ lhs: ArtistEntry,
        _ rhs: ArtistEntry,
        libraryVM: LibraryViewModel
    ) -> Bool {
        let result: ComparisonResult
        switch libraryVM.artistSortKey {
        case .name:
            result = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
        case .trackCount:
            result = compareInt(lhs.trackCount, rhs.trackCount)
        case .albumCount:
            result = compareInt(lhs.albumCount, rhs.albumCount)
        case .totalDuration:
            result = compareDouble(lhs.totalDuration, rhs.totalDuration)
        case .updatedAt:
            result = compareDate(lhs.updatedAt, rhs.updatedAt)
        }
        if result == .orderedSame {
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        return libraryVM.trackSortOrder == .ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func compareAlbums(
        _ lhs: AlbumEntry,
        _ rhs: AlbumEntry,
        libraryVM: LibraryViewModel
    ) -> Bool {
        let result: ComparisonResult
        switch libraryVM.albumSortKey {
        case .title:
            result = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
        case .artist:
            result = lhs.primaryArtistDisplayName
                .localizedCaseInsensitiveCompare(rhs.primaryArtistDisplayName)
        case .trackCount:
            result = compareInt(lhs.trackCount, rhs.trackCount)
        case .totalDuration:
            result = compareDouble(lhs.totalDuration, rhs.totalDuration)
        case .updatedAt:
            result = compareDate(lhs.updatedAt, rhs.updatedAt)
        }
        if result == .orderedSame {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
        return libraryVM.trackSortOrder == .ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func compareInt(_ a: Int, _ b: Int) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    private func compareDouble(_ a: Double, _ b: Double) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    private func compareDate(_ a: Date, _ b: Date) -> ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    private func refreshStats(from libraryVM: LibraryViewModel, allTracks: [Track]) {
        let statsService = PreferenceStatsService.shared
        totalTrackCount = allTracks.count

        var totalPlays = 0
        var totalSeconds: Double = 0
        var weekPlays = 0
        var weekSeconds: Double = 0
        var artistPlayCounts: [String: Int] = [:]
        var weeklyArtistPlayCounts: [String: Int] = [:]
        var ranked: [(track: Track, stats: TrackPreferenceStats)] = []
        var dayMap: [Date: Int] = [:]
        let calendar = Calendar.current
        let weekInterval = calendar.dateInterval(of: .weekOfYear, for: Date())

        for track in allTracks {
            let stats = statsService.getStats(for: track.id)
            totalPlays += stats.playCount
            totalSeconds += stats.totalPlayedSeconds

            let artistKey = track.artist
            artistPlayCounts[artistKey, default: 0] += stats.playCount

            if let lastPlayedAt = stats.lastPlayedAt {
                let day = calendar.startOfDay(for: lastPlayedAt)
                dayMap[day, default: 0] += stats.playCount

                if let weekInterval, weekInterval.contains(lastPlayedAt) {
                    weekPlays += stats.playCount
                    weekSeconds += stats.totalPlayedSeconds
                    weeklyArtistPlayCounts[artistKey, default: 0] += stats.playCount
                }
            }

            if stats.playCount > 0 {
                ranked.append((track, stats))
            }
        }

        totalPlayCount = totalPlays
        totalListeningSeconds = totalSeconds
        weeklyPlayCount = weekPlays
        weeklyListeningSeconds = weekSeconds

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

        dailyListeningMap = dayMap
    }

    private func refreshHeroReference(in allTracks: [Track]) {
        guard let heroID = heroTrack?.id ?? selectedHeroTrackID,
              let updatedHero = allTracks.first(where: { $0.id == heroID })
        else { return }
        heroTrack = updatedHero
    }

    private func updateCachedSignatures(from libraryVM: LibraryViewModel, allTracks: [Track]) {
        trackIdentitySignature = makeTrackIdentitySignature(allTracks)
        trackMetadataSignature = makeTrackMetadataSignature(allTracks)
        playlistSignature = makePlaylistSignature(libraryVM.playlists)
        artistSignature = makeArtistSignature(libraryVM.artistEntries)
        albumSignature = makeAlbumSignature(libraryVM.albumEntries)
    }

    private func makeTrackIdentitySignature(_ tracks: [Track]) -> Int {
        var hasher = Hasher()
        hasher.combine(tracks.count)
        for track in tracks {
            hasher.combine(track.id)
        }
        return hasher.finalize()
    }

    private func makeTrackMetadataSignature(_ tracks: [Track]) -> Int {
        var hasher = Hasher()
        hasher.combine(tracks.count)
        for track in tracks {
            hasher.combine(track.id)
            hasher.combine(track.title)
            hasher.combine(track.artist)
            hasher.combine(track.album)
            hasher.combine(track.albumGroupKey)
            hasher.combine(track.artworkFileName)
        }
        return hasher.finalize()
    }

    private func makePlaylistSignature(_ playlists: [Playlist]) -> Int {
        var hasher = Hasher()
        hasher.combine(playlists.count)
        for playlist in playlists {
            hasher.combine(playlist.id)
            hasher.combine(playlist.name)
            hasher.combine(playlist.userDescription)
            hasher.combine(playlist.tracks.count)
            for track in playlist.tracks {
                hasher.combine(track.id)
            }
        }
        return hasher.finalize()
    }

    private func makeArtistSignature(_ artists: [ArtistEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(artists.count)
        for artist in artists {
            hasher.combine(artist.id)
            hasher.combine(artist.displayName)
            hasher.combine(artist.canonicalName)
            hasher.combine(artist.albumCount)
            hasher.combine(artist.trackCount)
            hasher.combine(artist.artworkFileName)
        }
        return hasher.finalize()
    }

    private func makeAlbumSignature(_ albums: [AlbumEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(albums.count)
        for album in albums {
            hasher.combine(album.id)
            hasher.combine(album.displayTitle)
            hasher.combine(album.canonicalKey)
            hasher.combine(album.primaryArtistDisplayName)
            hasher.combine(album.trackCount)
            hasher.combine(album.artworkFileName)
        }
        return hasher.finalize()
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
        let preferredPool = tracksWithArt.isEmpty ? allTracks : tracksWithArt
        let pick = PlaybackCoordinator.smartRandomQueue(from: preferredPool).first
        selectedHeroTrackID = pick?.id
        selectedHeroGeneratedAt = pick == nil ? nil : now
        return pick
    }
}
