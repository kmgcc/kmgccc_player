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

    private var allTracks: [Track] = []
    private var playlists: [Playlist] = []
    private var runtimeArtists: [ArtistSection] = []
    private var runtimeAlbums: [AlbumSection] = []
    private var dedupCountByKey: [String: Int] = [:]
    private var playlistItemAddedAtMap: [UUID: [UUID: Date]] = [:]

    init(modelContext: ModelContext? = nil, libraryService: LocalLibraryService? = nil) {
        self.indexContext = modelContext
        self.libraryService = libraryService ?? LocalLibraryService.shared
        self.scanner = MusicLibraryScanner()
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
                createdAt: sidecar.createdAt,
                tracks: resolved
            )
        }

        allTracks = tracks.sorted { ($0.importedAt ?? $0.addedAt) > ($1.importedAt ?? $1.addedAt) }
        playlists = loadedPlaylists.sorted { $0.createdAt < $1.createdAt }
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
    }

    // MARK: - Track Operations

    func fetchTracks(in playlist: Playlist?) async -> [Track] {
        if let playlist { return playlist.tracks }
        return allTracks
    }

    func addTrack(_ track: Track) async {
        allTracks.append(track)
        libraryService.writeSidecar(for: track)
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
    }

    func addTracks(_ tracks: [Track]) async {
        for track in tracks {
            allTracks.append(track)
            libraryService.writeSidecar(for: track)
        }
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
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
    }

    func updateTrack(_ track: Track) async {
        libraryService.writeSidecar(for: track)
        rebuildRuntimeDerivedState()
        rebuildTrackIndexCache()
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
        playlist.name = name
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
        await reloadFromLibrary()
    }

    func save() async {
        // No-op for authoritative disk-backed repository.
    }

    // MARK: - Private Helpers

    private func buildTrack(from meta: ScannedTrackMeta) -> Track {
        let audioURL = LocalLibraryPaths.libraryURL(from: meta.libraryRelativePath)
        let isAvailable = fileManager.fileExists(atPath: audioURL.path)

        let artworkData: Data? = meta.artworkFileName.flatMap { fileName in
            let artworkURL = meta.folderURL.appendingPathComponent(fileName)
            return try? Data(contentsOf: artworkURL)
        }

        var lyricsText: String?
        var ttmlText: String?
        if let lyricsFileName = meta.lyricsFileName {
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
