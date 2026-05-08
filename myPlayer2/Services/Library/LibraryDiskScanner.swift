//
//  LibraryDiskScanner.swift
//  myPlayer2
//
//  Sendable background disk scanner. Returns pure-data snapshot.
//  All FileManager I/O happens off-MainActor.
//

import Foundation

nonisolated struct LibraryDiskSnapshot: Sendable {
    let trackMetas: [ScannedTrackMeta]
    let playlistSidecars: [PlaylistSidecar]
    let artistSidecars: [(sidecar: ArtistSidecar, folderURL: URL)]
    let albumSidecars: [(sidecar: AlbumSidecar, folderURL: URL)]
}

nonisolated struct LibraryDiskScanner: Sendable {
    private static let manifestFileName = ".kmgccc-library-manifest.json"
    private static let manifestSchemaVersion = 1

    func scanAll() -> LibraryDiskSnapshot {
        scanIncremental()
    }

    func scanIncremental() -> LibraryDiskSnapshot {
        let start = Date()
        let rootURL = LocalLibraryPaths.libraryRootURL
        let manifestLoad = loadManifest(at: rootURL.appendingPathComponent(Self.manifestFileName))
        let previousManifest = manifestLoad.manifest
        let now = Date()

        let tracks = scanTracks(using: previousManifest, rootURL: rootURL, now: now)
        let playlists = scanPlaylists(using: previousManifest, rootURL: rootURL, now: now)
        let artists = scanArtists(using: previousManifest, rootURL: rootURL, now: now)
        let albums = scanAlbums(using: previousManifest, rootURL: rootURL, now: now)

        let snapshot = LibraryDiskSnapshot(
            trackMetas: tracks.values,
            playlistSidecars: playlists.values,
            artistSidecars: artists.values,
            albumSidecars: albums.values
        )

        let newManifest = LibraryManifest(
            schemaVersion: Self.manifestSchemaVersion,
            generatedAt: now,
            tracks: tracks.manifestEntries,
            playlists: playlists.manifestEntries,
            artists: artists.manifestEntries,
            albums: albums.manifestEntries
        )
        writeManifest(newManifest, at: rootURL.appendingPathComponent(Self.manifestFileName), rootURL: rootURL)

        let elapsed = Date().timeIntervalSince(start)
        logSummary(kind: "tracks", stats: tracks.stats)
        logSummary(kind: "playlists", stats: playlists.stats)
        logSummary(kind: "artists", stats: artists.stats)
        logSummary(kind: "albums", stats: albums.stats)
        Log.info(
            "[LibraryIncrementalScan] elapsed=\(String(format: "%.2f", elapsed))s manifest=\(manifestLoad.status)",
            category: .library
        )

        return snapshot
    }

    func scanTracksOnly() -> [ScannedTrackMeta] {
        scanTracks(using: loadManifestForActiveRoot(), rootURL: LocalLibraryPaths.libraryRootURL, now: Date()).values
    }

    // MARK: - Tracks

    private func scanTracks(
        using manifest: LibraryManifest?,
        rootURL: URL,
        now: Date
    ) -> ScanResult<ScannedTrackMeta, ManifestTrackEntry> {
        let fileManager = FileManager()
        let scanner = MusicLibraryScanner()
        let folders = directDirectories(at: LocalLibraryPaths.tracksRootURL)
        var values: [ScannedTrackMeta] = []
        var manifestEntries: [String: ManifestTrackEntry] = [:]
        var cached = 0
        var rescanned = 0
        var seen = Set<String>()

        for folderURL in folders {
            let folderRelativePath = "Tracks/\(folderURL.lastPathComponent)"
            let metaRelativePath = "\(folderRelativePath)/meta.json"
            seen.insert(folderRelativePath)

            guard let fingerprint = fingerprint(for: rootURL.appendingPathComponent(metaRelativePath)) else {
                if fileManager.fileExists(atPath: folderURL.path) {
                    Log.warning(
                        "[LibraryIncrementalScan] skipped track missing meta: \(folderRelativePath)",
                        category: .library
                    )
                }
                continue
            }

            if let entry = manifest?.tracks[folderRelativePath],
               entry.fingerprint.matches(fingerprint),
               let meta = entry.cachedMeta.makeScannedMeta(rootURL: rootURL) {
                values.append(meta)
                manifestEntries[folderRelativePath] = entry.updatingLastScannedAt(now)
                cached += 1
                continue
            }

            guard let meta = scanner.scanTrackFolder(folderURL) else {
                Log.warning(
                    "[LibraryIncrementalScan] skipped damaged track meta: \(metaRelativePath)",
                    category: .library
                )
                continue
            }

            values.append(meta)
            manifestEntries[folderRelativePath] = ManifestTrackEntry(
                relativePath: folderRelativePath,
                modifiedAt: fingerprint.modifiedAt,
                fileSize: fingerprint.fileSize,
                lastScannedAt: now,
                cachedMeta: CachedScannedTrackMeta(meta)
            )
            rescanned += 1
        }

        let removed = max(0, (manifest?.tracks.keys.filter { !seen.contains($0) }.count) ?? 0)
        return ScanResult(
            values: values,
            manifestEntries: manifestEntries,
            stats: ScanStats(total: values.count, cached: cached, rescanned: rescanned, removed: removed)
        )
    }

    // MARK: - Playlist Sidecars

    func loadPlaylistSidecars() -> [PlaylistSidecar] {
        scanPlaylists(using: loadManifestForActiveRoot(), rootURL: LocalLibraryPaths.libraryRootURL, now: Date()).values
    }

    private func scanPlaylists(
        using manifest: LibraryManifest?,
        rootURL: URL,
        now: Date
    ) -> ScanResult<PlaylistSidecar, ManifestSidecarEntry<PlaylistSidecar>> {
        let decoder = makeDecoder()
        let files = directFiles(at: LocalLibraryPaths.playlistsRootURL)
            .filter { $0.pathExtension.lowercased() == "json" }

        return scanJSONSidecars(
            files: files,
            rootURL: rootURL,
            sectionName: "playlist",
            previousEntries: manifest?.playlists ?? [:],
            now: now
        ) { data in
            try decoder.decode(PlaylistSidecar.self, from: data)
        }
        .mappingValues { sidecar, _ in
            sidecar
        }
    }

    // MARK: - Artist Sidecars

    func loadArtistSidecars() -> [(sidecar: ArtistSidecar, folderURL: URL)] {
        scanArtists(using: loadManifestForActiveRoot(), rootURL: LocalLibraryPaths.libraryRootURL, now: Date()).values
    }

    private func scanArtists(
        using manifest: LibraryManifest?,
        rootURL: URL,
        now: Date
    ) -> ScanResult<(sidecar: ArtistSidecar, folderURL: URL), ManifestSidecarEntry<ArtistSidecar>> {
        let decoder = makeDecoder()
        let files = directDirectories(at: LocalLibraryPaths.artistsRootURL)
            .map { $0.appendingPathComponent("meta.json") }

        return scanJSONSidecars(
            files: files,
            rootURL: rootURL,
            sectionName: "artist",
            previousEntries: manifest?.artists ?? [:],
            now: now
        ) { data in
            try decoder.decode(ArtistSidecar.self, from: data)
        }
        .mappingValues { sidecar, fileURL in
            (sidecar, fileURL.deletingLastPathComponent())
        }
    }

    // MARK: - Album Sidecars

    func loadAlbumSidecars() -> [(sidecar: AlbumSidecar, folderURL: URL)] {
        scanAlbums(using: loadManifestForActiveRoot(), rootURL: LocalLibraryPaths.libraryRootURL, now: Date()).values
    }

    private func scanAlbums(
        using manifest: LibraryManifest?,
        rootURL: URL,
        now: Date
    ) -> ScanResult<(sidecar: AlbumSidecar, folderURL: URL), ManifestSidecarEntry<AlbumSidecar>> {
        let decoder = makeDecoder()
        let files = directDirectories(at: LocalLibraryPaths.albumsRootURL)
            .map { $0.appendingPathComponent("meta.json") }

        return scanJSONSidecars(
            files: files,
            rootURL: rootURL,
            sectionName: "album",
            previousEntries: manifest?.albums ?? [:],
            now: now
        ) { data in
            try decoder.decode(AlbumSidecar.self, from: data)
        }
        .mappingValues { sidecar, fileURL in
            (sidecar, fileURL.deletingLastPathComponent())
        }
    }

    // MARK: - Generic JSON Sidecars

    private func scanJSONSidecars<T: Codable & Sendable>(
        files: [URL],
        rootURL: URL,
        sectionName: String,
        previousEntries: [String: ManifestSidecarEntry<T>],
        now: Date,
        decode: (Data) throws -> T
    ) -> ScanResult<(sidecar: T, fileURL: URL), ManifestSidecarEntry<T>> {
        var values: [(sidecar: T, fileURL: URL)] = []
        var manifestEntries: [String: ManifestSidecarEntry<T>] = [:]
        var cached = 0
        var rescanned = 0
        var seen = Set<String>()

        for fileURL in files {
            guard let relativePath = relativePath(for: fileURL, rootURL: rootURL) else { continue }
            seen.insert(relativePath)

            guard let fingerprint = fingerprint(for: fileURL) else {
                continue
            }

            if let entry = previousEntries[relativePath],
               entry.fingerprint.matches(fingerprint) {
                values.append((entry.cachedValue, fileURL))
                manifestEntries[relativePath] = entry.updatingLastScannedAt(now)
                cached += 1
                continue
            }

            do {
                let data = try Data(contentsOf: fileURL)
                let sidecar = try decode(data)
                values.append((sidecar, fileURL))
                manifestEntries[relativePath] = ManifestSidecarEntry(
                    relativePath: relativePath,
                    modifiedAt: fingerprint.modifiedAt,
                    fileSize: fingerprint.fileSize,
                    lastScannedAt: now,
                    cachedValue: sidecar
                )
                rescanned += 1
            } catch {
                Log.warning(
                    "[LibraryIncrementalScan] skipped damaged \(sectionName) sidecar: \(relativePath)",
                    category: .library
                )
            }
        }

        let removed = max(0, previousEntries.keys.filter { !seen.contains($0) }.count)
        return ScanResult(
            values: values,
            manifestEntries: manifestEntries,
            stats: ScanStats(total: values.count, cached: cached, rescanned: rescanned, removed: removed)
        )
    }

    // MARK: - Manifest

    private func loadManifestForActiveRoot() -> LibraryManifest? {
        loadManifest(at: LocalLibraryPaths.libraryRootURL.appendingPathComponent(Self.manifestFileName)).manifest
    }

    private func loadManifest(at url: URL) -> ManifestLoad {
        let fileManager = FileManager()
        guard fileManager.fileExists(atPath: url.path) else {
            return ManifestLoad(manifest: nil, status: "miss")
        }

        do {
            let data = try Data(contentsOf: url)
            let manifest = try makeDecoder().decode(LibraryManifest.self, from: data)
            guard manifest.schemaVersion == Self.manifestSchemaVersion else {
                Log.warning("[LibraryIncrementalScan] schema mismatch; rebuilding manifest", category: .library)
                return ManifestLoad(manifest: nil, status: "schema-mismatch")
            }
            return ManifestLoad(manifest: manifest, status: "hit")
        } catch {
            Log.warning("[LibraryIncrementalScan] damaged manifest; rebuilding manifest", category: .library)
            return ManifestLoad(manifest: nil, status: "damaged")
        }
    }

    private func writeManifest(_ manifest: LibraryManifest, at url: URL, rootURL: URL) {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(manifest)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.warning(
                "[LibraryIncrementalScan] failed to write manifest: \(error.localizedDescription)",
                category: .library
            )
        }
    }

    // MARK: - File Helpers

    private func directDirectories(at url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter {
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func directFiles(at url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? [])
        .filter {
            ((try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true)
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func fingerprint(for url: URL) -> FileFingerprint? {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
              let modifiedAt = values.contentModificationDate
        else {
            return nil
        }
        return FileFingerprint(
            modifiedAt: modifiedAt.timeIntervalSince1970,
            fileSize: Int64(values.fileSize ?? 0)
        )
    }

    private func relativePath(for url: URL, rootURL: URL) -> String? {
        let rootPath = rootURL.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == rootPath || path.hasPrefix(rootPath + "/") else { return nil }
        if path == rootPath { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func logSummary(kind: String, stats: ScanStats) {
        Log.info(
            "[LibraryIncrementalScan] \(kind) total=\(stats.total) cached=\(stats.cached) rescanned=\(stats.rescanned) removed=\(stats.removed)",
            category: .library
        )
    }
}

// MARK: - Manifest Models

nonisolated private struct ManifestLoad {
    let manifest: LibraryManifest?
    let status: String
}

nonisolated private struct ScanStats {
    let total: Int
    let cached: Int
    let rescanned: Int
    let removed: Int
}

nonisolated private struct ScanResult<Value, Entry> {
    let values: [Value]
    let manifestEntries: [String: Entry]
    let stats: ScanStats
}

private extension ScanResult {
    nonisolated func mappingValues<Sidecar, MappedValue>(
        _ transform: (Sidecar, URL) -> MappedValue
    ) -> ScanResult<MappedValue, Entry> where Value == (sidecar: Sidecar, fileURL: URL) {
        ScanResult<MappedValue, Entry>(
            values: values.map { transform($0.sidecar, $0.fileURL) },
            manifestEntries: manifestEntries,
            stats: stats
        )
    }
}

nonisolated private struct FileFingerprint: Codable {
    let modifiedAt: TimeInterval
    let fileSize: Int64

    func matches(_ other: FileFingerprint) -> Bool {
        modifiedAt == other.modifiedAt && fileSize == other.fileSize
    }
}

nonisolated private struct LibraryManifest: Codable {
    let schemaVersion: Int
    let generatedAt: Date
    let tracks: [String: ManifestTrackEntry]
    let playlists: [String: ManifestSidecarEntry<PlaylistSidecar>]
    let artists: [String: ManifestSidecarEntry<ArtistSidecar>]
    let albums: [String: ManifestSidecarEntry<AlbumSidecar>]
}

nonisolated private struct ManifestTrackEntry: Codable {
    let relativePath: String
    let modifiedAt: TimeInterval
    let fileSize: Int64
    let lastScannedAt: Date
    let cachedMeta: CachedScannedTrackMeta

    var fingerprint: FileFingerprint {
        FileFingerprint(modifiedAt: modifiedAt, fileSize: fileSize)
    }

    func updatingLastScannedAt(_ date: Date) -> ManifestTrackEntry {
        ManifestTrackEntry(
            relativePath: relativePath,
            modifiedAt: modifiedAt,
            fileSize: fileSize,
            lastScannedAt: date,
            cachedMeta: cachedMeta
        )
    }
}

nonisolated private struct ManifestSidecarEntry<T: Codable & Sendable>: Codable, Sendable {
    let relativePath: String
    let modifiedAt: TimeInterval
    let fileSize: Int64
    let lastScannedAt: Date
    let cachedValue: T

    var fingerprint: FileFingerprint {
        FileFingerprint(modifiedAt: modifiedAt, fileSize: fileSize)
    }

    func updatingLastScannedAt(_ date: Date) -> ManifestSidecarEntry<T> {
        ManifestSidecarEntry(
            relativePath: relativePath,
            modifiedAt: modifiedAt,
            fileSize: fileSize,
            lastScannedAt: date,
            cachedValue: cachedValue
        )
    }
}

nonisolated private struct CachedScannedTrackMeta: Codable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let description: String
    let genreTags: [String]
    let language: String
    let labelOrCompany: String
    let releaseDate: Date?
    let qqMusicSongMid: String?
    let metadataSource: String?
    let metadataFetchedAt: Date?
    let metadataConfidence: Double?
    let duration: Double
    let addedAt: Date
    let importedAt: Date
    let lyricsTimeOffsetMs: Double
    let originalFilePath: String
    let audioFileName: String
    let artworkFileName: String?
    let lyricsFileName: String?
    let ttmlLyricsFileName: String?
    let playCount: Int?
    let preferenceStats: TrackPreferenceStats?
    let folderRelativePath: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case title
        case artist
        case album
        case albumArtist
        case description
        case genreTags
        case language
        case labelOrCompany
        case releaseDate
        case qqMusicSongMid
        case metadataSource
        case metadataFetchedAt
        case metadataConfidence
        case duration
        case addedAt
        case importedAt
        case lyricsTimeOffsetMs
        case originalFilePath
        case audioFileName
        case artworkFileName
        case lyricsFileName
        case ttmlLyricsFileName
        case playCount
        case preferenceStats
        case folderRelativePath
    }

    init(_ meta: ScannedTrackMeta) {
        schemaVersion = meta.schemaVersion
        id = meta.id
        title = meta.title
        artist = meta.artist
        album = meta.album
        albumArtist = meta.albumArtist
        description = meta.description
        genreTags = meta.genreTags
        language = meta.language
        labelOrCompany = meta.labelOrCompany
        releaseDate = meta.releaseDate
        qqMusicSongMid = meta.qqMusicSongMid
        metadataSource = meta.metadataSource
        metadataFetchedAt = meta.metadataFetchedAt
        metadataConfidence = meta.metadataConfidence
        duration = meta.duration
        addedAt = meta.addedAt
        importedAt = meta.importedAt
        lyricsTimeOffsetMs = meta.lyricsTimeOffsetMs
        originalFilePath = meta.originalFilePath
        audioFileName = meta.audioFileName
        artworkFileName = meta.artworkFileName
        lyricsFileName = meta.lyricsFileName
        ttmlLyricsFileName = meta.ttmlLyricsFileName
        playCount = meta.playCount
        preferenceStats = meta.preferenceStats
        folderRelativePath = "Tracks/\(meta.id.uuidString)"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        artist = try c.decode(String.self, forKey: .artist)
        album = try c.decode(String.self, forKey: .album)
        albumArtist = try c.decodeIfPresent(String.self, forKey: .albumArtist)
        description = try c.decode(String.self, forKey: .description)
        genreTags = try c.decodeIfPresent([String].self, forKey: .genreTags) ?? []
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        labelOrCompany = try c.decodeIfPresent(String.self, forKey: .labelOrCompany) ?? ""
        releaseDate = try c.decodeIfPresent(Date.self, forKey: .releaseDate)
        qqMusicSongMid = try c.decodeIfPresent(String.self, forKey: .qqMusicSongMid)
        metadataSource = try c.decodeIfPresent(String.self, forKey: .metadataSource)
        metadataFetchedAt = try c.decodeIfPresent(Date.self, forKey: .metadataFetchedAt)
        metadataConfidence = try c.decodeIfPresent(Double.self, forKey: .metadataConfidence)
        duration = try c.decode(Double.self, forKey: .duration)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        importedAt = try c.decode(Date.self, forKey: .importedAt)
        lyricsTimeOffsetMs = try c.decode(Double.self, forKey: .lyricsTimeOffsetMs)
        originalFilePath = try c.decode(String.self, forKey: .originalFilePath)
        audioFileName = try c.decode(String.self, forKey: .audioFileName)
        artworkFileName = try c.decodeIfPresent(String.self, forKey: .artworkFileName)
        lyricsFileName = try c.decodeIfPresent(String.self, forKey: .lyricsFileName)
        ttmlLyricsFileName = try c.decodeIfPresent(String.self, forKey: .ttmlLyricsFileName)
        playCount = try c.decodeIfPresent(Int.self, forKey: .playCount)
        preferenceStats = try c.decodeIfPresent(TrackPreferenceStats.self, forKey: .preferenceStats)
        folderRelativePath = try c.decode(String.self, forKey: .folderRelativePath)
    }

    func makeScannedMeta(rootURL: URL) -> ScannedTrackMeta? {
        guard folderRelativePath == "Tracks/\(id.uuidString)" else { return nil }
        return ScannedTrackMeta(
            schemaVersion: schemaVersion,
            id: id,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            description: description,
            genreTags: genreTags,
            language: language,
            labelOrCompany: labelOrCompany,
            releaseDate: releaseDate,
            qqMusicSongMid: qqMusicSongMid,
            metadataSource: metadataSource,
            metadataFetchedAt: metadataFetchedAt,
            metadataConfidence: metadataConfidence,
            duration: duration,
            addedAt: addedAt,
            importedAt: importedAt,
            lyricsTimeOffsetMs: lyricsTimeOffsetMs,
            originalFilePath: originalFilePath,
            audioFileName: audioFileName,
            artworkFileName: artworkFileName,
            lyricsFileName: lyricsFileName,
            ttmlLyricsFileName: ttmlLyricsFileName,
            playCount: playCount,
            preferenceStats: preferenceStats,
            folderURL: rootURL.appendingPathComponent(folderRelativePath, isDirectory: true)
        )
    }
}
