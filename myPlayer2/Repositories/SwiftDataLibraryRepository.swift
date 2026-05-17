//
//  SwiftDataLibraryRepository.swift
//  myPlayer2
//
//  Authoritative data source: Music Library on disk.
//  SwiftData is used only for TrackIndexEntry cache.
//

import Darwin.Mach
import Foundation
import SwiftData

private struct PlaylistPersistenceSnapshot: Sendable {
    let playlistID: UUID
    let name: String
    let description: String
    let createdAt: Date
    let trackIDs: [UUID]
    let itemAddedAt: [UUID: Date]
}

private struct TrackDeletionCleanupPlan: Sendable {
    let reason: String
    let deletedTrackIDs: [UUID]
    let playlistSnapshots: [PlaylistPersistenceSnapshot]
    let trackFolderIDs: [UUID]
    let artistEntryIDsToDelete: [UUID]
    let albumEntryIDsToDelete: [UUID]
}

private struct TrackDeletionMemorySnapshot {
    let physicalFootprintBytes: UInt64

    static func capture() -> TrackDeletionMemorySnapshot {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<natural_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    rebound,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else {
            return TrackDeletionMemorySnapshot(physicalFootprintBytes: 0)
        }
        return TrackDeletionMemorySnapshot(physicalFootprintBytes: UInt64(info.phys_footprint))
    }

