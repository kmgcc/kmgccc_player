//
//  SwiftDataLibraryRepository.swift
//  myPlayer2
//
//  Authoritative data source: Music Library on disk.
//  SwiftData is used only for TrackIndexEntry cache.
//

import Foundation
import SwiftData

@MainActor
final class SwiftDataLibraryRepository: LibraryRepositoryProtocol {
    private let libraryService: LocalLibraryService
    private let scanner: MusicLibraryScanner
    private let fileManager = FileManager.default
    private let indexContext: ModelContext?
    private var changeHandler: LibraryRepositoryChangeHandler?

    private var allTracks: [Track] = []
    private var playlists: [Playlist] = []
    private var runtimeArtists: [ArtistSection] = []
    private var runtimeAlbums: [AlbumSection] = []
    private var dedupCountByKey: [String: Int] = [:]
    private var playlistItemAddedAtMap: [UUID: [UUID: Date]] = [:]
    private var artistEntries: [ArtistEntry] = []
    private var albumEntries: [AlbumEntry] = []
    private let metadataSync = LibraryMetadataSync()

    init(modelContext: ModelContext? = nil, libraryService: LocalLibraryService? = nil) {
        self.indexContext = modelContext
        self.libraryService = libraryService ?? LocalLibraryService.shared
        self.scanner = MusicLibraryScanner()
    }

    func setChangeHandler(_ handler: LibraryRepositoryChangeHandler?) {
        changeHandler = handler
    }

    // MARK: - Boot/Reload

    func reloadFromLibrary() async {
        libraryService.ensureLibraryFolders()
        playlistItemAddedAtMap.removeAll()
        let metas = scanner.scanTracks()
        let tracks = metas.map { buildTrack(from: $0) }
        let tracksById = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        let sidecars = libraryService.loadPlaylistSidecarsFromDisk()
        let loadedPlaylists: [Playlist] = sidecars.map { sidecar in
            let resolvedTrackIDs: [UUID]
            let addedAtByTrackID: [UUID: Date]

            if sidecar.schemaVersion >= 2 {
                resolvedTrackIDs = sidecar.items.map(\.trackID)
                addedAtByTrackID = Dictionary(uniqueKeysWithValues: sidecar.items.map {
                    ($0.trackID, $0.addedAt)
                })
            } else {
                resolvedTrackIDs = sidecar.trackIDs
                addedAtByTrackID = Dictionary(uniqueKeysWithValues: resolvedTrackIDs.map { trackID in
                    let fallback = tracksById[trackID]?.importedAt ?? tracksById[trackID]?.addedAt
                        ?? Date()
                    return (trackID, fallback)
                })
            }

            let resolved = resolvedTrackIDs.compactMap { tracksById[$0] }
            playlistItemAddedAtMap[sidecar.id] = addedAtByTrackID
            return Playlist(
                id: sidecar.id,
                name: sidecar.name,
                userDescription: sidecar.description ?? "",
                createdAt: sidecar.createdAt,
                tracks: resolved
            )
        }

        allTracks = tracks.sorted { ($0.importedAt ?? $0.addedAt) > ($1.importedAt ?? $1.addedAt) }
        playlists = loadedPlaylists.sorted { $0.createdAt < $1.createdAt }
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums
    }

    // MARK: - Track Operations

    func fetchTracks(in playlist: Playlist?) async -> [Track] {
        if let playlist { return playlist.tracks }
        return allTracks
    }

