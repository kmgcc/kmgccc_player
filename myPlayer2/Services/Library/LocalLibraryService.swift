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
        schemaVersion: Int = 3,
        id: UUID,
        title: String,
        artist: String,
        album: String,
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
        try container.encode(3, forKey: .schemaVersion)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
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

struct PlaylistSidecar: Codable {
    let schemaVersion: Int
    let id: UUID
    let name: String
    let createdAt: Date
    let items: [PlaylistItemSidecar]
    let legacyTrackIDs: [UUID]?
    let description: String?
    let customHeaderArtworkFileName: String?
    let generatedHeaderArtworkFileName: String?
    let headerArtworkSource: PlaylistArtworkSource?
    let generatedArtworkSignature: String?
    let artworkRevision: String?

    var trackIDs: [UUID] {
        if schemaVersion >= 2 {
            return items.map(\.trackID)
        }
        return legacyTrackIDs ?? []
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case name
        case createdAt
        case items
        case trackIDs
        case trackIds
        case description
        case customHeaderArtworkFileName
        case generatedHeaderArtworkFileName
        case headerArtworkSource
        case generatedArtworkSignature
        case artworkRevision
        case legacyHeaderArtworkSignature = "headerArtworkSignature"
    }

    init(
        schemaVersion: Int = 4,
        id: UUID,
        name: String,
        description: String? = nil,
        createdAt: Date,
        items: [PlaylistItemSidecar],
        customHeaderArtworkFileName: String? = nil,
        generatedHeaderArtworkFileName: String? = nil,
        headerArtworkSource: PlaylistArtworkSource? = nil,
        generatedArtworkSignature: String? = nil,
        artworkRevision: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.createdAt = createdAt
        self.items = items
        self.legacyTrackIDs = nil
        self.customHeaderArtworkFileName = customHeaderArtworkFileName
        self.generatedHeaderArtworkFileName = generatedHeaderArtworkFileName
        self.headerArtworkSource = headerArtworkSource
        self.generatedArtworkSignature = generatedArtworkSignature
        self.artworkRevision = artworkRevision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1

        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        schemaVersion = version
        description = try c.decodeIfPresent(String.self, forKey: .description)
        customHeaderArtworkFileName = try c.decodeIfPresent(
            String.self,
            forKey: .customHeaderArtworkFileName
        )
        generatedHeaderArtworkFileName = try c.decodeIfPresent(
            String.self,
            forKey: .generatedHeaderArtworkFileName
        )
        headerArtworkSource = try c.decodeIfPresent(PlaylistArtworkSource.self, forKey: .headerArtworkSource)
        generatedArtworkSignature =
            try c.decodeIfPresent(String.self, forKey: .generatedArtworkSignature)
            ?? c.decodeIfPresent(String.self, forKey: .legacyHeaderArtworkSignature)
        artworkRevision = try c.decodeIfPresent(String.self, forKey: .artworkRevision)

        if version >= 2 {
            items = try c.decodeIfPresent([PlaylistItemSidecar].self, forKey: .items) ?? []
            legacyTrackIDs = nil
        } else {
            let ids =
                try c.decodeIfPresent([UUID].self, forKey: .trackIDs)
                ?? c.decodeIfPresent([UUID].self, forKey: .trackIds)
                ?? []
            items = []
            legacyTrackIDs = ids
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(4, forKey: .schemaVersion)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(description, forKey: .description)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(items, forKey: .items)
        try c.encodeIfPresent(customHeaderArtworkFileName, forKey: .customHeaderArtworkFileName)
        try c.encodeIfPresent(generatedHeaderArtworkFileName, forKey: .generatedHeaderArtworkFileName)
        try c.encodeIfPresent(headerArtworkSource, forKey: .headerArtworkSource)
        try c.encodeIfPresent(generatedArtworkSignature, forKey: .generatedArtworkSignature)
        try c.encodeIfPresent(artworkRevision, forKey: .artworkRevision)
    }
}

struct PlaylistItemSidecar: Codable {
    let trackID: UUID
    let addedAt: Date
}

enum PlaylistArtworkSource: String, Codable {
    case none
    case custom
    case generated
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

struct ArtistSidecar: Codable {
    var schemaVersion: Int
    var id: UUID
    var canonicalName: String
    var displayName: String
    var artworkFileName: String?
    var description: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        id: UUID,
        canonicalName: String,
        displayName: String,
        artworkFileName: String? = nil,
        description: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.artworkFileName = artworkFileName
        self.description = description
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct AlbumSidecar: Codable {
    var schemaVersion: Int
    var id: UUID
    var canonicalKey: String
    var displayTitle: String
    var primaryArtistCanonicalName: String
    var artworkFileName: String?
    var description: String?
    var year: Int?
    var createdAt: Date
    var updatedAt: Date

    init(
        schemaVersion: Int = 1,
        id: UUID,
        canonicalKey: String,
        displayTitle: String,
        primaryArtistCanonicalName: String,
        artworkFileName: String? = nil,
        description: String? = nil,
        year: Int? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.canonicalKey = canonicalKey
        self.displayTitle = displayTitle
        self.primaryArtistCanonicalName = primaryArtistCanonicalName
        self.artworkFileName = artworkFileName
        self.description = description
        self.year = year
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
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

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Library Setup

    func ensureLibraryFolders() {
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
            schemaVersion: 3,
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
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

        guard let data = track.artworkData, !data.isEmpty else {
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

        let dataToWrite: Data
        let encoding: String
        if isPNGData(data) {
            if dataMatches(data, existingArtworkData), existingArtworkFileName == targetArtworkFileName {
                logTrackPersistence(track: track, reason: reason, action: "artwork-skip", artwork: "encoded-unchanged")
                return existingArtworkFileName
            }
            dataToWrite = data
            encoding = "png-original"
        } else if let image = NSImage(data: data), let png = image.pngData() {
            if dataMatches(png, existingArtworkData), existingArtworkFileName == targetArtworkFileName {
                logTrackPersistence(track: track, reason: reason, action: "artwork-skip", artwork: "encoded-unchanged")
                return existingArtworkFileName
            }
            dataToWrite = png
            encoding = "png"
        } else {
            logTrackPersistence(track: track, reason: reason, action: "artwork-error", artwork: "png-encode-failed")
            throw NSError(
                domain: "LocalLibraryService.TrackPersistence",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Artwork could not be encoded as PNG"]
            )
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
            artwork: "changed encoding=\(encoding)"
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
        let folder = LocalLibraryPaths.trackFolderURL(for: track.id)
        if fileManager.fileExists(atPath: folder.path) {
            do {
                try fileManager.removeItem(at: folder)
            } catch {
                Log.error("Failed to delete track folder \(folder.lastPathComponent): \(error)", category: .library)
            }
        }
    }

    // MARK: - Playlist Sidecars

    func writePlaylist(_ playlist: Playlist, itemAddedAt: [UUID: Date]? = nil) {
        ensureLibraryFolders()
        let items = playlist.tracks.map { track in
            PlaylistItemSidecar(
                trackID: track.id,
                addedAt: itemAddedAt?[track.id] ?? Date()
            )
        }
        let desc = playlist.userDescription.isEmpty ? nil : playlist.userDescription
        let existingSidecar = loadPlaylistSidecar(playlistID: playlist.id)
        let sidecar = PlaylistSidecar(
            id: playlist.id,
            name: playlist.name,
            description: desc,
            createdAt: playlist.createdAt,
            items: items,
            customHeaderArtworkFileName: existingSidecar?.customHeaderArtworkFileName,
            generatedHeaderArtworkFileName: existingSidecar?.generatedHeaderArtworkFileName,
            headerArtworkSource: existingSidecar?.headerArtworkSource,
            generatedArtworkSignature: existingSidecar?.generatedArtworkSignature,
            artworkRevision: existingSidecar?.artworkRevision
        )

        do {
            let data = try encoder.encode(sidecar)
            let url = LocalLibraryPaths.playlistURL(for: playlist.id)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("Failed to write playlist sidecar '\(playlist.name)': \(error)", category: .library)
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
        debugArtworkPersistence(
            "selectionIdentity=\(playlistID) source=custom filePath=\(fileURL.path) save=accepted oldGeneratedDeleted=true"
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
        debugArtworkPersistence(
            "selectionIdentity=\(playlistID) source=generated filePath=\(fileURL.path) save=accepted generatedSignature=\(signature)"
        )
    }

    /// Explicitly regenerate playlist artwork from tracks and set it as the active artwork.
    /// This clears any custom artwork and forces generation (or re-generation) of the built-in cover.
    func regeneratePlaylistArtwork(
        playlistID: UUID,
        tracks: [Track],
        image: NSImage
    ) {
        let fileURL = LocalLibraryPaths.playlistGeneratedArtworkURL(for: playlistID)
        guard writePNGArtwork(image, to: fileURL) else { return }

        let existing = loadPlaylistSidecar(playlistID: playlistID)

        // Delete old custom artwork file when switching to generated
        if let customFileName = existing?.customHeaderArtworkFileName {
            let customURL = LocalLibraryPaths.playlistsRootURL
                .appendingPathComponent(customFileName)
            try? FileManager.default.removeItem(at: customURL)
        }

        // Clear custom artwork (set to nil) and set active source to generated
        updatePlaylistArtworkMetadata(
            playlistID: playlistID,
            customFileName: nil,
            generatedFileName: fileURL.lastPathComponent,
            activeSource: .generated,
            generatedSignature: nil, // Signature not used for stability anymore
            artworkRevision: UUID().uuidString
        )
        debugArtworkPersistence(
            "selectionIdentity=\(playlistID) source=generated filePath=\(fileURL.path) phase=regenerate save=accepted oldCustomDeleted=true"
        )
    }

    func loadPlaylistSidecar(playlistID: UUID) -> PlaylistSidecar? {
        let url = LocalLibraryPaths.playlistURL(for: playlistID)
        guard let data = try? Data(contentsOf: url),
              let sidecar = try? decoder.decode(PlaylistSidecar.self, from: data)
        else { return nil }
        return sidecar
    }

    private func updatePlaylistArtworkMetadata(
        playlistID: UUID,
        customFileName: String?,
        generatedFileName: String?,
        activeSource: PlaylistArtworkSource,
        generatedSignature: String?,
        artworkRevision: String?
    ) {
        guard let sidecar = loadPlaylistSidecar(playlistID: playlistID) else { return }
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
        } catch {
            Log.error("Failed to update playlist artwork metadata: \(error)", category: .library)
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

        debugArtworkPersistence(
            "selectionIdentity=\(playlistID) source=\((legacySource == .generated) ? "generated" : "custom") filePath=\(destinationURL.path) migration=legacy-single-file"
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
            let metaURL = LocalLibraryPaths.albumMetaURL(for: sidecar.id)
            let data = try encoder.encode(sidecar)
            try data.write(to: metaURL, options: .atomic)
            if let artworkData, let fileName = sidecar.artworkFileName {
                let artworkURL = folder.appendingPathComponent(fileName)
                try artworkData.write(to: artworkURL, options: .atomic)
            }
        } catch {
            Log.error("Failed to write album sidecar '\(sidecar.displayTitle)': \(error)", category: .library)
        }
    }

    func deleteArtistEntry(id: UUID) {
        let folder = LocalLibraryPaths.artistFolderURL(for: id)
        guard fileManager.fileExists(atPath: folder.path) else { return }
        try? fileManager.removeItem(at: folder)
    }

    func deleteAlbumEntry(id: UUID) {
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
            let artworkData = resolvedArtworkFileName.flatMap { fileName -> Data? in
                let url = dir.appendingPathComponent(fileName)
                return try? Data(contentsOf: url)
            }

            var ttmlText: String?
            var lyricsText: String?
            if let ttmlFileName = sidecar.ttmlLyricsFileName {
                let url = dir.appendingPathComponent(ttmlFileName)
                if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                    ttmlText = text
                }
            }
            if let lyricsFile = sidecar.lyricsFileName {
                let url = dir.appendingPathComponent(lyricsFile)
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    if lyricsFile.lowercased().hasSuffix(".ttml"), ttmlText == nil {
                        ttmlText = text
                    } else {
                        lyricsText = text
                    }
                }
            }

            let track = Track(
                id: sidecar.id,
                title: sidecar.title,
                artist: sidecar.artist,
                album: sidecar.album,
                duration: sidecar.duration,
                addedAt: sidecar.addedAt,
                importedAt: sidecar.importedAt ?? sidecar.addedAt,
                lyricsTimeOffsetMs: sidecar.lyricsTimeOffsetMs ?? 0,
                fileBookmarkData: Data(),
                originalFilePath: sidecar.originalFilePath ?? "",
                libraryRelativePath: relativePath,
                availability: isAvailable ? .available : .missing,
                artworkData: artworkData,
                ttmlLyricText: ttmlText,
                lyricsText: lyricsText
            )

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
                queue: DispatchQueue.global(qos: .utility)
            )

            source.setEventHandler { [weak self] in
                print("📝 Detected change in \(name) folder")
                self?.scheduleAvailabilitySync(repository: repository)
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

    private func scheduleAvailabilitySync(repository: LibraryRepositoryProtocol) {
        pendingSync?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                await self?.refreshAvailability(repository: repository)
            }
        }
        pendingSync = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5, execute: work)
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
