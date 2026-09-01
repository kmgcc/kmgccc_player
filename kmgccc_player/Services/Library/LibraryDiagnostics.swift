//
//  LibraryDiagnostics.swift
//  myPlayer2
//
//  Rebuildable local-library health, quality and duplicate projections.
//
//  This file intentionally contains no persistence or destructive action. The
//  source of truth remains Track and its locator; diagnostics are a derived
//  snapshot that can be discarded and rebuilt at any time.
//

import Foundation

nonisolated struct LibraryTrackDiagnosticInput: Sendable, Equatable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let availability: TrackAvailability
    let format: String
    let codec: String?
    let fileSize: Int64?
    let physicalKey: String?
    let metadataKey: String?
    let path: String
    let storageKind: LocalTrackStorageKind

    init(
        id: UUID,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        availability: TrackAvailability,
        format: String,
        codec: String? = nil,
        fileSize: Int64?,
        physicalKey: String?,
        metadataKey: String?,
        path: String,
        storageKind: LocalTrackStorageKind
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.availability = availability
        self.format = format
        self.codec = codec
        self.fileSize = fileSize
        self.physicalKey = physicalKey
        self.metadataKey = metadataKey
        self.path = path
        self.storageKind = storageKind
    }
}

nonisolated enum LibraryDuplicateReason: String, Codable, Sendable, Equatable {
    case samePhysicalFile
    case sameMetadata

    var displayName: String {
        switch self {
        case .samePhysicalFile:
            return "同一个文件被重复记录"
        case .sameMetadata:
            return "歌曲信息高度相同"
        }
    }
}

nonisolated struct LibraryDuplicateGroup: Identifiable, Codable, Sendable, Equatable {
    let key: String
    let reason: LibraryDuplicateReason
    let trackIDs: [UUID]
    let title: String
    let artist: String
    let paths: [String]

    var id: String { key }
}

nonisolated struct LibraryQualitySummary: Codable, Sendable, Equatable {
    let totalTracks: Int
    let playableTracks: Int
    let staleTracks: Int
    let missingTracks: Int
    let offlineTracks: Int
    let permissionDeniedTracks: Int
    let checkingTracks: Int
    let totalDuration: Double
    let totalBytes: Int64
    let formatCounts: [String: Int]

    static let empty = LibraryQualitySummary(
        totalTracks: 0,
        playableTracks: 0,
        staleTracks: 0,
        missingTracks: 0,
        offlineTracks: 0,
        permissionDeniedTracks: 0,
        checkingTracks: 0,
        totalDuration: 0,
        totalBytes: 0,
        formatCounts: [:]
    )

    var unavailableTracks: Int {
        totalTracks - playableTracks
    }

    var topFormats: [(format: String, count: Int)] {
        formatCounts
            .map { (format: $0.key, count: $0.value) }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.format < $1.format
            }
    }
}

nonisolated struct LibraryDiagnosticsSnapshot: Codable, Sendable, Equatable {
    let generatedAt: Date
    let summary: LibraryQualitySummary
    let duplicateGroups: [LibraryDuplicateGroup]

    static let empty = LibraryDiagnosticsSnapshot(
        generatedAt: .distantPast,
        summary: .empty,
        duplicateGroups: []
    )
}