    func fetchTracks(ids: [UUID]) async -> [Track] {
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return [] }
        return allTracks.filter { idSet.contains($0.id) }
    }

    func addTrack(_ track: Track) async {
        allTracks.append(track)
        persistImportedTrackResources([track], reason: "initialImport")
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums
    }

    func addTracks(_ tracks: [Track]) async {
        allTracks.append(contentsOf: tracks)
        persistImportedTrackResources(tracks, reason: "initialImport")
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums
    }

    func addPlaylist(_ playlist: Playlist) async {
        playlists.append(playlist)
        playlists.sort { $0.createdAt < $1.createdAt }
        playlistItemAddedAtMap[playlist.id] = [:]
        writePlaylistToDisk(playlist)
    }

    func deleteTrack(_ track: Track) async {
        allTracks.removeAll { $0.id == track.id }
        for playlist in playlists {
            playlist.tracks.removeAll { $0.id == track.id }
            playlistItemAddedAtMap[playlist.id]?[track.id] = nil
            writePlaylistToDisk(playlist)
        }
        libraryService.deleteTrackFiles(track)
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums
    }

    func persistTrackMetaOnly(_ track: Track, reason: String) async {
        _ = await persistTrackMetaOnly([track], reason: reason)
    }

    func persistTrackMetaOnly(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta-only",
            reason: reason
        ) { [libraryService] track in
            libraryService.writeMetaOnly(for: track, reason: reason)
        }
    }

    func persistTrackMetaAndLyrics(_ track: Track, reason: String) async {
        _ = await persistTrackMetaAndLyrics([track], reason: reason)
    }

    func persistTrackMetaAndLyrics(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta+lyrics",
            reason: reason
        ) { [libraryService] track in
            libraryService.writeTrackMetaAndLyrics(for: track, reason: reason)
        }
    }

    func persistTrackMetaAndArtwork(_ track: Track, reason: String) async {
        _ = await persistTrackMetaAndArtwork([track], reason: reason)
    }

    func persistTrackMetaAndArtwork(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta+artwork",
            reason: reason
        ) { [libraryService] track in
            libraryService.writeTrackMetaAndArtwork(for: track, reason: reason)
        }
    }

    func persistTrackMetaLyricsAndArtwork(_ track: Track, reason: String) async {
        _ = await persistTrackMetaLyricsAndArtwork([track], reason: reason)
    }

    func persistTrackMetaLyricsAndArtwork(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta+lyrics+artwork",
            reason: reason
        ) { [libraryService] track in
            libraryService.writeTrackMetaLyricsAndArtwork(for: track, reason: reason)
        }
    }

    func refreshTracks(ids: [UUID]) async -> [Track] {
        let uniqueIDs = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueIDs.isEmpty else { return [] }

        Log.info(
            "[ImportEnrichmentReload] reload requested for track IDs: \(uniqueIDs.map(\.uuidString))",
            category: .library
        )

        let metas = scanner.scanTracks(ids: uniqueIDs)
        let refreshedTracks = metas.map(buildTrack)
        let refreshedByID = Dictionary(uniqueKeysWithValues: refreshedTracks.map { ($0.id, $0) })

        guard !refreshedByID.isEmpty else {
            Log.warning(
                "[ImportEnrichmentReload] reload read complete for track IDs: []",
                category: .library
            )
            return []
        }

        allTracks = allTracks.map { refreshedByID[$0.id] ?? $0 }
        for playlist in playlists {
            playlist.tracks = playlist.tracks.map { refreshedByID[$0.id] ?? $0 }
        }
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums

        let refreshedIDs = refreshedTracks.map(\.id.uuidString)
        Log.info(
            "[ImportEnrichmentReload] reload read complete for track IDs: \(refreshedIDs)",
            category: .library
        )
        Log.info(
            "[ImportEnrichmentReload] repository cache replaced for \(refreshedTracks.count) tracks",
            category: .library
        )
        return refreshedTracks
    }

    func trackExists(filePath: String) async -> Bool {
        allTracks.contains { $0.originalFilePath == filePath }
    }

    func trackExists(title: String, artist: String) async -> Bool {
        let key = LibraryNormalization.normalizedDedupKey(title: title, artist: artist)
        return (dedupCountByKey[key] ?? 0) > 0
    }

    func dedupMatchCount(title: String, artist: String) async -> Int {
        let key = LibraryNormalization.normalizedDedupKey(title: title, artist: artist)
        return dedupCountByKey[key] ?? 0
    }

    // MARK: - Playlist Operations

    func fetchPlaylists() async -> [Playlist] {
        playlists
    }

    func createPlaylist(name: String) async -> Playlist {
        let playlist = Playlist(name: name)
        playlists.append(playlist)
        playlists.sort { $0.createdAt < $1.createdAt }
        playlistItemAddedAtMap[playlist.id] = [:]
        writePlaylistToDisk(playlist)
        return playlist
    }

    func renamePlaylist(_ playlist: Playlist, name: String) async {
        await updatePlaylistDetails(
            playlist,
            name: name,
            description: playlist.userDescription
        )
    }

    func updatePlaylistDetails(_ playlist: Playlist, name: String, description: String) async {
        playlist.name = name
        playlist.userDescription = description
        writePlaylistToDisk(playlist)
    }

    func deletePlaylist(_ playlist: Playlist) async {
        playlists.removeAll { $0.id == playlist.id }
        playlistItemAddedAtMap[playlist.id] = nil
        libraryService.deletePlaylist(playlist)
    }

    func addTracks(_ tracks: [Track], to playlist: Playlist) async {
        var dates = playlistItemAddedAtMap[playlist.id] ?? [:]
        for track in tracks where !playlist.tracks.contains(where: { $0.id == track.id }) {
            playlist.tracks.append(track)
            dates[track.id] = Date()
        }
        playlistItemAddedAtMap[playlist.id] = dates
        writePlaylistToDisk(playlist)
    }

    func removeTracks(_ tracks: [Track], from playlist: Playlist) async {
        let trackIds = Set(tracks.map(\.id))
        playlist.tracks.removeAll { trackIds.contains($0.id) }
        var dates = playlistItemAddedAtMap[playlist.id] ?? [:]
        for trackID in trackIds {
            dates[trackID] = nil
        }
        playlistItemAddedAtMap[playlist.id] = dates
        writePlaylistToDisk(playlist)
    }

    // MARK: - Statistics & Runtime Sections

    func totalTrackCount() async -> Int {
        allTracks.count
    }

    func fetchUniqueArtists() async -> [String] {
        runtimeArtists.map(\.name)
    }

    func fetchUniqueAlbums() async -> [String] {
        runtimeAlbums.map(\.name)
    }

    func fetchArtistSections() async -> [ArtistSection] {
        runtimeArtists
    }

    func fetchAlbumSections() async -> [AlbumSection] {
        runtimeAlbums
    }

    func fetchPlaylistItemAddedAtMap() async -> [UUID: [UUID: Date]] {
        playlistItemAddedAtMap
    }

    // MARK: - Artist/Album Entries

    func fetchArtistEntries() async -> [ArtistEntry] {
        artistEntries
    }

    func fetchAlbumEntries() async -> [AlbumEntry] {
        albumEntries
    }

    func updateArtistEntry(_ entry: ArtistEntry) async {
        if let idx = artistEntries.firstIndex(where: { $0.id == entry.id }) {
            artistEntries[idx] = entry
        }
        writeArtistEntryToDisk(entry)
    }

    func updateAlbumEntry(_ entry: AlbumEntry) async {
        if let idx = albumEntries.firstIndex(where: { $0.id == entry.id }) {
            albumEntries[idx] = entry
        }
        writeAlbumEntryToDisk(entry)
    }

    func applyArtistEdits(original: ArtistEntry, updated: ArtistEntry) async {
        let trimmedName = updated.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedName = trimmedName.isEmpty ? original.displayName : trimmedName
        let newCanonicalName = LibraryNormalization.normalizeArtist(resolvedName)
        let isRename =
            original.displayName != resolvedName
            || original.canonicalName != newCanonicalName

        var finalEntry = updated
        finalEntry.displayName = resolvedName
        finalEntry.canonicalName = newCanonicalName
        finalEntry.updatedAt = Date()

        guard isRename else {
            await updateArtistEntry(finalEntry)
            return
        }

        let targetArtist = artistEntries.first {
            $0.canonicalName == newCanonicalName && $0.id != original.id
        }
        let entryToPersist = mergedArtistEntry(
            preferred: finalEntry,
            fallback: targetArtist,
            canonicalName: newCanonicalName,
            displayName: resolvedName
        )
        writeArtistEntryToDisk(entryToPersist)
        if let targetArtist {
            libraryService.deleteArtistEntry(id: original.id)
            artistEntries.removeAll { $0.id == original.id }
            if let idx = artistEntries.firstIndex(where: { $0.id == targetArtist.id }) {
                artistEntries[idx] = entryToPersist
            }
        } else if let idx = artistEntries.firstIndex(where: { $0.id == original.id }) {
            artistEntries[idx] = entryToPersist
        }

        let relatedAlbums = albumEntries.filter { $0.primaryArtistCanonicalName == original.canonicalName }
        for album in relatedAlbums {
            var migratedAlbum = album
            migratedAlbum.primaryArtistCanonicalName = newCanonicalName
            migratedAlbum.primaryArtistDisplayName = resolvedName
            migratedAlbum.canonicalKey = LibraryNormalization.normalizedAlbumKey(
                album: migratedAlbum.displayTitle,
                artist: resolvedName
            )
            migratedAlbum.updatedAt = Date()

            let targetAlbum = albumEntries.first {
                $0.canonicalKey == migratedAlbum.canonicalKey && $0.id != album.id
            }
            let albumToPersist = mergedAlbumEntry(
                preferred: migratedAlbum,
                fallback: targetAlbum,
                canonicalKey: migratedAlbum.canonicalKey,
                displayTitle: migratedAlbum.displayTitle,
                primaryArtistCanonicalName: newCanonicalName,
                primaryArtistDisplayName: resolvedName
            )
            writeAlbumEntryToDisk(albumToPersist)
            if let targetAlbum {
                libraryService.deleteAlbumEntry(id: album.id)
                albumEntries.removeAll { $0.id == album.id }
                if let idx = albumEntries.firstIndex(where: { $0.id == targetAlbum.id }) {
                    albumEntries[idx] = albumToPersist
                }
            } else if let idx = albumEntries.firstIndex(where: { $0.id == album.id }) {
                albumEntries[idx] = albumToPersist
            }
        }

        let affectedTracks = allTracks.filter {
            LibraryNormalization.normalizeArtist($0.artist) == original.canonicalName
        }
        for track in affectedTracks {
            track.artist = resolvedName
        }
        _ = await persistTrackMetaOnly(affectedTracks, reason: "artistRename")
    }

    func applyAlbumEdits(original: AlbumEntry, updated: AlbumEntry) async {
        let trimmedTitle = updated.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? original.displayTitle : trimmedTitle
        let newCanonicalKey = LibraryNormalization.normalizedAlbumKey(
            album: resolvedTitle,
            artist: original.primaryArtistDisplayName
        )
        let isRename =
            original.displayTitle != resolvedTitle
            || original.canonicalKey != newCanonicalKey

        var finalEntry = updated
        finalEntry.displayTitle = resolvedTitle
        finalEntry.canonicalKey = newCanonicalKey
        finalEntry.primaryArtistCanonicalName = original.primaryArtistCanonicalName
        finalEntry.primaryArtistDisplayName = original.primaryArtistDisplayName
        finalEntry.updatedAt = Date()

        guard isRename else {
            await updateAlbumEntry(finalEntry)
            return
        }

        let targetAlbum = albumEntries.first {
            $0.canonicalKey == newCanonicalKey && $0.id != original.id
        }
        let entryToPersist = mergedAlbumEntry(
            preferred: finalEntry,
            fallback: targetAlbum,
            canonicalKey: newCanonicalKey,
            displayTitle: resolvedTitle,
            primaryArtistCanonicalName: original.primaryArtistCanonicalName,
            primaryArtistDisplayName: original.primaryArtistDisplayName
        )
        writeAlbumEntryToDisk(entryToPersist)
        if let targetAlbum {
            libraryService.deleteAlbumEntry(id: original.id)
            albumEntries.removeAll { $0.id == original.id }
            if let idx = albumEntries.firstIndex(where: { $0.id == targetAlbum.id }) {
                albumEntries[idx] = entryToPersist
            }
        } else if let idx = albumEntries.firstIndex(where: { $0.id == original.id }) {
            albumEntries[idx] = entryToPersist
        }

        let affectedTracks = allTracks.filter {
            LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
                == original.canonicalKey
        }
        for track in affectedTracks {
            track.album = resolvedTitle
        }
        _ = await persistTrackMetaOnly(affectedTracks, reason: "albumRename")
    }

    func deleteArtist(_ entry: ArtistEntry) async {
        libraryService.deleteArtistEntry(id: entry.id)
        let affectedTracks = allTracks.filter {
            LibraryNormalization.normalizeArtist($0.artist) == entry.canonicalName
        }
        let affectedAlbumKeys = Set(affectedTracks.map {
            LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
        })
        deleteTracksAndMetadata(
            tracks: affectedTracks,
            cleanupArtistCanonicalNames: [entry.canonicalName],
            cleanupAlbumKeys: affectedAlbumKeys
        )
    }

    func deleteAlbum(_ entry: AlbumEntry) async {
        libraryService.deleteAlbumEntry(id: entry.id)
        let affectedTracks = allTracks.filter {
            LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
                == entry.canonicalKey
        }
        deleteTracksAndMetadata(
            tracks: affectedTracks,
            cleanupArtistCanonicalNames: [entry.primaryArtistCanonicalName],
            cleanupAlbumKeys: [entry.canonicalKey]
        )
    }

    func updatePlaylistDescription(_ playlist: Playlist, description: String) async {
        await updatePlaylistDetails(
            playlist,
            name: playlist.name,
            description: description
        )
    }

    // MARK: - Cache Maintenance

    func clearIndexCacheAndRebuild() async {
        clearTrackIndexCache()
        for url in TrackIndexStorePaths.relatedStoreFiles where fileManager.fileExists(atPath: url.path)
        {
            try? fileManager.removeItem(at: url)
        }
        allTracks.removeAll()
        playlists.removeAll()
        runtimeArtists.removeAll()
        runtimeAlbums.removeAll()
        dedupCountByKey.removeAll()
        playlistItemAddedAtMap.removeAll()
        artistEntries.removeAll()
        albumEntries.removeAll()
        await reloadFromLibrary()
    }

    func save() async {
        // No-op for authoritative disk-backed repository.
    }

    // MARK: - Private Helpers

    private func buildTrack(from meta: ScannedTrackMeta) -> Track {
        let audioURL = LocalLibraryPaths.libraryURL(from: meta.libraryRelativePath)
        let isAvailable = fileManager.fileExists(atPath: audioURL.path)
        let persistedStats = meta.preferenceStats
            ?? meta.playCount.map { TrackPreferenceStats.fromLegacy(playCount: max($0, 0)) }
            ?? TrackPreferenceStats()

        PreferenceStatsService.shared.replaceStats(for: meta.id, with: persistedStats)

        let artworkData: Data? = meta.artworkFileName.flatMap { fileName in
            let artworkURL = meta.folderURL.appendingPathComponent(fileName)
            return try? Data(contentsOf: artworkURL)
        }

        var ttmlText: String?
        var lyricsText: String?

        if let ttmlFileName = meta.ttmlLyricsFileName {
            let ttmlURL = meta.folderURL.appendingPathComponent(ttmlFileName)
            if let text = try? String(contentsOf: ttmlURL, encoding: .utf8), !text.isEmpty {
                ttmlText = text
            }
        }

        if ttmlText == nil, let lyricsFileName = meta.lyricsFileName {
            let lyricsURL = meta.folderURL.appendingPathComponent(lyricsFileName)
            if let text = try? String(contentsOf: lyricsURL, encoding: .utf8) {
                if lyricsFileName.lowercased().hasSuffix(".ttml") {
                    ttmlText = text
                } else {
                    lyricsText = text
                }
            }
        }

        return Track(
            id: meta.id,
            title: meta.title,
            artist: meta.artist,
            album: meta.album,
            duration: meta.duration,
            addedAt: meta.addedAt,
            importedAt: meta.importedAt,
            lyricsTimeOffsetMs: meta.lyricsTimeOffsetMs,
            fileBookmarkData: Data(),
            originalFilePath: meta.originalFilePath,
            libraryRelativePath: meta.libraryRelativePath,
            availability: isAvailable ? .available : .missing,
            artworkData: artworkData,
            ttmlLyricText: ttmlText,
            lyricsText: lyricsText
        )
    }

    private func rebuildRuntimeDerivedState() {
        var dedup: [String: Int] = [:]
        var artistBucket: [String: (name: String, count: Int)] = [:]
        var albumBucket: [String: (name: String, artistName: String, count: Int)] = [:]

        for track in allTracks {
            let artistDisplay = LibraryNormalization.displayArtist(track.artist)
            let albumDisplay = LibraryNormalization.displayAlbum(track.album)

            let dedupKey = LibraryNormalization.normalizedDedupKey(
                title: track.title,
                artist: track.artist
            )
            dedup[dedupKey, default: 0] += 1

            let artistKey = LibraryNormalization.normalizeArtist(track.artist)
            var artistValue = artistBucket[artistKey] ?? (artistDisplay, 0)
            artistValue.count += 1
            if artistValue.name == LibraryNormalization.unknownArtist {
                artistValue.name = artistDisplay
            }
            artistBucket[artistKey] = artistValue

            let albumKey = LibraryNormalization.normalizedAlbumKey(
                album: track.album,
                artist: track.artist
            )
            var albumValue = albumBucket[albumKey] ?? (albumDisplay, artistDisplay, 0)
            albumValue.count += 1
            albumBucket[albumKey] = albumValue
        }

        dedupCountByKey = dedup
        runtimeArtists = artistBucket
            .map { ArtistSection(key: $0.key, name: $0.value.name, trackCount: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        runtimeAlbums = albumBucket
            .map {
                AlbumSection(
                    key: $0.key,
                    name: $0.value.name,
                    artistName: $0.value.artistName,
                    trackCount: $0.value.count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func writePlaylistToDisk(_ playlist: Playlist) {
        let itemDates = playlistItemAddedAtMap[playlist.id] ?? [:]
        libraryService.writePlaylist(playlist, itemAddedAt: itemDates)
    }

    private func writeArtistEntryToDisk(_ entry: ArtistEntry) {
        let sidecar = ArtistSidecar(
            id: entry.id,
            canonicalName: entry.canonicalName,
            displayName: entry.displayName,
            artworkFileName: entry.artworkFileName,
            description: entry.description.isEmpty ? nil : entry.description,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt
        )
        libraryService.writeArtistSidecar(sidecar, artworkData: entry.artworkData)
    }

    private func writeAlbumEntryToDisk(_ entry: AlbumEntry) {
        let sidecar = AlbumSidecar(
            id: entry.id,
            canonicalKey: entry.canonicalKey,
            displayTitle: entry.displayTitle,
            primaryArtistCanonicalName: entry.primaryArtistCanonicalName,
            artworkFileName: entry.artworkFileName,
            description: entry.description.isEmpty ? nil : entry.description,
            year: entry.year,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt
        )
        libraryService.writeAlbumSidecar(
            sidecar,
            artworkData: entry.artworkFileName != nil ? entry.artworkData : nil
        )
    }

    private func mergedArtistEntry(
        preferred: ArtistEntry,
        fallback: ArtistEntry?,
        canonicalName: String,
        displayName: String
    ) -> ArtistEntry {
        guard let fallback else {
            var merged = preferred
            merged.canonicalName = canonicalName
            merged.displayName = displayName
            return merged
        }

        return ArtistEntry(
            id: fallback.id,
            canonicalName: canonicalName,
            displayName: displayName,
            artworkFileName: preferred.artworkData != nil || preferred.artworkFileName != nil
                ? preferred.artworkFileName
                : fallback.artworkFileName,
            description: preferred.description.isEmpty ? fallback.description : preferred.description,
            artworkData: preferred.artworkData ?? fallback.artworkData,
            createdAt: min(preferred.createdAt, fallback.createdAt),
            updatedAt: Date(),
            trackCount: max(preferred.trackCount, fallback.trackCount),
            albumCount: max(preferred.albumCount, fallback.albumCount),
            totalDuration: max(preferred.totalDuration, fallback.totalDuration),
            isOrphaned: false
        )
    }

    private func mergedAlbumEntry(
        preferred: AlbumEntry,
        fallback: AlbumEntry?,
        canonicalKey: String,
        displayTitle: String,
        primaryArtistCanonicalName: String,
        primaryArtistDisplayName: String
    ) -> AlbumEntry {
        guard let fallback else {
            var merged = preferred
            merged.canonicalKey = canonicalKey
            merged.displayTitle = displayTitle
            merged.primaryArtistCanonicalName = primaryArtistCanonicalName
            merged.primaryArtistDisplayName = primaryArtistDisplayName
            return merged
        }

        return AlbumEntry(
            id: fallback.id,
            canonicalKey: canonicalKey,
            displayTitle: displayTitle,
            primaryArtistCanonicalName: primaryArtistCanonicalName,
            primaryArtistDisplayName: primaryArtistDisplayName,
            artworkFileName: preferred.artworkData != nil || preferred.artworkFileName != nil
                ? preferred.artworkFileName
                : fallback.artworkFileName,
            description: preferred.description.isEmpty ? fallback.description : preferred.description,
            year: preferred.year ?? fallback.year,
            artworkData: preferred.artworkData ?? fallback.artworkData,
            createdAt: min(preferred.createdAt, fallback.createdAt),
            updatedAt: Date(),
            trackCount: max(preferred.trackCount, fallback.trackCount),
            totalDuration: max(preferred.totalDuration, fallback.totalDuration),
            isOrphaned: false
        )
    }

    private func deleteTracksAndMetadata(
        tracks: [Track],
        cleanupArtistCanonicalNames: Set<String>,
        cleanupAlbumKeys: Set<String>
    ) {
        let uniqueTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }).values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let trackIDs = Set(uniqueTracks.map(\.id))

        if !trackIDs.isEmpty {
            allTracks.removeAll { trackIDs.contains($0.id) }

            for playlist in playlists {
                let removedTrackIDs = playlist.tracks
                    .filter { trackIDs.contains($0.id) }
                    .map(\.id)
                guard !removedTrackIDs.isEmpty else { continue }
                playlist.tracks.removeAll { trackIDs.contains($0.id) }
                var dates = playlistItemAddedAtMap[playlist.id] ?? [:]
                for trackID in removedTrackIDs {
                    dates[trackID] = nil
                }
                playlistItemAddedAtMap[playlist.id] = dates
                writePlaylistToDisk(playlist)
            }

            for track in uniqueTracks {
                libraryService.deleteTrackFiles(track)
            }
        }

        cleanupMetadataSidecars(
            impactedArtistCanonicalNames: cleanupArtistCanonicalNames,
            impactedAlbumKeys: cleanupAlbumKeys
        )

        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            libraryService: libraryService
        )
        artistEntries = artists
        albumEntries = albums
    }

    private func cleanupMetadataSidecars(
        impactedArtistCanonicalNames: Set<String>,
        impactedAlbumKeys: Set<String>
    ) {
        let liveArtistKeys = Set(allTracks.map { LibraryNormalization.normalizeArtist($0.artist) })
        let liveAlbumKeys = Set(allTracks.map {
            LibraryNormalization.normalizedAlbumKey(album: $0.album, artist: $0.artist)
        })

        for artist in artistEntries
        where impactedArtistCanonicalNames.contains(artist.canonicalName)
            && !liveArtistKeys.contains(artist.canonicalName)
        {
            libraryService.deleteArtistEntry(id: artist.id)
        }

        for album in albumEntries
        where impactedAlbumKeys.contains(album.canonicalKey)
            && !liveAlbumKeys.contains(album.canonicalKey)
        {
            libraryService.deleteAlbumEntry(id: album.id)
        }
    }

    private func persistTracks(
        _ tracks: [Track],
        label: String,
        reason: String,
        writer: (Track) -> Bool
    ) async -> LibraryTrackPersistenceResult {
        let uniqueTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }).values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        guard !uniqueTracks.isEmpty else {
            return LibraryTrackPersistenceResult(persistedTrackIDs: [], failedTrackIDs: [])
        }

        Log.info(
            "[TrackPersistenceRepository] label=\(label) reason=\(reason) start tracks=\(uniqueTracks.count)",
            category: .library
        )

        var persistedTrackIDs: [UUID] = []
        var failedTrackIDs: [UUID] = []

        for track in uniqueTracks {
            if writer(track) {
                persistedTrackIDs.append(track.id)
            } else {
                failedTrackIDs.append(track.id)
            }
        }

        if !persistedTrackIDs.isEmpty {
            _ = await refreshTracks(ids: persistedTrackIDs)
        }

        if !persistedTrackIDs.isEmpty {
            if persistedTrackIDs.count == 1, let trackID = persistedTrackIDs.first {
                changeHandler?(.trackUpdated(trackID))
            } else {
                changeHandler?(.tracksUpdated(persistedTrackIDs))
            }
        }

        Log.info(
            "[TrackPersistenceRepository] label=\(label) reason=\(reason) complete persisted=\(persistedTrackIDs.count) failed=\(failedTrackIDs.count)",
            category: .library
        )

        return LibraryTrackPersistenceResult(
            persistedTrackIDs: persistedTrackIDs,
            failedTrackIDs: failedTrackIDs
        )
    }

    /// Import-only full resource persistence for newly created track folders.
    private func persistImportedTrackResources(_ tracks: [Track], reason: String) {
        let uniqueTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }).values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        guard !uniqueTracks.isEmpty else { return }

        Log.warning(
            "[TrackPersistenceRepository] import-only full resource write reason=\(reason) tracks=\(uniqueTracks.count)",
            category: .library
        )

        for track in uniqueTracks {
            _ = libraryService.writeImportedTrackSidecar(for: track, reason: reason)
        }
    }

    private func clearTrackIndexCache() {
        guard let indexContext else { return }
        do {
            let entries = try indexContext.fetch(FetchDescriptor<TrackIndexEntry>())
            for entry in entries {
                indexContext.delete(entry)
            }
            try indexContext.save()
        } catch {
            print("⚠️ 清空索引缓存失败: \(error)")
        }
    }

    private func rebuildTrackIndexCache() {
        guard let indexContext else { return }
        clearTrackIndexCache()

        for track in allTracks {
            let entry = TrackIndexEntry(
                id: track.id,
                libraryRelativePath: track.libraryRelativePath,
                normalizedTitle: LibraryNormalization.normalizeTitle(track.title),
                normalizedArtist: LibraryNormalization.normalizeArtist(track.artist),
                duration: track.duration,
                indexedAt: Date()
            )
            indexContext.insert(entry)
        }

        do {
            try indexContext.save()
        } catch {
            print("⚠️ 重建索引缓存失败: \(error)")
        }
    }
}
