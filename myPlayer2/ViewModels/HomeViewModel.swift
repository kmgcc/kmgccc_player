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
    private(set) var cachedStartupSnapshot: HomeStartupSnapshot?
    /// True after Home has built a complete in-memory snapshot from the
    /// currently loaded library. The view uses this as a startup gate so the
    /// first full Home paint does not race `LibraryViewModel.state == .loaded`.
    private(set) var hasPreparedContent = false

    private var trackIdentitySignature = 0
    private var trackMetadataSignature = 0
    private var playlistSignature = 0
    private var artistSignature = 0
    private var albumSignature = 0
    private var lastAppliedRefreshSignature: HomeRefreshSignature?
    private var snapshotWriteTask: Task<Void, Never>?

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
        let token = FirstUseHitchDiagnostics.begin(
            "HomeViewModel.refresh",
            detail: "tracks=\(allTracks.count), albums=\(libraryVM.albumEntries.count), artists=\(libraryVM.artistEntries.count), playlists=\(libraryVM.playlists.count)"
        )
        defer { FirstUseHitchDiagnostics.end(token) }

        let incomingSignature = HomeRefreshSignature(libraryVM: libraryVM, tracks: allTracks)
        guard incomingSignature != lastAppliedRefreshSignature else {
            hasPreparedContent = true
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
        lastAppliedRefreshSignature = incomingSignature
        hasPreparedContent = true
        writeStartupSnapshotIfNeeded(
            signature: incomingSignature.stableCacheSignature,
            libraryVM: libraryVM
        )
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
        let token = FirstUseHitchDiagnostics.begin(
            "HomeViewModel.refreshChangedSections",
            detail: "tracks=\(allTracks.count)"
        )
        defer { FirstUseHitchDiagnostics.end(token) }

        let incomingSignature = HomeRefreshSignature(libraryVM: libraryVM, tracks: allTracks)
        guard incomingSignature != lastAppliedRefreshSignature else {
            hasPreparedContent = true
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
        lastAppliedRefreshSignature = incomingSignature
        hasPreparedContent = true
        writeStartupSnapshotIfNeeded(
            signature: incomingSignature.stableCacheSignature,
            libraryVM: libraryVM
        )
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
        lastAppliedRefreshSignature = HomeRefreshSignature(libraryVM: libraryVM, tracks: allTracks)
        hasPreparedContent = true
        if let signature = lastAppliedRefreshSignature?.stableCacheSignature {
            writeStartupSnapshotIfNeeded(signature: signature, libraryVM: libraryVM)
        }
    }

    func refreshArtistAlbumSort(from libraryVM: LibraryViewModel) {
        artists = topArtists(from: libraryVM)
        albums = topAlbums(from: libraryVM)
        artistSignature = makeArtistSignature(libraryVM.artistEntries)
        albumSignature = makeAlbumSignature(libraryVM.albumEntries)
        lastAppliedRefreshSignature = nil
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
        let pick = PlaybackCoordinator.smartRandomPick(
            from: candidates.isEmpty ? fallbackCandidates : candidates
        ) ?? fallbackCandidates.first ?? allTracks.first

        selectedHeroTrackID = pick?.id
        selectedHeroGeneratedAt = pick == nil ? nil : Date()
        heroTrack = pick
        if let signature = lastAppliedRefreshSignature?.stableCacheSignature {
            writeStartupSnapshotIfNeeded(signature: signature, libraryVM: libraryVM)
        }
        hasPreparedContent = true
    }

    func loadCachedStartupSnapshot() async {
        guard cachedStartupSnapshot == nil else { return }
        cachedStartupSnapshot = await HomeStartupSnapshotStore.shared.load()
    }

    func invalidatePreparedContentForStartupGate() {
        hasPreparedContent = false
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
        hasPreparedContent = false
        trackIdentitySignature = 0
        trackMetadataSignature = 0
        playlistSignature = 0
        artistSignature = 0
        albumSignature = 0
        lastAppliedRefreshSignature = nil
    }

    private func topAlbums(from libraryVM: LibraryViewModel) -> [AlbumEntry] {
        let aggregateStats = LibraryAggregateStats(tracks: libraryVM.allTracks)
        return libraryVM.albumEntries
            .filter { !$0.isOrphaned }
            .sorted { compareAlbums($0, $1, libraryVM: libraryVM, aggregateStats: aggregateStats) }
            .prefix(20)
            .map { $0 }
    }

    private func topArtists(from libraryVM: LibraryViewModel) -> [ArtistEntry] {
        let aggregateStats = LibraryAggregateStats(tracks: libraryVM.allTracks)
        return libraryVM.artistEntries
            .filter { !$0.isOrphaned }
            .sorted { compareArtists($0, $1, libraryVM: libraryVM, aggregateStats: aggregateStats) }
            .prefix(15)
            .map { $0 }
    }

    private func compareArtists(
        _ lhs: ArtistEntry,
        _ rhs: ArtistEntry,
        libraryVM: LibraryViewModel,
        aggregateStats: LibraryAggregateStats
    ) -> Bool {
        let result: ComparisonResult
        let useNaturalDescending: Bool
        switch libraryVM.artistSortKey {
        case .name:
            result = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
            useNaturalDescending = false
        case .trackCount:
            result = compareInt(lhs.trackCount, rhs.trackCount)
            useNaturalDescending = false
        case .albumCount:
            result = compareInt(lhs.albumCount, rhs.albumCount)
            useNaturalDescending = false
        case .playCountTotal:
            result = compareAggregateMetric(
                aggregateStats.artistPlayCount(for: lhs),
                aggregateStats.artistPlayCount(for: rhs)
            )
            useNaturalDescending = true
        case .preferenceTotal:
            result = compareAggregateMetric(
                aggregateStats.artistPreferenceScore(for: lhs),
                aggregateStats.artistPreferenceScore(for: rhs)
            )
            useNaturalDescending = true
        case .totalDuration:
            result = compareDouble(lhs.totalDuration, rhs.totalDuration)
            useNaturalDescending = false
        case .updatedAt:
            result = compareDate(lhs.updatedAt, rhs.updatedAt)
            useNaturalDescending = false
        }
        if result == .orderedSame {
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
        if useNaturalDescending {
            return result == .orderedDescending
        }
        return libraryVM.trackSortOrder == .ascending
            ? result == .orderedAscending
            : result == .orderedDescending
    }

    private func compareAlbums(
        _ lhs: AlbumEntry,
        _ rhs: AlbumEntry,
        libraryVM: LibraryViewModel,
        aggregateStats: LibraryAggregateStats
    ) -> Bool {
        let result: ComparisonResult
        let useNaturalDescending: Bool
        switch libraryVM.albumSortKey {
        case .title:
            result = lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle)
            useNaturalDescending = false
        case .artist:
            result = lhs.primaryArtistDisplayName
                .localizedCaseInsensitiveCompare(rhs.primaryArtistDisplayName)
            useNaturalDescending = false
        case .trackCount:
            result = compareInt(lhs.trackCount, rhs.trackCount)
            useNaturalDescending = false
        case .playCountTotal:
            result = compareAggregateMetric(
                aggregateStats.albumPlayCount(for: lhs),
                aggregateStats.albumPlayCount(for: rhs)
            )
            useNaturalDescending = true
        case .preferenceTotal:
            result = compareAggregateMetric(
                aggregateStats.albumPreferenceScore(for: lhs),
                aggregateStats.albumPreferenceScore(for: rhs)
            )
            useNaturalDescending = true
        case .totalDuration:
            result = compareDouble(lhs.totalDuration, rhs.totalDuration)
            useNaturalDescending = false
        case .updatedAt:
            result = compareDate(lhs.updatedAt, rhs.updatedAt)
            useNaturalDescending = false
        }
        if result == .orderedSame {
            return lhs.displayTitle.localizedCaseInsensitiveCompare(rhs.displayTitle) == .orderedAscending
        }
        if useNaturalDescending {
            return result == .orderedDescending
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

    private func compareAggregateMetric(
        _ lhs: LibraryAggregateStats.Metric,
        _ rhs: LibraryAggregateStats.Metric
    ) -> ComparisonResult {
        if lhs.hasData != rhs.hasData {
            return lhs.hasData ? .orderedDescending : .orderedAscending
        }
        return compareDouble(lhs.value, rhs.value)
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

    private func writeStartupSnapshotIfNeeded(
        signature: String,
        libraryVM: LibraryViewModel
    ) {
        let snapshot = HomeStartupSnapshot(
            schemaVersion: HomeStartupSnapshot.currentSchemaVersion,
            librarySignature: signature,
            generatedAt: Date(),
            hero: heroTrack.map(HomeStartupSnapshot.TrackSummary.init(track:)),
            playlists: playlists.prefix(8).map(HomeStartupSnapshot.PlaylistSummary.init(playlist:)),
            albums: albums.prefix(12).map(HomeStartupSnapshot.AlbumSummary.init(album:)),
            artists: artists.prefix(12).map(HomeStartupSnapshot.ArtistSummary.init(artist:)),
            totalTrackCount: totalTrackCount,
            weeklyPlayCount: weeklyPlayCount,
            weeklyListeningSeconds: weeklyListeningSeconds,
            weeklyFavoriteArtistName: weeklyFavoriteArtistName,
            weeklyFavoriteArtistPlayCount: weeklyFavoriteArtistPlayCount,
            preferenceRanking: preferenceRanking.prefix(12).map(HomeStartupSnapshot.RankSummary.init(item:)),
            dailyListeningMap: dailyListeningMap
        )
        cachedStartupSnapshot = snapshot
        snapshotWriteTask?.cancel()
        snapshotWriteTask = Task(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            await HomeStartupSnapshotStore.shared.save(snapshot)
        }
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
        let pick = PlaybackCoordinator.smartRandomPick(from: preferredPool)
        selectedHeroTrackID = pick?.id
        selectedHeroGeneratedAt = pick == nil ? nil : now
        return pick
    }
}

nonisolated struct HomeStartupSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    struct TrackSummary: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let artist: String
        let album: String

        init(id: UUID, title: String, artist: String, album: String) {
            self.id = id
            self.title = title
            self.artist = artist
            self.album = album
        }

        @MainActor
        init(track: Track) {
            self.init(id: track.id, title: track.title, artist: track.artist, album: track.album)
        }
    }

    struct PlaylistSummary: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let trackCount: Int

        @MainActor
        init(playlist: Playlist) {
            id = playlist.id
            name = playlist.name
            trackCount = playlist.trackCount
        }
    }

    struct AlbumSummary: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let artist: String
        let trackCount: Int

        init(album: AlbumEntry) {
            id = album.id
            title = album.displayTitle
            artist = album.primaryArtistDisplayName
            trackCount = album.trackCount
        }
    }

    struct ArtistSummary: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let name: String
        let albumCount: Int
        let trackCount: Int

        init(artist: ArtistEntry) {
            id = artist.id
            name = artist.displayName
            albumCount = artist.albumCount
            trackCount = artist.trackCount
        }
    }

    struct RankSummary: Codable, Equatable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let artist: String
        let score: Double
        let playCount: Int

        init(item: HomeViewModel.PreferenceRankItem) {
            id = item.id
            title = item.title
            artist = item.artist
            score = item.score
            playCount = item.playCount
        }
    }

    let schemaVersion: Int
    let librarySignature: String
    let generatedAt: Date
    let hero: TrackSummary?
    let playlists: [PlaylistSummary]
    let albums: [AlbumSummary]
    let artists: [ArtistSummary]
    let totalTrackCount: Int
    let weeklyPlayCount: Int
    let weeklyListeningSeconds: Double
    let weeklyFavoriteArtistName: String?
    let weeklyFavoriteArtistPlayCount: Int
    let preferenceRanking: [RankSummary]
    let dailyListeningMap: [Date: Int]
}