    var megabytesText: String {
        String(format: "%.1f", Double(physicalFootprintBytes) / 1_048_576)
    }
}

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

        let snapshot = await Task.detached { @Sendable in
            LibraryDiskScanner().scanAll()
        }.value

        let tracks = snapshot.trackMetas.map { buildTrack(from: $0) }
        let tracksById = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        let loadedPlaylists: [Playlist] = snapshot.playlistSidecars.map { sidecar in
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
            artistSidecars: snapshot.artistSidecars,
            albumSidecars: snapshot.albumSidecars,
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
        let (artistSidecars, albumSidecars) = await Task.detached { @Sendable in
            let scanner = LibraryDiskScanner()
            return (scanner.loadArtistSidecars(), scanner.loadAlbumSidecars())
        }.value
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            artistSidecars: artistSidecars,
            albumSidecars: albumSidecars,
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
        let (artistSidecars, albumSidecars) = await Task.detached { @Sendable in
            let scanner = LibraryDiskScanner()
            return (scanner.loadArtistSidecars(), scanner.loadAlbumSidecars())
        }.value
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            artistSidecars: artistSidecars,
            albumSidecars: albumSidecars,
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
        await deleteTracks([track])
    }

    func deleteTracks(_ tracks: [Track]) async {
        let uniqueTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }).values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let impactedArtists = Set(uniqueTracks.map {
            LibraryNormalization.artistCanonicalNames($0.artist)
        }.flatMap { $0 })
        let impactedAlbums = Set(uniqueTracks.map(\.albumGroupKey))
        await deleteTracksAndMetadata(
            tracks: uniqueTracks,
            cleanupArtistCanonicalNames: impactedArtists,
            cleanupAlbumKeys: impactedAlbums,
            reason: "trackDelete"
        )
    }

    func persistTrackMetaOnly(_ track: Track, reason: String) async {
        _ = await persistTrackMetaOnly([track], reason: reason)
    }

    func persistTrackMetaOnly(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta-only",
            reason: reason,
            mode: .metaOnly
        )
    }

    func persistTrackMetaAndLyrics(_ track: Track, reason: String) async {
        _ = await persistTrackMetaAndLyrics([track], reason: reason)
    }

    func persistTrackMetaAndLyrics(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta+lyrics",
            reason: reason,
            mode: .metaAndLyrics
        )
    }

    func persistTrackMetaAndArtwork(_ track: Track, reason: String) async {
        _ = await persistTrackMetaAndArtwork([track], reason: reason)
    }

    func persistTrackMetaAndArtwork(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta+artwork",
            reason: reason,
            mode: .metaAndArtwork
        )
    }

    func persistTrackMetaLyricsAndArtwork(_ track: Track, reason: String) async {
        _ = await persistTrackMetaLyricsAndArtwork([track], reason: reason)
    }

    func persistTrackMetaLyricsAndArtwork(_ tracks: [Track], reason: String) async -> LibraryTrackPersistenceResult {
        await persistTracks(
            tracks,
            label: "meta+lyrics+artwork",
            reason: reason,
            mode: .metaLyricsAndArtwork
        )
    }

    func refreshTracks(ids: [UUID]) async -> [Track] {
        let uniqueIDs = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }
        guard !uniqueIDs.isEmpty else { return [] }

        Log.info(
            "[ImportEnrichmentReload] reload requested for track IDs: \(uniqueIDs.map(\.uuidString))",
            category: .library
        )

        let metas = await Task.detached { @Sendable in
            MusicLibraryScanner().scanTracks(ids: uniqueIDs)
        }.value
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
        let (artistSidecars, albumSidecars) = await Task.detached { @Sendable in
            let scanner = LibraryDiskScanner()
            return (scanner.loadArtistSidecars(), scanner.loadAlbumSidecars())
        }.value
        let (artists, albums) = metadataSync.sync(
            derivedArtists: runtimeArtists,
            derivedAlbums: runtimeAlbums,
            allTracks: allTracks,
            artistSidecars: artistSidecars,
            albumSidecars: albumSidecars,
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
        let canonicalName = entry.canonicalName
        let displayName = entry.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? LibraryNormalization.displayArtist(entry.displayName)
            : entry.displayName
        let target = artistEntries.first {
            $0.canonicalName == canonicalName && $0.id != entry.id
        }
        let entryToPersist = mergedArtistEntry(
            preferred: entry,
            fallback: target,
            canonicalName: canonicalName,
            displayName: displayName
        )

        writeArtistEntryToDisk(entryToPersist)

        if let target {
            libraryService.deleteArtistEntry(id: entry.id)
            artistEntries.removeAll { $0.id == entry.id }
            if let idx = artistEntries.firstIndex(where: { $0.id == target.id }) {
                artistEntries[idx] = entryToPersist
            } else {
                artistEntries.append(entryToPersist)
            }
        } else if let idx = artistEntries.firstIndex(where: { $0.id == entry.id }) {
            artistEntries[idx] = entryToPersist
        } else {
            artistEntries.append(entryToPersist)
        }
    }

    func updateAlbumEntry(_ entry: AlbumEntry) async {
        let target = albumEntries.first {
            $0.canonicalKey == entry.canonicalKey && $0.id != entry.id
        }
        let entryToPersist = mergedAlbumEntry(
            preferred: entry,
            fallback: target,
            canonicalKey: entry.canonicalKey,
            displayTitle: entry.displayTitle,
            primaryArtistCanonicalName: entry.primaryArtistCanonicalName,
            primaryArtistDisplayName: entry.primaryArtistDisplayName
        )

        writeAlbumEntryToDisk(entryToPersist)

        if let target {
            libraryService.deleteAlbumEntry(id: entry.id)
            albumEntries.removeAll { $0.id == entry.id }
            if let idx = albumEntries.firstIndex(where: { $0.id == target.id }) {
                albumEntries[idx] = entryToPersist
            } else {
                albumEntries.append(entryToPersist)
            }
        } else if let idx = albumEntries.firstIndex(where: { $0.id == entry.id }) {
            albumEntries[idx] = entryToPersist
        } else {
            albumEntries.append(entryToPersist)
        }
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
            migratedAlbum.canonicalKey = LibraryNormalization.renamedArtistAlbumKey(
                existingKey: migratedAlbum.canonicalKey,
                newArtistCanonicalName: newCanonicalName
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
            LibraryNormalization.containsArtist(original.canonicalName, in: $0.artist)
        }
        for track in affectedTracks {
            track.artist = LibraryNormalization.replacingArtistComponent(
                in: track.artist,
                matching: original.canonicalName,
                with: resolvedName
            )
        }
        _ = await persistTrackMetaOnly(affectedTracks, reason: "artistRename")
    }

    func applyAlbumEdits(original: AlbumEntry, updated: AlbumEntry) async {
        let trimmedTitle = updated.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = trimmedTitle.isEmpty ? original.displayTitle : trimmedTitle
        let newCanonicalKey = LibraryNormalization.retitledAlbumKey(
            existingKey: original.canonicalKey,
            newAlbumTitle: resolvedTitle
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
            $0.albumGroupKey == original.canonicalKey
        }
        for track in affectedTracks {
            track.album = resolvedTitle
        }
        _ = await persistTrackMetaOnly(affectedTracks, reason: "albumRename")
    }

    func deleteArtist(_ entry: ArtistEntry) async {
        let affectedTracks = allTracks.filter {
            LibraryNormalization.containsArtist(entry.canonicalName, in: $0.artist)
        }
        let affectedAlbumKeys = Set(affectedTracks.map {
            $0.albumGroupKey
        })
        await deleteTracksAndMetadata(
            tracks: affectedTracks,
            cleanupArtistCanonicalNames: [entry.canonicalName],
            cleanupAlbumKeys: affectedAlbumKeys,
            forcedArtistDeletionIDs: [entry.id],
            reason: "artistDelete"
        )
    }

    func deleteAlbum(_ entry: AlbumEntry) async {
        let affectedTracks = allTracks.filter {
            $0.albumGroupKey == entry.canonicalKey
        }
        await deleteTracksAndMetadata(
            tracks: affectedTracks,
            cleanupArtistCanonicalNames: [entry.primaryArtistCanonicalName],
            cleanupAlbumKeys: [entry.canonicalKey],
            forcedAlbumDeletionIDs: [entry.id],
            reason: "albumDelete"
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

        let track = Track(
            id: meta.id,
            title: meta.title,
            artist: meta.artist,
            album: meta.album,
            albumArtist: meta.albumArtist,
            userDescription: meta.description,
            genreTags: meta.genreTags,
            language: meta.language,
            labelOrCompany: meta.labelOrCompany,
            releaseDate: meta.releaseDate,
            qqMusicSongMid: meta.qqMusicSongMid,
            metadataSource: meta.metadataSource,
            metadataFetchedAt: meta.metadataFetchedAt,
            metadataConfidence: meta.metadataConfidence,
            duration: meta.duration,
            addedAt: meta.addedAt,
            importedAt: meta.importedAt,
            lyricsTimeOffsetMs: meta.lyricsTimeOffsetMs,
            fileBookmarkData: Data(),
            originalFilePath: meta.originalFilePath,
            libraryRelativePath: meta.libraryRelativePath,
            availability: isAvailable ? .available : .missing,
            artworkData: nil,
            ttmlLyricText: nil,
            lyricsText: nil
        )

        track.libraryRootSnapshot = LocalLibraryPaths.libraryRootURL.path
        track.audioFileName = meta.audioFileName
        track.artworkFileName = meta.artworkFileName
        track.lyricsFileName = meta.lyricsFileName
        track.ttmlLyricsFileName = meta.ttmlLyricsFileName

        return track
    }

    private func rebuildRuntimeDerivedState() {
        var dedup: [String: Int] = [:]
        var artistBucket: [String: (name: String, count: Int)] = [:]

        for track in allTracks {
            let dedupKey = LibraryNormalization.normalizedDedupKey(
                title: track.title,
                artist: track.artist
            )
            dedup[dedupKey, default: 0] += 1

            for component in LibraryNormalization.artistComponents(track.artist) {
                var artistValue = artistBucket[component.canonicalName] ?? (component.displayName, 0)
                artistValue.count += 1
                if artistValue.name == LibraryNormalization.unknownArtist {
                    artistValue.name = component.displayName
                }
                artistBucket[component.canonicalName] = artistValue
            }
        }

        dedupCountByKey = dedup
        runtimeArtists = artistBucket
            .map { ArtistSection(key: $0.key, name: $0.value.name, trackCount: $0.value.count) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let albumGrouping = LibraryNormalization.buildAlbumGrouping(tracks: allTracks)
        for track in allTracks {
            track.albumGroupKey = albumGrouping.albumKeyByTrackID[track.id]
                ?? LibraryNormalization.normalizedAlbumKey(album: track.album)
        }
        runtimeAlbums = albumGrouping.sections
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
            genreTags: entry.genreTags,
            region: entry.region.isEmpty ? nil : entry.region,
            foreignName: entry.foreignName.isEmpty ? nil : entry.foreignName,
            qqMusicSingerMid: entry.qqMusicSingerMid,
            metadataSource: entry.metadataSource,
            metadataFetchedAt: entry.metadataFetchedAt,
            metadataConfidence: entry.metadataConfidence,
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
            primaryArtistDisplayName: entry.primaryArtistDisplayName.isEmpty ? nil : entry.primaryArtistDisplayName,
            artworkFileName: entry.artworkFileName,
            description: entry.description.isEmpty ? nil : entry.description,
            year: entry.year,
            releaseYear: entry.releaseYear ?? entry.year,
            releaseDate: entry.releaseDate,
            albumType: entry.albumType.isEmpty ? nil : entry.albumType,
            genreTags: entry.genreTags,
            language: entry.language.isEmpty ? nil : entry.language,
            labelOrCompany: entry.labelOrCompany.isEmpty ? nil : entry.labelOrCompany,
            qqMusicAlbumMid: entry.qqMusicAlbumMid,
            metadataSource: entry.metadataSource,
            metadataFetchedAt: entry.metadataFetchedAt,
            metadataConfidence: entry.metadataConfidence,
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
            artworkFileName: preferred.artworkFileName ?? fallback.artworkFileName,
            description: preferred.description.isEmpty ? fallback.description : preferred.description,
            genreTags: preferred.genreTags.isEmpty ? fallback.genreTags : preferred.genreTags,
            region: preferred.region.isEmpty ? fallback.region : preferred.region,
            foreignName: preferred.foreignName.isEmpty ? fallback.foreignName : preferred.foreignName,
            qqMusicSingerMid: preferred.qqMusicSingerMid ?? fallback.qqMusicSingerMid,
            metadataSource: preferred.metadataSource ?? fallback.metadataSource,
            metadataFetchedAt: preferred.metadataFetchedAt ?? fallback.metadataFetchedAt,
            metadataConfidence: preferred.metadataConfidence ?? fallback.metadataConfidence,
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
            artworkFileName: preferred.artworkFileName ?? fallback.artworkFileName,
            description: preferred.description.isEmpty ? fallback.description : preferred.description,
            year: preferred.year ?? fallback.year,
            releaseYear: preferred.releaseYear ?? fallback.releaseYear ?? preferred.year ?? fallback.year,
            releaseDate: preferred.releaseDate ?? fallback.releaseDate,
            albumType: preferred.albumType.isEmpty ? fallback.albumType : preferred.albumType,
            genreTags: preferred.genreTags.isEmpty ? fallback.genreTags : preferred.genreTags,
            language: preferred.language.isEmpty ? fallback.language : preferred.language,
            labelOrCompany: preferred.labelOrCompany.isEmpty ? fallback.labelOrCompany : preferred.labelOrCompany,
            qqMusicAlbumMid: preferred.qqMusicAlbumMid ?? fallback.qqMusicAlbumMid,
            metadataSource: preferred.metadataSource ?? fallback.metadataSource,
            metadataFetchedAt: preferred.metadataFetchedAt ?? fallback.metadataFetchedAt,
            metadataConfidence: preferred.metadataConfidence ?? fallback.metadataConfidence,
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
        cleanupAlbumKeys: Set<String>,
        forcedArtistDeletionIDs: Set<UUID> = [],
        forcedAlbumDeletionIDs: Set<UUID> = [],
        reason: String
    ) async {
        let startedAt = ContinuousClock.now
        let memoryBefore = TrackDeletionMemorySnapshot.capture()
        let uniqueTracks = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) }).values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        let deletedTrackIDs = uniqueTracks.map(\.id)
        let deletedTrackIDSet = Set(deletedTrackIDs)

        Log.info(
            "[LibraryDelete] reason=\(reason) start tracks=\(deletedTrackIDs.count) memoryMB=\(memoryBefore.megabytesText)",
            category: .library
        )

        var playlistSnapshots: [PlaylistPersistenceSnapshot] = []
        if !deletedTrackIDSet.isEmpty {
            allTracks.removeAll { deletedTrackIDSet.contains($0.id) }

            for playlist in playlists {
                let removedTrackIDs = playlist.tracks
                    .filter { deletedTrackIDSet.contains($0.id) }
                    .map(\.id)
                guard !removedTrackIDs.isEmpty else { continue }

                playlist.tracks.removeAll { deletedTrackIDSet.contains($0.id) }
                var dates = playlistItemAddedAtMap[playlist.id] ?? [:]
                for trackID in removedTrackIDs {
                    dates[trackID] = nil
                }
                playlistItemAddedAtMap[playlist.id] = dates
                playlistSnapshots.append(playlistPersistenceSnapshot(for: playlist))
            }

            for track in uniqueTracks {
                track.releaseTransientMediaResources()
            }
            PreferenceStatsService.shared.removeStats(for: deletedTrackIDSet)
            deleteTrackIndexEntries(ids: deletedTrackIDs)
        }

        rebuildRuntimeDerivedState()
        let metadataCleanup = reconcileMetadataEntriesAfterDeletion(
            impactedArtistCanonicalNames: cleanupArtistCanonicalNames,
            impactedAlbumKeys: cleanupAlbumKeys,
            forcedArtistDeletionIDs: forcedArtistDeletionIDs,
            forcedAlbumDeletionIDs: forcedAlbumDeletionIDs
        )

        let afterMainMutation = TrackDeletionMemorySnapshot.capture()
        Log.info(
            "[LibraryDelete] reason=\(reason) mainStageComplete tracks=\(deletedTrackIDs.count) playlistWrites=\(playlistSnapshots.count) artistDeletes=\(metadataCleanup.artistEntryIDsToDelete.count) albumDeletes=\(metadataCleanup.albumEntryIDsToDelete.count) memoryMB=\(afterMainMutation.megabytesText)",
            category: .library
        )

        if !deletedTrackIDs.isEmpty {
            changeHandler?(.tracksDeleted(deletedTrackIDs))
        }

        let cleanupPlan = TrackDeletionCleanupPlan(
            reason: reason,
            deletedTrackIDs: deletedTrackIDs,
            playlistSnapshots: playlistSnapshots,
            trackFolderIDs: deletedTrackIDs,
            artistEntryIDsToDelete: metadataCleanup.artistEntryIDsToDelete,
            albumEntryIDsToDelete: metadataCleanup.albumEntryIDsToDelete
        )
        let failedFolderDeletes = await performBackgroundTrackDeletionCleanup(cleanupPlan)

        await ArtworkLoader.clearMemoryCache()
        await ArtworkDerivativeCacheStore.shared.clearMemory()
        await ArtworkAssetStore.shared.clearTrackDeletionResidue()
        await PlaylistArtworkPipeline.shared.clearMemory()

        let memoryAfterCleanup = TrackDeletionMemorySnapshot.capture()
        let elapsed = startedAt.duration(to: ContinuousClock.now)
        let elapsedMs = Double(elapsed.components.seconds) * 1000
            + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000

        Log.info(
            "[LibraryDelete] reason=\(reason) complete tracks=\(deletedTrackIDs.count) totalMs=\(String(format: "%.1f", elapsedMs)) failedFolderDeletes=\(failedFolderDeletes) memoryBeforeMB=\(memoryBefore.megabytesText) memoryAfterMainMB=\(afterMainMutation.megabytesText) memoryAfterCleanupMB=\(memoryAfterCleanup.megabytesText)",
            category: .library
        )
    }

    private func playlistPersistenceSnapshot(for playlist: Playlist) -> PlaylistPersistenceSnapshot {
        PlaylistPersistenceSnapshot(
            playlistID: playlist.id,
            name: playlist.name,
            description: playlist.userDescription,
            createdAt: playlist.createdAt,
            trackIDs: playlist.tracks.map(\.id),
            itemAddedAt: playlistItemAddedAtMap[playlist.id] ?? [:]
        )
    }

    private func reconcileMetadataEntriesAfterDeletion(
        impactedArtistCanonicalNames: Set<String>,
        impactedAlbumKeys: Set<String>,
        forcedArtistDeletionIDs: Set<UUID>,
        forcedAlbumDeletionIDs: Set<UUID>
    ) -> (artistEntryIDsToDelete: [UUID], albumEntryIDsToDelete: [UUID]) {
        let artistSectionByKey = Dictionary(uniqueKeysWithValues: runtimeArtists.map { ($0.key, $0) })
        let albumSectionByKey = Dictionary(uniqueKeysWithValues: runtimeAlbums.map { ($0.key, $0) })
        let tracksByAlbumKey = Dictionary(grouping: allTracks, by: \.albumGroupKey)

        var albumKeysByArtist: [String: Set<String>] = [:]
        var totalDurationByArtist: [String: Double] = [:]
        for track in allTracks {
            for artistKey in LibraryNormalization.artistCanonicalNames(track.artist) {
                albumKeysByArtist[artistKey, default: []].insert(track.albumGroupKey)
                totalDurationByArtist[artistKey, default: 0] += track.duration
            }
        }

        var artistEntryIDsToDelete: [UUID] = []
        var nextArtistEntries: [ArtistEntry] = []
        nextArtistEntries.reserveCapacity(artistEntries.count)

        for var entry in artistEntries {
            if forcedArtistDeletionIDs.contains(entry.id) {
                artistEntryIDsToDelete.append(entry.id)
                continue
            }

            if let section = artistSectionByKey[entry.canonicalName] {
                entry.displayName = section.name
                entry.trackCount = section.trackCount
                entry.albumCount = albumKeysByArtist[entry.canonicalName]?.count ?? 0
                entry.totalDuration = totalDurationByArtist[entry.canonicalName] ?? 0
                entry.isOrphaned = false
                nextArtistEntries.append(entry)
                continue
            }

            if impactedArtistCanonicalNames.contains(entry.canonicalName) {
                if hasUserContent(entry) {
                    entry.trackCount = 0
                    entry.albumCount = 0
                    entry.totalDuration = 0
                    entry.isOrphaned = true
                    nextArtistEntries.append(entry)
                } else {
                    artistEntryIDsToDelete.append(entry.id)
                }
                continue
            }

            nextArtistEntries.append(entry)
        }

        var albumEntryIDsToDelete: [UUID] = []
        var nextAlbumEntries: [AlbumEntry] = []
        nextAlbumEntries.reserveCapacity(albumEntries.count)

        for var entry in albumEntries {
            if forcedAlbumDeletionIDs.contains(entry.id) {
                albumEntryIDsToDelete.append(entry.id)
                continue
            }

            if let section = albumSectionByKey[entry.canonicalKey] {
                let matchingTracks = tracksByAlbumKey[entry.canonicalKey] ?? []
                entry.displayTitle = section.name
                entry.primaryArtistCanonicalName = section.artistCanonicalName
                entry.primaryArtistDisplayName = section.artistName
                entry.trackCount = section.trackCount
                entry.totalDuration = matchingTracks.reduce(0) { $0 + $1.duration }
                entry.isOrphaned = false
                if entry.artworkFileName == nil {
                    entry.artworkData = matchingTracks.first(where: { $0.artworkData != nil })?.artworkData
                        ?? matchingTracks.first?.artworkData
                }
                nextAlbumEntries.append(entry)
                continue
            }

            if impactedAlbumKeys.contains(entry.canonicalKey) {
                if hasUserContent(entry) {
                    entry.trackCount = 0
                    entry.totalDuration = 0
                    entry.isOrphaned = true
                    if entry.artworkFileName == nil {
                        entry.artworkData = nil
                    }
                    nextAlbumEntries.append(entry)
                } else {
                    albumEntryIDsToDelete.append(entry.id)
                }
                continue
            }

            nextAlbumEntries.append(entry)
        }

        artistEntries = nextArtistEntries.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        albumEntries = nextAlbumEntries.sorted {
            $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending
        }

        return (
            artistEntryIDsToDelete: artistEntryIDsToDelete.sorted { $0.uuidString < $1.uuidString },
            albumEntryIDsToDelete: albumEntryIDsToDelete.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private func hasUserContent(_ entry: ArtistEntry) -> Bool {
        !entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.artworkFileName != nil
            || !entry.genreTags.isEmpty
            || !entry.region.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !entry.foreignName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.qqMusicSingerMid != nil
            || entry.metadataSource != nil
    }

    private func hasUserContent(_ entry: AlbumEntry) -> Bool {
        !entry.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.artworkFileName != nil
            || entry.year != nil
            || entry.releaseYear != nil
            || entry.releaseDate != nil
            || !entry.albumType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !entry.genreTags.isEmpty
            || !entry.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !entry.labelOrCompany.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || entry.qqMusicAlbumMid != nil
            || entry.metadataSource != nil
    }

    private func performBackgroundTrackDeletionCleanup(_ cleanupPlan: TrackDeletionCleanupPlan) async -> Int {
        await withCheckedContinuation { continuation in
            let libraryService = self.libraryService
            DispatchQueue.global(qos: .utility).async {
                libraryService.suppressMonitorEvents(for: 3.0)

                for snapshot in cleanupPlan.playlistSnapshots {
                    autoreleasepool {
                        libraryService.writePlaylistSidecar(
                            playlistID: snapshot.playlistID,
                            name: snapshot.name,
                            description: snapshot.description,
                            createdAt: snapshot.createdAt,
                            trackIDs: snapshot.trackIDs,
                            itemAddedAt: snapshot.itemAddedAt
                        )
                    }
                }

                var failedFolderDeletes = 0
                for trackID in cleanupPlan.trackFolderIDs {
                    autoreleasepool {
                        if !libraryService.deleteTrackFolder(trackID: trackID) {
                            failedFolderDeletes += 1
                        }
                    }
                }

                for artistID in cleanupPlan.artistEntryIDsToDelete {
                    libraryService.deleteArtistEntry(id: artistID)
                }

                for albumID in cleanupPlan.albumEntryIDsToDelete {
                    libraryService.deleteAlbumEntry(id: albumID)
                }

                Log.info(
                    "[LibraryDelete] reason=\(cleanupPlan.reason) backgroundStageComplete tracks=\(cleanupPlan.deletedTrackIDs.count) failedFolderDeletes=\(failedFolderDeletes) onMainThread=\(Thread.isMainThread)",
                    category: .library
                )
                continuation.resume(returning: failedFolderDeletes)
            }
        }
    }

    private func applyPersistenceReferences(_ results: [TrackPersistenceWriteResult]) {
        let referencesByTrackID = Dictionary(
            uniqueKeysWithValues: results.compactMap { result -> (UUID, TrackPersistenceReferences)? in
                guard let references = result.references else { return nil }
                return (result.trackID, references)
            }
        )
        guard !referencesByTrackID.isEmpty else { return }

        func apply(_ references: TrackPersistenceReferences, to track: Track) {
            track.artworkFileName = references.artworkFileName
            track.lyricsFileName = references.lyricsFileName
            track.ttmlLyricsFileName = references.ttmlLyricsFileName
        }

        for track in allTracks {
            if let references = referencesByTrackID[track.id] {
                apply(references, to: track)
            }
        }

        for playlist in playlists {
            for track in playlist.tracks {
                if let references = referencesByTrackID[track.id] {
                    apply(references, to: track)
                }
            }
        }
    }

    private func persistTracks(
        _ tracks: [Track],
        label: String,
        reason: String,
        mode: TrackPersistenceAssetMode
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

        let startedAt = ProcessInfo.processInfo.systemUptime
        let statsByTrackID = PreferenceStatsService.shared.getStats(for: uniqueTracks.map(\.id))
        let snapshots = uniqueTracks.map { track in
            TrackPersistenceSnapshot(
                track: track,
                preferenceStats: statsByTrackID[track.id] ?? TrackPreferenceStats()
            )
        }

        libraryService.suppressMonitorEvents(
            for: min(10.0, max(1.5, Double(uniqueTracks.count) * 0.15 + 1.5))
        )

        let results = await Task.detached(priority: .utility) { @Sendable in
            snapshots.map { snapshot in
                autoreleasepool {
                    LocalLibraryService.persistTrackSnapshotOnBackground(
                        snapshot,
                        mode: mode,
                        reason: reason
                    )
                }
            }
        }.value

        let persistedResults = results.filter(\.succeeded)
        let persistedTrackIDs = persistedResults.map(\.trackID)
        let persistedTrackIDSet = Set(persistedTrackIDs)
        let failedTrackIDs = results.filter { !$0.succeeded }.map(\.trackID)

        if !persistedResults.isEmpty {
            applyPersistenceReferences(persistedResults)
            rebuildRuntimeDerivedState()
            upsertTrackIndexEntries(for: allTracks.filter { persistedTrackIDSet.contains($0.id) })
        }

        if !persistedTrackIDs.isEmpty {
            if persistedTrackIDs.count == 1, let trackID = persistedTrackIDs.first {
                changeHandler?(.trackUpdated(trackID))
            } else {
                changeHandler?(.tracksUpdated(persistedTrackIDs))
            }
        }

        Log.info(
            "[TrackPersistenceRepository] label=\(label) reason=\(reason) complete persisted=\(persistedTrackIDs.count) failed=\(failedTrackIDs.count) ms=\(String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - startedAt) * 1000))",
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
            autoreleasepool {
                _ = libraryService.writeImportedTrackSidecar(for: track, reason: reason)
            }
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

    private func upsertTrackIndexEntries(for tracks: [Track]) {
        guard let indexContext, !tracks.isEmpty else { return }

        do {
            for track in tracks {
                let trackID = track.id
                let descriptor = FetchDescriptor<TrackIndexEntry>(
                    predicate: #Predicate<TrackIndexEntry> { entry in
                        entry.id == trackID
                    }
                )
                let existingEntries = try indexContext.fetch(descriptor)
                for entry in existingEntries {
                    indexContext.delete(entry)
                }

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
            try indexContext.save()
        } catch {
            print("⚠️ 更新索引缓存条目失败: \(error)")
        }
    }

    private func deleteTrackIndexEntries(ids: [UUID]) {
        guard let indexContext else { return }
        let idSet = Set(ids)
        guard !idSet.isEmpty else { return }

        do {
            let entries = try indexContext.fetch(FetchDescriptor<TrackIndexEntry>())
            for entry in entries where idSet.contains(entry.id) {
                indexContext.delete(entry)
            }
            try indexContext.save()
        } catch {
            print("⚠️ 删除索引缓存条目失败: \(error)")
        }
    }
}
