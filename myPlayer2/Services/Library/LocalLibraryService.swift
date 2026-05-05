//
//  LocalLibraryService.swift
//  myPlayer2
//
//  kmgccc_player - Local Library Service
//  Stores audio + sidecar metadata under ~/Music/kmgccc_player Library
//

import AppKit
import Darwin
import Dispatch
import Foundation
import ImageIO

struct TrackSidecar: Codable {
    let schemaVersion: Int
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let description: String?
    let duration: Double
    let addedAt: Date
    let importedAt: Date?
    let lyricsTimeOffsetMs: Double?
    let originalFilePath: String?
    let audioFileName: String?
    let artworkFileName: String?
    let lyricsFileName: String?
    let lyricsType: String?
    let ttmlLyricsFileName: String?
    let ncmSourcePath: String?
    let playCount: Int?
    /// Extended preference statistics (schemaVersion >= 3)
    let preferenceStats: TrackPreferenceStats?

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case title
        case artist
        case album
        case albumArtist
        case description
        case duration
        case addedAt
        case importedAt
        case lyricsTimeOffsetMs
        case originalFilePath
        case audioFileName
        case artworkFileName
        case lyricsFileName
        case lyricsType
        case ttmlLyricsFileName
        case ncmSourcePath
        case playCount
        case preferenceStats
    }

    init(
        schemaVersion: Int = 5,
        id: UUID,
        title: String,
        artist: String,
        album: String,
        albumArtist: String? = nil,
        description: String? = nil,
        duration: Double,
        addedAt: Date,
        importedAt: Date?,
        lyricsTimeOffsetMs: Double?,
        originalFilePath: String?,
        audioFileName: String?,
        artworkFileName: String?,
        lyricsFileName: String?,
        lyricsType: String?,
        ttmlLyricsFileName: String?,
        ncmSourcePath: String?,
        playCount: Int? = 0,
        preferenceStats: TrackPreferenceStats? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.description = description
        self.duration = duration
        self.addedAt = addedAt
        self.importedAt = importedAt
        self.lyricsTimeOffsetMs = lyricsTimeOffsetMs
        self.originalFilePath = originalFilePath
        self.audioFileName = audioFileName
        self.artworkFileName = artworkFileName
        self.lyricsFileName = lyricsFileName
        self.lyricsType = lyricsType
        self.ttmlLyricsFileName = ttmlLyricsFileName
        self.ncmSourcePath = ncmSourcePath
        self.playCount = playCount
        self.preferenceStats = preferenceStats
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // schemaVersion defaults to 1 for backward compatibility
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decode(String.self, forKey: .artist)
        album = try container.decode(String.self, forKey: .album)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        duration = try container.decode(Double.self, forKey: .duration)
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        importedAt = try container.decodeIfPresent(Date.self, forKey: .importedAt)
        lyricsTimeOffsetMs = try container.decodeIfPresent(Double.self, forKey: .lyricsTimeOffsetMs)
        originalFilePath = try container.decodeIfPresent(String.self, forKey: .originalFilePath)
        audioFileName = try container.decodeIfPresent(String.self, forKey: .audioFileName)
        artworkFileName = try container.decodeIfPresent(String.self, forKey: .artworkFileName)
        lyricsFileName = try container.decodeIfPresent(String.self, forKey: .lyricsFileName)
        lyricsType = try container.decodeIfPresent(String.self, forKey: .lyricsType)
        ttmlLyricsFileName = try container.decodeIfPresent(String.self, forKey: .ttmlLyricsFileName)
        ncmSourcePath = try container.decodeIfPresent(String.self, forKey: .ncmSourcePath)
        // playCount defaults to 0 for backward compatibility (schemaVersion 1 doesn't have this field)
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0

        // preferenceStats: migrate from legacy playCount if not present
        if let stats = try container.decodeIfPresent(TrackPreferenceStats.self, forKey: .preferenceStats) {
            preferenceStats = stats
        } else if schemaVersion < 3, let legacyPlayCount = playCount, legacyPlayCount > 0 {
            // Migration: create preferenceStats from legacy playCount
            preferenceStats = TrackPreferenceStats.fromLegacy(playCount: legacyPlayCount)
        } else {
            preferenceStats = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(5, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encodeIfPresent(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(duration, forKey: .duration)
        try container.encode(addedAt, forKey: .addedAt)
        try container.encodeIfPresent(importedAt, forKey: .importedAt)
        try container.encodeIfPresent(lyricsTimeOffsetMs, forKey: .lyricsTimeOffsetMs)
        try container.encodeIfPresent(originalFilePath, forKey: .originalFilePath)
        try container.encodeIfPresent(audioFileName, forKey: .audioFileName)
        try container.encodeIfPresent(artworkFileName, forKey: .artworkFileName)
        try container.encodeIfPresent(lyricsFileName, forKey: .lyricsFileName)
        try container.encodeIfPresent(lyricsType, forKey: .lyricsType)
        try container.encodeIfPresent(ttmlLyricsFileName, forKey: .ttmlLyricsFileName)
        try container.encodeIfPresent(ncmSourcePath, forKey: .ncmSourcePath)
        // NOTE: playCount is deprecated - all stats now live in preferenceStats
        // We intentionally do NOT write playCount to avoid double-counting
        // The field is kept in CodingKeys only for backward compatibility during decoding
        try container.encodeIfPresent(preferenceStats, forKey: .preferenceStats)
    }
}

private struct TrackPersistenceReferences {
    let artworkFileName: String?
    let lyricsFileName: String?
    let lyricsType: String?
    let ttmlLyricsFileName: String?

    init(
        artworkFileName: String? = nil,
        lyricsFileName: String? = nil,
        lyricsType: String? = nil,
        ttmlLyricsFileName: String? = nil
    ) {
        self.artworkFileName = artworkFileName
        self.lyricsFileName = lyricsFileName
        self.lyricsType = lyricsType
        self.ttmlLyricsFileName = ttmlLyricsFileName
    }
}

struct PersistedPlaylistArtwork {
    let image: NSImage
    let source: PlaylistArtworkSource
    let fileURL: URL
}

struct PersistedPlaylistArtworkRecord {
    let customArtwork: PersistedPlaylistArtwork?
    let generatedArtwork: PersistedPlaylistArtwork?
    let generatedSignature: String?
}

@MainActor
final class LocalLibraryService {

    static let shared = LocalLibraryService()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private var monitors: [String: DispatchSourceFileSystemObject] = [:]
    private var monitorFDs: [String: Int32] = [:]
    private var pendingSync: DispatchWorkItem?
    private nonisolated let monitorSuppressionLock = NSLock()
    private nonisolated(unsafe) var monitorEventsSuppressedUntil: TimeInterval = 0

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Library Setup

    private nonisolated static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private nonisolated static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    nonisolated func ensureLibraryFolders() {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: LocalLibraryPaths.libraryRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: LocalLibraryPaths.tracksRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: LocalLibraryPaths.playlistsRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: LocalLibraryPaths.artistsRootURL,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: LocalLibraryPaths.albumsRootURL,
                withIntermediateDirectories: true
            )
        } catch {
            Log.error("Failed to create library folders: \(error)", category: .library)
        }
    }

    // MARK: - Import

    func importAudioFile(from sourceURL: URL, trackId: UUID) throws -> String {
        ensureLibraryFolders()

        let trackFolder = LocalLibraryPaths.trackFolderURL(for: trackId)
        try fileManager.createDirectory(at: trackFolder, withIntermediateDirectories: true)

        let ext = sourceURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeExt = ext.isEmpty ? "audio" : ext
        let audioFileName = "audio.\(safeExt)"
        let destURL = trackFolder.appendingPathComponent(audioFileName)

        if fileManager.fileExists(atPath: destURL.path) {
            try fileManager.removeItem(at: destURL)
        }
        try fileManager.copyItem(at: sourceURL, to: destURL)

        return "Tracks/\(trackId.uuidString)/\(audioFileName)"
    }

    // MARK: - Sidecar Write

    /// Import-only full resource persistence.
    /// Ordinary business updates must use `writeMetaOnly` / `writeTrackMetaAnd...`.
    @discardableResult
    func writeImportedTrackSidecar(for track: Track, reason: String = "importFullTrack") -> Bool {
        guard !track.libraryRelativePath.isEmpty else { return false }

        do {
            let references = loadTrackPersistenceReferences(for: track.id)
            let trackFolder = try ensureTrackFolder(for: track.id)
            let artworkFileName = try writeArtworkIfChanged(
                for: track,
                reason: reason,
                existingFileName: references.artworkFileName
            )
            let updatedReferences = try writeLyricsAssets(
                for: track,
                folder: trackFolder,
                existing: references
            )
            let finalReferences = TrackPersistenceReferences(
                artworkFileName: artworkFileName,
                lyricsFileName: updatedReferences.lyricsFileName,
                lyricsType: updatedReferences.lyricsType,
                ttmlLyricsFileName: updatedReferences.ttmlLyricsFileName
            )
            logTrackPersistence(
                track: track,
                reason: reason,
                action: "import-full-sidecar",
                artwork: "requested"
            )
            try writeTrackMeta(for: track, references: finalReferences)
            return true
        } catch {
            Log.error("Failed to write imported track sidecar for \(track.title): \(error)", category: .library)
            return false
        }
    }

    @discardableResult
    func writeMetaOnly(for track: Track, reason: String) -> Bool {
        guard !track.libraryRelativePath.isEmpty else { return false }

        do {
            let references = loadTrackPersistenceReferences(for: track.id)
            logTrackPersistence(track: track, reason: reason, action: "meta-only", artwork: "not-requested")
            try writeTrackMeta(for: track, references: references)
            return true
        } catch {
            Log.error("Failed to write meta only for \(track.title): \(error)", category: .library)
            return false
        }
    }

    @discardableResult
    func writeTrackMetaAndLyrics(for track: Track, reason: String) -> Bool {
        guard !track.libraryRelativePath.isEmpty else { return false }

        do {
            let references = loadTrackPersistenceReferences(for: track.id)
            let trackFolder = try ensureTrackFolder(for: track.id)
            let updatedReferences = try writeLyricsAssets(for: track, folder: trackFolder, existing: references)
            logTrackPersistence(track: track, reason: reason, action: "meta+lyrics", artwork: "not-requested")
            try writeTrackMeta(for: track, references: updatedReferences)
            return true
        } catch {
            Log.error("Failed to write meta+lyrics for \(track.title): \(error)", category: .library)
            return false
        }
    }

    @discardableResult
    func writeTrackMetaAndArtwork(for track: Track, reason: String) -> Bool {
        guard !track.libraryRelativePath.isEmpty else { return false }

        do {
            let references = loadTrackPersistenceReferences(for: track.id)
            let artworkFileName = try writeArtworkIfChanged(
                for: track,
                reason: reason,
                existingFileName: references.artworkFileName
            )
            let finalReferences = TrackPersistenceReferences(
                artworkFileName: artworkFileName,
                lyricsFileName: references.lyricsFileName,
                lyricsType: references.lyricsType,
                ttmlLyricsFileName: references.ttmlLyricsFileName
            )
            try writeTrackMeta(for: track, references: finalReferences)
            return true
        } catch {
            Log.error("Failed to write meta+artwork for \(track.title): \(error)", category: .library)
            return false
        }
    }

    @discardableResult
    func writeTrackMetaLyricsAndArtwork(for track: Track, reason: String) -> Bool {
        guard !track.libraryRelativePath.isEmpty else { return false }

        do {
            let references = loadTrackPersistenceReferences(for: track.id)
            let trackFolder = try ensureTrackFolder(for: track.id)
            let artworkFileName = try writeArtworkIfChanged(
                for: track,
                reason: reason,
                existingFileName: references.artworkFileName
            )
            let updatedReferences = try writeLyricsAssets(for: track, folder: trackFolder, existing: references)
            let finalReferences = TrackPersistenceReferences(
                artworkFileName: artworkFileName,
                lyricsFileName: updatedReferences.lyricsFileName,
                lyricsType: updatedReferences.lyricsType,
                ttmlLyricsFileName: updatedReferences.ttmlLyricsFileName
            )
            try writeTrackMeta(for: track, references: finalReferences)
            return true
        } catch {
            Log.error("Failed to write meta+lyrics+artwork for \(track.title): \(error)", category: .library)
            return false
        }
    }

    private func ensureTrackFolder(for trackID: UUID) throws -> URL {
        ensureLibraryFolders()
        let trackFolder = LocalLibraryPaths.trackFolderURL(for: trackID)
        try fileManager.createDirectory(at: trackFolder, withIntermediateDirectories: true)
        return trackFolder
    }

    private func loadTrackPersistenceReferences(for trackID: UUID) -> TrackPersistenceReferences {
        let metaURL = LocalLibraryPaths.trackMetaURL(for: trackID)
        guard let data = try? Data(contentsOf: metaURL),
              let sidecar = try? decoder.decode(TrackSidecar.self, from: data)
        else {
            return TrackPersistenceReferences()
        }

        let resolvedArtworkFileName = resolvedTrackArtworkFileName(
            for: trackID,
            preferredFileName: sidecar.artworkFileName
        )

        return TrackPersistenceReferences(
            artworkFileName: resolvedArtworkFileName,
            lyricsFileName: sidecar.lyricsFileName,
            lyricsType: sidecar.lyricsType,
            ttmlLyricsFileName: sidecar.ttmlLyricsFileName
        )
    }

    private func writeTrackMeta(for track: Track, references: TrackPersistenceReferences) throws {
        _ = try ensureTrackFolder(for: track.id)
        let audioFileName = URL(fileURLWithPath: track.libraryRelativePath).lastPathComponent
        let preferenceStats = PreferenceStatsService.shared.getStats(for: track.id)
        let sidecar = TrackSidecar(
            schemaVersion: 5,
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            albumArtist: {
                let trimmed = track.albumArtist?.trimmingCharacters(in: .whitespacesAndNewlines)
                return (trimmed?.isEmpty ?? true) ? nil : trimmed
            }(),
            description: {
                let trimmed = track.userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }(),
            duration: track.duration,
            addedAt: track.addedAt,
            importedAt: track.importedAt ?? track.addedAt,
            lyricsTimeOffsetMs: track.lyricsTimeOffsetMs,
            originalFilePath: track.originalFilePath.isEmpty ? nil : track.originalFilePath,
            audioFileName: audioFileName.isEmpty ? nil : audioFileName,
            artworkFileName: references.artworkFileName,
            lyricsFileName: references.lyricsFileName,
            lyricsType: references.lyricsType,
            ttmlLyricsFileName: references.ttmlLyricsFileName,
            ncmSourcePath: nil,
            preferenceStats: preferenceStats
        )

        let data = try encoder.encode(sidecar)
        let metaURL = LocalLibraryPaths.trackMetaURL(for: track.id)
        try data.write(to: metaURL, options: .atomic)
    }

    func writeArtworkIfChanged(
        for track: Track,
        reason: String,
        existingFileName: String? = nil
    ) throws -> String? {
        let trackFolder = try ensureTrackFolder(for: track.id)
        let existingArtworkFileName = resolvedTrackArtworkFileName(
            for: track.id,
            preferredFileName: existingFileName
        )
        let existingArtworkURL = existingArtworkFileName.map { trackFolder.appendingPathComponent($0) }
        let existingArtworkData = existingArtworkURL.flatMap { try? Data(contentsOf: $0) }
        let targetArtworkFileName = LocalLibraryPaths.preferredTrackArtworkFileName
        let targetArtworkURL = LocalLibraryPaths.trackArtworkURL(
            for: track.id,
            fileName: targetArtworkFileName
        )

        let loadedData = track.loadArtworkDataIfNeeded()
        guard let data = loadedData, !data.isEmpty else {
            let candidateFileNames = LocalLibraryPaths.trackArtworkCandidateFileNames(
                preferredFileName: existingArtworkFileName
            )
            var removedAny = false
            for fileName in candidateFileNames {
                let candidateURL = trackFolder.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: candidateURL.path) {
                    try fileManager.removeItem(at: candidateURL)
                    removedAny = true
                }
            }
            logTrackPersistence(
                track: track,
                reason: reason,
                action: "artwork-remove",
                artwork: removedAny ? "removed" : "already-missing"
            )
            return nil
        }

        if dataMatches(data, existingArtworkData), existingArtworkFileName == targetArtworkFileName {
            logTrackPersistence(track: track, reason: reason, action: "artwork-skip", artwork: "raw-unchanged")
            return existingArtworkFileName
        }

        guard
            let dataToWrite = ArtworkDataNormalizer.normalizedJPEGData(
                from: data,
                maxPixelSize: ArtworkDataNormalizer.storedMaxPixelSize
            )
        else {
            logTrackPersistence(track: track, reason: reason, action: "artwork-error", artwork: "normalize-failed")
            throw NSError(
                domain: "LocalLibraryService.TrackPersistence",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Artwork could not be downsampled and encoded"]
            )
        }

        if dataMatches(dataToWrite, existingArtworkData), existingArtworkFileName == targetArtworkFileName {
            logTrackPersistence(track: track, reason: reason, action: "artwork-skip", artwork: "encoded-unchanged")
            return existingArtworkFileName
        }

        try dataToWrite.write(to: targetArtworkURL, options: .atomic)
        if let existingArtworkFileName, existingArtworkFileName != targetArtworkFileName,
           let existingArtworkURL,
           fileManager.fileExists(atPath: existingArtworkURL.path) {
            try? fileManager.removeItem(at: existingArtworkURL)
        }
        logTrackPersistence(
            track: track,
            reason: reason,
            action: "artwork-write",
            artwork: "changed encoding=jpeg-downsampled maxPixel=\(ArtworkDataNormalizer.storedMaxPixelSize)"
        )
        return targetArtworkFileName
    }

    private func writeLyricsAssets(
        for track: Track,
        folder: URL,
        existing: TrackPersistenceReferences
    ) throws -> TrackPersistenceReferences {
        let ttmlText = track.ttmlLyricText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyText = track.lyricsText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let ttmlURL = folder.appendingPathComponent("lyrics.ttml")
        let plainLyricsURL = folder.appendingPathComponent("lyrics.txt")

        if let ttml = ttmlText, !ttml.isEmpty {
            try ttml.write(to: ttmlURL, atomically: true, encoding: .utf8)
            if fileManager.fileExists(atPath: plainLyricsURL.path) {
                try? fileManager.removeItem(at: plainLyricsURL)
            }
            return TrackPersistenceReferences(
                artworkFileName: existing.artworkFileName,
                lyricsFileName: nil,
                lyricsType: nil,
                ttmlLyricsFileName: "lyrics.ttml"
            )
        }

        if let legacy = legacyText, !legacy.isEmpty {
            let isTTML = legacy.lowercased().contains("<tt") && legacy.contains("</")
            if isTTML {
                try legacy.write(to: ttmlURL, atomically: true, encoding: .utf8)
                if fileManager.fileExists(atPath: plainLyricsURL.path) {
                    try? fileManager.removeItem(at: plainLyricsURL)
                }
                return TrackPersistenceReferences(
                    artworkFileName: existing.artworkFileName,
                    lyricsFileName: nil,
                    lyricsType: nil,
                    ttmlLyricsFileName: "lyrics.ttml"
                )
            }

            try legacy.write(to: plainLyricsURL, atomically: true, encoding: .utf8)
            if fileManager.fileExists(atPath: ttmlURL.path) {
                try? fileManager.removeItem(at: ttmlURL)
            }
            return TrackPersistenceReferences(
                artworkFileName: existing.artworkFileName,
                lyricsFileName: "lyrics.txt",
                lyricsType: "plain",
                ttmlLyricsFileName: nil
            )
        }

        if fileManager.fileExists(atPath: ttmlURL.path) {
            try? fileManager.removeItem(at: ttmlURL)
        }
        if fileManager.fileExists(atPath: plainLyricsURL.path) {
            try? fileManager.removeItem(at: plainLyricsURL)
        }

        return TrackPersistenceReferences(
            artworkFileName: existing.artworkFileName,
            lyricsFileName: nil,
            lyricsType: nil,
            ttmlLyricsFileName: nil
        )
    }

    private func dataMatches(_ lhs: Data, _ rhs: Data?) -> Bool {
        guard let rhs else { return false }
        guard ArtworkAssetStore.checksum(for: lhs) == ArtworkAssetStore.checksum(for: rhs) else {
            return false
        }
        return lhs == rhs
    }

    private func resolvedTrackArtworkFileName(for trackID: UUID, preferredFileName: String?) -> String? {
        let folder = LocalLibraryPaths.trackFolderURL(for: trackID)
        return resolvedTrackArtworkFileName(in: folder, preferredFileName: preferredFileName)
    }

    private func resolvedTrackArtworkFileName(in folder: URL, preferredFileName: String?) -> String? {
        for fileName in LocalLibraryPaths.trackArtworkCandidateFileNames(preferredFileName: preferredFileName) {
            let candidateURL = folder.appendingPathComponent(fileName)
            if fileManager.fileExists(atPath: candidateURL.path) {
                return fileName
            }
        }
        if let preferredFileName, !preferredFileName.isEmpty {
            return preferredFileName
        }
        return nil
    }

    private func isPNGData(_ data: Data) -> Bool {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    private func logTrackPersistence(track: Track, reason: String, action: String, artwork: String) {
        Log.info(
            "[TrackPersistence] reason=\(reason) track=\(track.id.uuidString) title=\(track.title) action=\(action) artwork=\(artwork)",
            category: .library
        )
    }

    // MARK: - Track Deletion

    func deleteTrackFiles(_ track: Track) {
        _ = deleteTrackFolder(trackID: track.id)
    }

    @discardableResult
    nonisolated func deleteTrackFolder(trackID: UUID) -> Bool {
        let fileManager = FileManager.default
        let folder = LocalLibraryPaths.trackFolderURL(for: trackID)
        guard fileManager.fileExists(atPath: folder.path) else { return true }

        do {
            try fileManager.removeItem(at: folder)
            return true
        } catch {
            // Fallback: remove meta.json so a later full rescan cannot resurrect the deleted track.
            let metaURL = folder.appendingPathComponent("meta.json")
            if fileManager.fileExists(atPath: metaURL.path) {
                try? fileManager.removeItem(at: metaURL)
            }
            Log.error(
                "Failed to delete track folder \(folder.lastPathComponent): \(error)",
                category: .library
            )
            return false
        }
    }

    // MARK: - Playlist Sidecars

    func writePlaylist(_ playlist: Playlist, itemAddedAt: [UUID: Date]? = nil) {
        ensureLibraryFolders()
        writePlaylistSidecar(
            playlistID: playlist.id,
            name: playlist.name,
            description: playlist.userDescription,
            createdAt: playlist.createdAt,
            trackIDs: playlist.tracks.map(\.id),
            itemAddedAt: itemAddedAt ?? [:]
        )
    }

    nonisolated func writePlaylistSidecar(
        playlistID: UUID,
        name: String,
        description: String,
        createdAt: Date,
        trackIDs: [UUID],
        itemAddedAt: [UUID: Date]
    ) {
        ensureLibraryFolders()
        let items = trackIDs.map { trackID in
            PlaylistItemSidecar(
                trackID: trackID,
                addedAt: itemAddedAt[trackID] ?? Date()
            )
        }
        let desc = description.isEmpty ? nil : description
        let existingSidecar = loadPlaylistSidecar(playlistID: playlistID)
        let sidecar = PlaylistSidecar(
            id: playlistID,
            name: name,
            description: desc,
            createdAt: createdAt,
            items: items,
            customHeaderArtworkFileName: existingSidecar?.customHeaderArtworkFileName,
            generatedHeaderArtworkFileName: existingSidecar?.generatedHeaderArtworkFileName,
            headerArtworkSource: existingSidecar?.headerArtworkSource,
            generatedArtworkSignature: existingSidecar?.generatedArtworkSignature,
            artworkRevision: existingSidecar?.artworkRevision
        )

        do {
            let data = try Self.makeJSONEncoder().encode(sidecar)
            let url = LocalLibraryPaths.playlistURL(for: playlistID)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("Failed to write playlist sidecar '\(name)': \(error)", category: .library)
        }
    }

    func writeAllPlaylists(_ playlists: [Playlist]) {
        for playlist in playlists {
            writePlaylist(playlist)
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        let url = LocalLibraryPaths.playlistURL(for: playlist.id)
        if fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Log.error("Failed to delete playlist sidecar '\(playlist.name)': \(error)", category: .library)
            }
        }
        let artworkURL = LocalLibraryPaths.legacyPlaylistArtworkURL(for: playlist.id)
        if fileManager.fileExists(atPath: artworkURL.path) {
            try? fileManager.removeItem(at: artworkURL)
        }
        let customArtworkURL = LocalLibraryPaths.playlistCustomArtworkURL(for: playlist.id)
        if fileManager.fileExists(atPath: customArtworkURL.path) {
            try? fileManager.removeItem(at: customArtworkURL)
        }
        let generatedArtworkURL = LocalLibraryPaths.playlistGeneratedArtworkURL(for: playlist.id)
        if fileManager.fileExists(atPath: generatedArtworkURL.path) {
            try? fileManager.removeItem(at: generatedArtworkURL)
        }
    }

    func loadPlaylistArtworkRecord(playlistID: UUID) -> PersistedPlaylistArtworkRecord {
        let sidecar = loadPlaylistSidecar(playlistID: playlistID)
        let migratedSidecar = migrateLegacyPlaylistArtworkIfNeeded(
            playlistID: playlistID,
            sidecar: sidecar
        )

        let customArtwork = loadPersistedPlaylistArtwork(
            playlistID: playlistID,
            fileName: migratedSidecar?.customHeaderArtworkFileName,
            source: .custom
        )
        let generatedArtwork = loadPersistedPlaylistArtwork(
            playlistID: playlistID,
            fileName: migratedSidecar?.generatedHeaderArtworkFileName,
            source: .generated
        )

        return PersistedPlaylistArtworkRecord(
            customArtwork: customArtwork,
            generatedArtwork: generatedArtwork,
            generatedSignature: migratedSidecar?.generatedArtworkSignature
        )
    }

    func playlistArtworkRevision(playlistID: UUID) -> String? {
        loadPlaylistSidecar(playlistID: playlistID)?.artworkRevision
    }

    func savePlaylistCustomArtwork(playlistID: UUID, image: NSImage) {
        let fileURL = LocalLibraryPaths.playlistCustomArtworkURL(for: playlistID)
        guard writePNGArtwork(image, to: fileURL) else { return }

        let existing = loadPlaylistSidecar(playlistID: playlistID)

        // Delete old generated artwork file when switching to custom
        if let generatedFileName = existing?.generatedHeaderArtworkFileName {
            let generatedURL = LocalLibraryPaths.playlistsRootURL
                .appendingPathComponent(generatedFileName)
            try? FileManager.default.removeItem(at: generatedURL)
        }

        updatePlaylistArtworkMetadata(
            playlistID: playlistID,
            customFileName: fileURL.lastPathComponent,
            generatedFileName: nil, // Clear generated file reference
            activeSource: .custom,
            generatedSignature: nil, // Clear signature since we're using custom
            artworkRevision: UUID().uuidString
        )
    }

    func savePlaylistGeneratedArtwork(
        playlistID: UUID,
        image: NSImage,
        signature: String
    ) {
        let fileURL = LocalLibraryPaths.playlistGeneratedArtworkURL(for: playlistID)
        guard writePNGArtwork(image, to: fileURL) else { return }

        let existing = loadPlaylistSidecar(playlistID: playlistID)
        let shouldActivateGenerated = existing?.customHeaderArtworkFileName == nil
        let activeSource: PlaylistArtworkSource =
            shouldActivateGenerated ? .generated : (existing?.headerArtworkSource ?? .custom)
        updatePlaylistArtworkMetadata(
            playlistID: playlistID,
            customFileName: existing?.customHeaderArtworkFileName,
            generatedFileName: fileURL.lastPathComponent,
            activeSource: activeSource,
            generatedSignature: signature,
            artworkRevision: shouldActivateGenerated
                ? UUID().uuidString
                : existing?.artworkRevision
        )
    }

    /// Explicitly regenerate playlist artwork from tracks and set it as the active artwork.
    /// This clears any custom artwork and forces generation (or re-generation) of the built-in cover.
    func regeneratePlaylistArtwork(
        playlistID: UUID,
        tracks: [Track],
        image: NSImage
    ) -> Bool {
        let fileURL = LocalLibraryPaths.playlistGeneratedArtworkURL(for: playlistID)
        guard writePNGArtwork(image, to: fileURL) else {
            debugArtworkPersistence(
                "selectionIdentity=\(playlistID) source=generated filePath=\(fileURL.path) phase=regenerate save=failed reason=png-write-failed tracks=\(tracks.count)"
            )
            return false
        }

        let existing = loadPlaylistSidecar(playlistID: playlistID)

        // Delete old custom artwork file when switching to generated
        if let customFileName = existing?.customHeaderArtworkFileName {
            let customURL = LocalLibraryPaths.playlistsRootURL
                .appendingPathComponent(customFileName)
            try? FileManager.default.removeItem(at: customURL)
        }

        // Clear custom artwork (set to nil) and set active source to generated
        let metadataSaved = updatePlaylistArtworkMetadata(
            playlistID: playlistID,
            customFileName: nil,
            generatedFileName: fileURL.lastPathComponent,
            activeSource: .generated,
            generatedSignature: nil, // Signature not used for stability anymore
            artworkRevision: UUID().uuidString
        )
        if !metadataSaved {
            debugArtworkPersistence(
                "selectionIdentity=\(playlistID) source=generated filePath=\(fileURL.path) phase=regenerate save=failed reason=metadata-write-failed tracks=\(tracks.count)"
            )
        }
        return metadataSaved
    }

    nonisolated func loadPlaylistSidecar(playlistID: UUID) -> PlaylistSidecar? {
        let url = LocalLibraryPaths.playlistURL(for: playlistID)
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? Self.makeJSONDecoder().decode(PlaylistSidecar.self, from: data)
        else { return nil }
        return sidecar
    }

    @discardableResult
    private func updatePlaylistArtworkMetadata(
        playlistID: UUID,
        customFileName: String?,
        generatedFileName: String?,
        activeSource: PlaylistArtworkSource,
        generatedSignature: String?,
        artworkRevision: String?
    ) -> Bool {
        guard let sidecar = loadPlaylistSidecar(playlistID: playlistID) else { return false }
        let updated = PlaylistSidecar(
            schemaVersion: sidecar.schemaVersion,
            id: sidecar.id,
            name: sidecar.name,
            description: sidecar.description,
            createdAt: sidecar.createdAt,
            items: sidecar.items,
            customHeaderArtworkFileName: customFileName,
            generatedHeaderArtworkFileName: generatedFileName,
            headerArtworkSource: activeSource,
            generatedArtworkSignature: generatedSignature,
            artworkRevision: artworkRevision
        )
        do {
            let data = try encoder.encode(updated)
            let url = LocalLibraryPaths.playlistURL(for: playlistID)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error("Failed to update playlist artwork metadata: \(error)", category: .library)
            return false
        }
    }

    private func migrateLegacyPlaylistArtworkIfNeeded(
        playlistID: UUID,
        sidecar: PlaylistSidecar?
    ) -> PlaylistSidecar? {
        guard let sidecar else { return nil }

        let legacyURL = LocalLibraryPaths.legacyPlaylistArtworkURL(for: playlistID)
        guard fileManager.fileExists(atPath: legacyURL.path) else { return sidecar }
        guard sidecar.customHeaderArtworkFileName == nil, sidecar.generatedHeaderArtworkFileName == nil else {
            return sidecar
        }

        let legacySource = sidecar.headerArtworkSource ?? .custom
        let destinationURL: URL
        let customFileName: String?
        let generatedFileName: String?

        switch legacySource {
        case .generated:
            destinationURL = LocalLibraryPaths.playlistGeneratedArtworkURL(for: playlistID)
            customFileName = nil
            generatedFileName = destinationURL.lastPathComponent
        case .custom, .none:
            destinationURL = LocalLibraryPaths.playlistCustomArtworkURL(for: playlistID)
            customFileName = destinationURL.lastPathComponent
            generatedFileName = nil
        }

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: legacyURL, to: destinationURL)
            try? fileManager.removeItem(at: legacyURL)
        } catch {
            Log.error("Failed to migrate legacy playlist artwork: \(error)", category: .library)
        }

        updatePlaylistArtworkMetadata(
            playlistID: playlistID,
            customFileName: customFileName,
            generatedFileName: generatedFileName,
            activeSource: legacySource == .none ? .custom : legacySource,
            generatedSignature: sidecar.generatedArtworkSignature,
            artworkRevision: sidecar.artworkRevision ?? UUID().uuidString
        )

        return loadPlaylistSidecar(playlistID: playlistID)
    }

    private func loadPersistedPlaylistArtwork(
        playlistID _: UUID,
        fileName: String?,
        source: PlaylistArtworkSource
    ) -> PersistedPlaylistArtwork? {
        guard let fileName else { return nil }
        let fileURL = LocalLibraryPaths.playlistsRootURL.appendingPathComponent(fileName)
        guard
            fileManager.fileExists(atPath: fileURL.path),
            let image = downsampledArtworkImage(fileURL: fileURL, maxPixelSize: 680)
        else {
            return nil
        }
        return PersistedPlaylistArtwork(image: image, source: source, fileURL: fileURL)
    }

    private func downsampledArtworkImage(fileURL: URL, maxPixelSize: Int) -> NSImage? {
        guard
            let source = CGImageSourceCreateWithURL(
                fileURL as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            )
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: cgImage.width, height: cgImage.height)
        )
    }

    @discardableResult
    private func writePNGArtwork(_ image: NSImage, to url: URL) -> Bool {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:])
        else { return false }

        do {
            try pngData.write(to: url, options: .atomic)
            return true
        } catch {
            Log.error("Failed to save playlist artwork: \(error)", category: .library)
            return false
        }
    }

    private func debugArtworkPersistence(_ message: String) {
        print("🎨 [HeaderArtworkPersistence] \(message)")
    }

    // MARK: - Artist/Album Sidecars

    func loadArtistSidecarsFromDisk() -> [(sidecar: ArtistSidecar, folderURL: URL)] {
        let root = LocalLibraryPaths.artistsRootURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return entries.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let metaURL = folderURL.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(ArtistSidecar.self, from: data)
            else { return nil }
            return (sidecar, folderURL)
        }
    }

    func loadAlbumSidecarsFromDisk() -> [(sidecar: AlbumSidecar, folderURL: URL)] {
        let root = LocalLibraryPaths.albumsRootURL
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return entries.compactMap { folderURL in
            guard (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            let metaURL = folderURL.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let sidecar = try? decoder.decode(AlbumSidecar.self, from: data)
            else { return nil }
            return (sidecar, folderURL)
        }
    }

    func writeArtistSidecar(_ sidecar: ArtistSidecar, artworkData: Data?) {
        let folder = LocalLibraryPaths.artistFolderURL(for: sidecar.id)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let metaURL = LocalLibraryPaths.artistMetaURL(for: sidecar.id)
            let data = try encoder.encode(sidecar)
            try data.write(to: metaURL, options: .atomic)
            if let artworkData, let fileName = sidecar.artworkFileName {
                let artworkURL = folder.appendingPathComponent(fileName)
                try artworkData.write(to: artworkURL, options: .atomic)
            }
        } catch {
            Log.error("Failed to write artist sidecar '\(sidecar.displayName)': \(error)", category: .library)
        }
    }

    func writeAlbumSidecar(_ sidecar: AlbumSidecar, artworkData: Data?) {
        let folder = LocalLibraryPaths.albumFolderURL(for: sidecar.id)
        do {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            let previousArtworkFileName = loadAlbumSidecarsFromDisk()
                .first(where: { $0.sidecar.id == sidecar.id })?
                .sidecar
                .artworkFileName
            let metaURL = LocalLibraryPaths.albumMetaURL(for: sidecar.id)
            let data = try encoder.encode(sidecar)
            try data.write(to: metaURL, options: .atomic)
            if let previousArtworkFileName, previousArtworkFileName != sidecar.artworkFileName {
                let previousArtworkURL = folder.appendingPathComponent(previousArtworkFileName)
                if fileManager.fileExists(atPath: previousArtworkURL.path) {
                    try? fileManager.removeItem(at: previousArtworkURL)
                }
            }
            if let artworkData, let fileName = sidecar.artworkFileName {
                let artworkURL = folder.appendingPathComponent(fileName)
                try artworkData.write(to: artworkURL, options: .atomic)
            }
        } catch {
            Log.error("Failed to write album sidecar '\(sidecar.displayTitle)': \(error)", category: .library)
        }
    }

    nonisolated func deleteArtistEntry(id: UUID) {
        let fileManager = FileManager.default
        let folder = LocalLibraryPaths.artistFolderURL(for: id)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try? fileManager.removeItem(at: folder)
    }

    nonisolated func deleteAlbumEntry(id: UUID) {
        let fileManager = FileManager.default
        let folder = LocalLibraryPaths.albumFolderURL(for: id)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try? fileManager.removeItem(at: folder)
    }

    // MARK: - Bootstrap / Sync

    func bootstrapIfNeeded(repository: LibraryRepositoryProtocol) async {
        ensureLibraryFolders()

        let count = await repository.totalTrackCount()
        if count == 0 {
            let tracks = loadTracksFromDisk()
            if !tracks.isEmpty {
                await repository.addTracks(tracks)
            }

            let tracksById = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            let playlists = loadPlaylistsFromDisk(tracksById: tracksById)
            for playlist in playlists {
                await repository.addPlaylist(playlist)
            }
        } else {
            await migrateLegacyTracksIfNeeded(repository: repository)
            await refreshAvailability(repository: repository)
        }
    }

    func refreshAvailability(repository: LibraryRepositoryProtocol) async {
        // 1. Refresh Tracks Availability
        let tracks = await repository.fetchTracks(in: nil)
        for track in tracks {
            guard !track.libraryRelativePath.isEmpty else { continue }
            let url = LocalLibraryPaths.libraryURL(from: track.libraryRelativePath)
            let exists = fileManager.fileExists(atPath: url.path)

            let newAvailability: TrackAvailability = exists ? .available : .missing
            let needsImportBackfill = track.importedAt == nil

            if track.availability != newAvailability || needsImportBackfill {
                track.availability = newAvailability
                if needsImportBackfill {
                    track.importedAt = track.addedAt
                }
                await repository.persistTrackMetaOnly(track, reason: "availabilityRefresh")
            }
        }

        // 2. Refresh Playlists from Disk
        await refreshPlaylists(repository: repository)
    }

    /// Refresh playlists by comparing raw disk sidecar data against the DB.
    /// IMPORTANT: We use PlaylistSidecar structs (not @Model Playlist objects) to avoid
    /// SwiftData implicitly inserting phantom Playlist objects into the context when
    /// managed Track objects are assigned to their relationships.
    /// IMPORTANT: We do NOT write back to disk during sync to avoid triggering
    /// the file system monitor and creating an infinite feedback loop.
    private func refreshPlaylists(repository: LibraryRepositoryProtocol) async {
        let tracks = await repository.fetchTracks(in: nil)
        let tracksById = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        let diskSidecars = loadPlaylistSidecarsFromDisk()

        let dbPlaylists = await repository.fetchPlaylists()

        // 1. Identify IDs
        let diskIds = Set(diskSidecars.map { $0.id })
        let dbIds = Set(dbPlaylists.map { $0.id })

        // 2. Add New (On Disk, not in DB)
        for sidecar in diskSidecars where !dbIds.contains(sidecar.id) {
            Log.debug("Found new playlist on disk: \(sidecar.name)", category: .library)
            let resolvedTracks = sidecar.trackIDs.compactMap { tracksById[$0] }
            let playlist = Playlist(
                id: sidecar.id,
                name: sidecar.name,
                createdAt: sidecar.createdAt,
                tracks: resolvedTracks
            )
            await repository.addPlaylist(playlist)
        }

        // 3. Delete Stale (In DB, not on Disk)
        for playlist in dbPlaylists where !diskIds.contains(playlist.id) {
            Log.debug("Removing stale playlist from DB: \(playlist.name)", category: .library)
            await repository.deletePlaylist(playlist)
        }

        // 4. Update Existing
        // Use Set comparison to avoid false positives from SwiftData ordering differences.
        // Directly modify the managed Playlist object and save WITHOUT writing back to disk,
        // to prevent triggering the file system monitor → infinite refresh loop.
        var needsSave = false
        for sidecar in diskSidecars {
            if let dbPlaylist = dbPlaylists.first(where: { $0.id == sidecar.id }) {
                // Sync Name
                if dbPlaylist.name != sidecar.name {
                    dbPlaylist.name = sidecar.name
                    needsSave = true
                }

                // Sync Tracks — compare as Sets (order-insensitive)
                let dbTrackIdSet = Set(dbPlaylist.tracks.map { $0.id })
                let diskTrackIdSet = Set(sidecar.trackIDs)

                if dbTrackIdSet != diskTrackIdSet {
                    Log.debug("Syncing tracks for playlist: \(sidecar.name)", category: .library)
                    let resolvedTracks = sidecar.trackIDs.compactMap { tracksById[$0] }
                    dbPlaylist.tracks = resolvedTracks
                    needsSave = true
                }
            }
        }

        if needsSave {
            await repository.save()
        }
    }

    /// Load raw playlist sidecar data from disk without creating @Model objects.
    /// This is safe to call during refresh because it does not touch the SwiftData context.
    func loadPlaylistSidecarsFromDisk() -> [PlaylistSidecar] {
        ensureLibraryFolders()
        var sidecars: [PlaylistSidecar] = []

        let files =
            (try? fileManager.contentsOfDirectory(
                at: LocalLibraryPaths.playlistsRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                let sidecar = try? decoder.decode(PlaylistSidecar.self, from: data)
            else {
                continue
            }
            sidecars.append(sidecar)
        }

        return sidecars
    }

    func migrateLegacyTracksIfNeeded(repository: LibraryRepositoryProtocol) async {
        let tracks = await repository.fetchTracks(in: nil)
        for track in tracks
        where track.libraryRelativePath.isEmpty && !track.fileBookmarkData.isEmpty {
            let result = track.resolveFileURL()
            guard let sourceURL = result.url else {
                track.availability = .missing
                await repository.persistTrackMetaOnly(track, reason: "legacyMigration")
                continue
            }

            do {
                let relativePath = try importAudioFile(from: sourceURL, trackId: track.id)
                track.libraryRelativePath = relativePath
                if track.originalFilePath.isEmpty {
                    track.originalFilePath = sourceURL.path
                }
                track.availability = .available
                await repository.persistTrackMetaOnly(track, reason: "legacyMigration")
            } catch {
                Log.error("Failed to migrate track \(track.title): \(error)", category: .library)
            }

            track.stopAccessingFile(url: sourceURL)
        }
    }

    // MARK: - Disk Load

    func loadTracksFromDisk() -> [Track] {
        ensureLibraryFolders()
        var tracks: [Track] = []

        let trackDirs =
            (try? fileManager.contentsOfDirectory(
                at: LocalLibraryPaths.tracksRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        for dir in trackDirs where dir.hasDirectoryPath {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                let sidecar = try? decoder.decode(TrackSidecar.self, from: data)
            else {
                continue
            }

            let audioFileName = sidecar.audioFileName ?? findAudioFileName(in: dir)
            let relativePath: String = {
                if let audioFileName {
                    return "Tracks/\(sidecar.id.uuidString)/\(audioFileName)"
                }
                return ""
            }()

            let audioURL =
                relativePath.isEmpty
                ? nil
                : LocalLibraryPaths.libraryURL(from: relativePath)
            let isAvailable = audioURL.map { fileManager.fileExists(atPath: $0.path) } ?? false

            let resolvedArtworkFileName = resolvedTrackArtworkFileName(
                in: dir,
                preferredFileName: sidecar.artworkFileName
            )

            let track = Track(
                id: sidecar.id,
                title: sidecar.title,
                artist: sidecar.artist,
                album: sidecar.album,
                albumArtist: sidecar.albumArtist,
                userDescription: sidecar.description ?? "",
                duration: sidecar.duration,
                addedAt: sidecar.addedAt,
                importedAt: sidecar.importedAt ?? sidecar.addedAt,
                lyricsTimeOffsetMs: sidecar.lyricsTimeOffsetMs ?? 0,
                fileBookmarkData: Data(),
                originalFilePath: sidecar.originalFilePath ?? "",
                libraryRelativePath: relativePath,
                availability: isAvailable ? .available : .missing,
                artworkData: nil,
                ttmlLyricText: nil,
                lyricsText: nil
            )

            track.libraryRootSnapshot = LocalLibraryPaths.libraryRootURL.path
            track.audioFileName = audioFileName ?? ""
            track.artworkFileName = resolvedArtworkFileName
            track.lyricsFileName = sidecar.lyricsFileName
            track.ttmlLyricsFileName = sidecar.ttmlLyricsFileName

            // Load preference stats into cache if available.
            // If preferenceStats exists in sidecar, use it; otherwise migration will happen on first write.
            PreferenceStatsService.shared.loadStats(from: sidecar)

            tracks.append(track)
        }

        return tracks
    }

    func loadPlaylistsFromDisk(tracksById: [UUID: Track]) -> [Playlist] {
        ensureLibraryFolders()
        var playlists: [Playlist] = []

        let files =
            (try? fileManager.contentsOfDirectory(
                at: LocalLibraryPaths.playlistsRootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                let sidecar = try? decoder.decode(PlaylistSidecar.self, from: data)
            else {
                continue
            }

            let tracks = sidecar.trackIDs.compactMap { tracksById[$0] }
            let playlist = Playlist(
                id: sidecar.id,
                name: sidecar.name,
                createdAt: sidecar.createdAt,
                tracks: tracks
            )
            playlists.append(playlist)
        }

        return playlists
    }

    private func findAudioFileName(in folder: URL) -> String? {
        let files =
            (try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []

        if let audio = files.first(where: { $0.lastPathComponent.lowercased().hasPrefix("audio.") })
        {
            return audio.lastPathComponent
        }

        let supported = Set(Constants.FileTypes.supportedAudioExtensions)
        if let audio = files.first(where: { supported.contains($0.pathExtension.lowercased()) }) {
            return audio.lastPathComponent
        }

        return nil
    }

    // MARK: - Monitoring (missing/removed files)

    func startMonitoring(repository: LibraryRepositoryProtocol) {
        stopMonitoring()
        ensureLibraryFolders()

        let pathsToMonitor = [
            "tracks": LocalLibraryPaths.tracksRootURL.path,
            "playlists": LocalLibraryPaths.playlistsRootURL.path,
        ]

        for (name, path) in pathsToMonitor {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else {
                Log.warning("Failed to open \(name) path for monitoring: \(path)", category: .library)
                continue
            }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .extend, .attrib],  // Added .extend/.attrib for better file change detection
                queue: .main
            )

            source.setEventHandler { [weak self] in
                guard let self else { return }
                if self.shouldIgnoreMonitorEvent() {
                    Log.debug("Ignored self-induced monitor event in \(name)", category: .library)
                    return
                }
                print("📝 Detected change in \(name) folder")
                self.scheduleAvailabilitySync(repository: repository)
            }

            source.setCancelHandler { [fd] in
                close(fd)
            }

            source.resume()
            monitors[name] = source
            monitorFDs[name] = fd
            print("👀 Started monitoring \(name) at \(path)")
        }
    }

    func stopMonitoring() {
        pendingSync?.cancel()
        pendingSync = nil

        for source in monitors.values {
            source.cancel()
        }
        monitors.removeAll()

        // FDs are closed in cancel handler, but we clear our tracking
        monitorFDs.removeAll()
    }

    func restartMonitoring(repository: LibraryRepositoryProtocol) {
        stopMonitoring()
        startMonitoring(repository: repository)
    }

    private func scheduleAvailabilitySync(repository: LibraryRepositoryProtocol) {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.refreshAvailability(repository: repository)
            }
        }
        pendingSync = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    nonisolated func suppressMonitorEvents(for duration: TimeInterval = 1.5) {
        monitorSuppressionLock.lock()
        monitorEventsSuppressedUntil = max(
            monitorEventsSuppressedUntil,
            ProcessInfo.processInfo.systemUptime + duration
        )
        monitorSuppressionLock.unlock()
    }

    private func shouldIgnoreMonitorEvent() -> Bool {
        monitorSuppressionLock.lock()
        let ignored = ProcessInfo.processInfo.systemUptime < monitorEventsSuppressedUntil
        monitorSuppressionLock.unlock()
        return ignored
    }
}

extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff)
        else {
            return nil
        }

        return rep.representation(using: .png, properties: [:])
    }
}