private actor HomeStartupSnapshotStore {
    static let shared = HomeStartupSnapshotStore()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() -> HomeStartupSnapshot? {
        let url = cacheURL()
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(HomeStartupSnapshot.self, from: data),
              snapshot.schemaVersion == HomeStartupSnapshot.currentSchemaVersion
        else { return nil }
        return snapshot
    }

    func save(_ snapshot: HomeStartupSnapshot) {
        let url = cacheURL()
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(snapshot)
            try data.write(to: url, options: [.atomic])
        } catch {
            Log.debug("[Home] Failed to write startup snapshot: \(error.localizedDescription)", category: .library)
        }
    }

    private func cacheURL() -> URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("kmgccc_player", isDirectory: true)
            .appendingPathComponent("Home", isDirectory: true)
            .appendingPathComponent("startup-snapshot-v\(HomeStartupSnapshot.currentSchemaVersion).json")
    }
}

private struct HomeRefreshSignature: Equatable {
    let volatileHash: Int
    let stableCacheSignature: String

    @MainActor
    init(libraryVM: LibraryViewModel, tracks: [Track]) {
        var hasher = Hasher()
        var stable = HomeStableHasher()

        hasher.combine(tracks.count)
        stable.combine("tracks:\(tracks.count)")
        for track in tracks {
            hasher.combine(track.id)
            hasher.combine(track.title)
            hasher.combine(track.artist)
            hasher.combine(track.album)
            hasher.combine(track.albumGroupKey)
            hasher.combine(track.artworkFileName)
            stable.combine(track.id.uuidString)
            stable.combine(track.title)
            stable.combine(track.artist)
            stable.combine(track.album)
            stable.combine(track.albumGroupKey)
            stable.combine(track.artworkFileName ?? "")
        }

        hasher.combine(libraryVM.playlists.count)
        stable.combine("playlists:\(libraryVM.playlists.count)")
        for playlist in libraryVM.playlists {
            hasher.combine(playlist.id)
            hasher.combine(playlist.name)
            hasher.combine(playlist.userDescription)
            hasher.combine(playlist.tracks.count)
            stable.combine(playlist.id.uuidString)
            stable.combine(playlist.name)
            stable.combine(playlist.userDescription)
            stable.combine("\(playlist.tracks.count)")
            for track in playlist.tracks {
                hasher.combine(track.id)
                stable.combine(track.id.uuidString)
            }
        }

        hasher.combine(libraryVM.artistSortKey.rawValue)
        hasher.combine(libraryVM.albumSortKey.rawValue)
        hasher.combine(libraryVM.trackSortOrder.rawValue)
        stable.combine(libraryVM.artistSortKey.rawValue)
        stable.combine(libraryVM.albumSortKey.rawValue)
        stable.combine(libraryVM.trackSortOrder.rawValue)

        for artist in libraryVM.artistEntries {
            hasher.combine(artist.id)
            hasher.combine(artist.updatedAt)
            hasher.combine(artist.trackCount)
            hasher.combine(artist.albumCount)
            stable.combine(artist.id.uuidString)
            stable.combine("\(artist.updatedAt.timeIntervalSince1970)")
            stable.combine("\(artist.trackCount)")
            stable.combine("\(artist.albumCount)")
        }

        for album in libraryVM.albumEntries {
            hasher.combine(album.id)
            hasher.combine(album.updatedAt)
            hasher.combine(album.trackCount)
            stable.combine(album.id.uuidString)
            stable.combine("\(album.updatedAt.timeIntervalSince1970)")
            stable.combine("\(album.trackCount)")
        }

        volatileHash = hasher.finalize()
        stableCacheSignature = stable.digest
    }
}

private struct HomeStableHasher {
    private var hash: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ value: String) {
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        hash ^= 0xff
        hash = hash &* 0x0000_0100_0000_01B3
    }

    var digest: String {
        String(hash, radix: 16)
    }
}