/// Pure analyzer used by the session view model and by tests. It does not
/// touch SwiftData, the file system, or source sidecars, so a large-library
/// calculation can run off the main actor safely.
nonisolated enum LibraryDiagnosticsAnalyzer {
    static func analyze(
        _ tracks: [LibraryTrackDiagnosticInput],
        generatedAt: Date = Date()
    ) -> LibraryDiagnosticsSnapshot {
        var playableTracks = 0
        var staleTracks = 0
        var missingTracks = 0
        var offlineTracks = 0
        var permissionDeniedTracks = 0
        var checkingTracks = 0
        var totalDuration = 0.0
        var totalBytes: Int64 = 0
        var formatCounts: [String: Int] = [:]
        var physicalGroups: [String: [LibraryTrackDiagnosticInput]] = [:]
        var metadataGroups: [String: [LibraryTrackDiagnosticInput]] = [:]

        for track in tracks {
            if track.availability.isPlayable { playableTracks += 1 }
            if track.availability == .stale { staleTracks += 1 }
            if track.availability == .missing { missingTracks += 1 }
            if track.availability == .volumeUnavailable || track.availability == .notDownloaded {
                offlineTracks += 1
            }
            if track.availability == .permissionDenied { permissionDeniedTracks += 1 }
            if track.availability == .checking { checkingTracks += 1 }

            if track.duration.isFinite, track.duration > 0 {
                totalDuration += track.duration
            }
            if let fileSize = track.fileSize, fileSize > 0 {
                totalBytes += fileSize
            }

            let format = track.format.isEmpty ? "unknown" : track.format
            let codec = track.codec?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayFormat: String
            if let codec, !codec.isEmpty, codec.caseInsensitiveCompare(format) != .orderedSame {
                displayFormat = "\(format) · \(codec)"
            } else {
                displayFormat = format
            }
            formatCounts[displayFormat, default: 0] += 1

            if let physicalKey = track.physicalKey {
                physicalGroups[physicalKey, default: []].append(track)
            }
            if let metadataKey = track.metadataKey {
                metadataGroups[metadataKey, default: []].append(track)
            }
        }

        let physicalDuplicates = makeGroups(
            physicalGroups,
            reason: .samePhysicalFile,
            keyPrefix: "physical"
        )
        let metadataDuplicates = makeGroups(
            metadataGroups,
            reason: .sameMetadata,
            keyPrefix: "metadata"
        )
        let duplicateGroups = (physicalDuplicates + metadataDuplicates).sorted {
            if $0.reason != $1.reason {
                return $0.reason == .samePhysicalFile
            }
            if $0.title != $1.title {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return $0.key < $1.key
        }

        return LibraryDiagnosticsSnapshot(
            generatedAt: generatedAt,
            summary: LibraryQualitySummary(
                totalTracks: tracks.count,
                playableTracks: playableTracks,
                staleTracks: staleTracks,
                missingTracks: missingTracks,
                offlineTracks: offlineTracks,
                permissionDeniedTracks: permissionDeniedTracks,
                checkingTracks: checkingTracks,
                totalDuration: totalDuration,
                totalBytes: totalBytes,
                formatCounts: formatCounts
            ),
            duplicateGroups: duplicateGroups
        )
    }

    private static func makeGroups(
        _ groups: [String: [LibraryTrackDiagnosticInput]],
        reason: LibraryDuplicateReason,
        keyPrefix: String
    ) -> [LibraryDuplicateGroup] {
        groups.compactMap { rawKey, tracks in
            guard tracks.count > 1 else { return nil }
            let sortedTracks = tracks.sorted { $0.id.uuidString < $1.id.uuidString }
            let first = sortedTracks[0]
            return LibraryDuplicateGroup(
                key: "\(keyPrefix):\(rawKey)",
                reason: reason,
                trackIDs: sortedTracks.map(\.id),
                title: first.title,
                artist: first.artist,
                paths: sortedTracks.map(\.path).filter { !$0.isEmpty }
            )
        }
    }
}

@MainActor
enum LibraryTrackDiagnosticInputBuilder {
    static func make(from track: Track) -> LibraryTrackDiagnosticInput {
        let locator = track.mediaLocator
        let rawPath: String
        let fileSize: Int64?
        let physicalKey: String?
        let audioProperties: TrackAudioProperties?

        switch locator {
        case let .managed(libraryRelativePath):
            rawPath = libraryRelativePath
            fileSize = nil
            physicalKey = nil
            audioProperties = track.audioProperties
        case let .referenced(locator):
            rawPath = locator.lastKnownPath
            fileSize = locator.fingerprint?.fileSize
            physicalKey = locator.fingerprint.flatMap {
                Self.physicalKey(for: $0, path: rawPath)
            }
            audioProperties = locator.primaryAudioProperties ?? track.audioProperties
        }

        let format = URL(fileURLWithPath: rawPath).pathExtension.lowercased()
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = track.artistCreditsDisplayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
        let metadataKey: String?
        if title.isEmpty && artist.isEmpty && album.isEmpty {
            metadataKey = nil
        } else {
            let durationKey = track.duration.isFinite && track.duration > 0
                ? String(Int(track.duration.rounded()))
                : "unknown"
            metadataKey = [
                LibraryNormalization.normalizeTitle(title),
                LibraryNormalization.normalizeArtist(artist),
                LibraryNormalization.normalizeAlbum(album),
                durationKey
            ].joined(separator: "|")
        }

        return LibraryTrackDiagnosticInput(
            id: track.id,
            title: title.isEmpty ? LibraryNormalization.unknownTitle : title,
            artist: artist.isEmpty ? LibraryNormalization.unknownArtist : artist,
            album: album,
            duration: track.duration,
            availability: track.availability,
            format: format,
            codec: audioProperties?.codec,
            fileSize: fileSize,
            physicalKey: physicalKey,
            metadataKey: metadataKey,
            path: rawPath,
            storageKind: locator.storageKind
        )
    }

    private static func physicalKey(
        for fingerprint: ReferencedFileFingerprint,
        path: String
    ) -> String? {
        if let identity = fingerprint.identity {
            let volume = identity.volumeUUID ?? ""
            let resource = identity.resourceIdentifierArchive?.base64EncodedString() ?? ""
            // A volume identifier alone is not a file identity. Require the
            // resource identifier before treating two records as the same
            // physical file; otherwise fall back to a conservative candidate.
            if !resource.isEmpty {
                return "identity:\(volume):\(resource)"
            }
        }
        guard fingerprint.fileSize > 0 else { return nil }
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return "fingerprint:\(fingerprint.fileSize):\(fingerprint.modifiedAt):\(normalizedPath)"
    }
}
