//
//  ImportTypes.swift
//  myPlayer2
//

import Foundation

nonisolated protocol EmbeddedLyricsTTMLConverting: Sendable {
    func convertToTTML(rawLyrics: String, stripMetadata: Bool) async throws -> String
}

extension TTMLConverter: EmbeddedLyricsTTMLConverting {}

nonisolated struct ImportPreview: Sendable {
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let duration: Double
    let lyrics: String?
    let artworkData: Data?
}

nonisolated struct TrackPreview: Sendable {
    let title: String
    let artist: String
    let artworkData: Data?
}

nonisolated struct DuplicatePairRow: Identifiable, Sendable {
    let id: String
    let fileURL: URL
    let incoming: ImportPreview
    let existing: TrackPreview?
    let existingCount: Int
    let dedupKey: String
}

nonisolated enum ImportEnrichmentMode: Sendable {
    case immediate
    case deferred

    var defersEnrichment: Bool {
        self == .deferred
    }
}

nonisolated enum ImportLyricsLookupOutcome: Sendable {
    case completed(String)
    case noResults
    case failed(String)
}

nonisolated enum ImportCoverLookupOutcome: Sendable {
    case completed(Data)
    case noResults
    case failed(String)
}

struct ImportCandidate: Sendable {
    let progressID: String
    let displayName: String
    let fileURL: URL
    let metadata: ImportPreview
}

struct ResolvedImportFile: Sendable {
    let progressID: String
    let displayName: String
    let fileURL: URL
    let ncmResult: NCMConversionResult?
}

struct ImportedTrackRecord {
    let progressID: String
    let displayName: String
    let track: Track
    let needsLyricsEnrichment: Bool
    let needsCoverEnrichment: Bool

    var needsAnyEnrichment: Bool {
        needsLyricsEnrichment || needsCoverEnrichment
    }
}

struct ImportedTrackEnrichmentPatch: Sendable {
    let trackID: UUID
    let ttmlLyricText: String?
    let artworkData: Data?

    var hasChanges: Bool {
        ttmlLyricText != nil || artworkData != nil
    }

    func apply(to track: Track) {
        if track.ttmlLyricText == nil, let ttmlLyricText {
            track.ttmlLyricText = ttmlLyricText
        }
        if track.artworkData == nil, let artworkData {
            track.artworkData = artworkData
        }
    }
}

struct ImportedTrackPayload: Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let albumArtist: String?
    let duration: Double
    let importedAt: Date
    let originalFilePath: String
    let libraryRelativePath: String
    let artworkData: Data?
    let ttmlLyricText: String?
    let lyricsText: String?
}

struct ExistingTrackMatchSnapshot: Sendable {
    let preview: TrackPreview?
    let count: Int
}

struct CandidatePreparationResult: Sendable {
    let index: Int
    let candidate: ImportCandidate
    let duplicateRow: DuplicatePairRow?
}

struct NCMConversionTaskOutput: Sendable {
    let sourceURL: URL
    let displayName: String
    let result: NCMConversionResult?
    let errorDescription: String?
}

struct ImportTaskOutput: Sendable {
    let index: Int
    let progressID: String
    let displayName: String
    let metadata: ImportPreview
    let payload: ImportedTrackPayload?
    let needsLyricsEnrichment: Bool
    let needsCoverEnrichment: Bool
    let errorDescription: String?
}

struct ImportEnrichmentSnapshot: Sendable {
    let progressID: String
    let id: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double?
    let needsLyrics: Bool
    let needsCover: Bool
}

struct ImportEnrichmentTaskOutput: Sendable {
    let progressID: String
    let trackID: UUID
    let title: String
    let artist: String
    let album: String
    let lyricOutcome: ImportLyricsLookupOutcome?
    let coverOutcome: ImportCoverLookupOutcome?
}

struct ImmediateImportEnrichmentUpdate: Sendable {
    let progressID: String
    let trackID: UUID
    let title: String
    let artist: String
    let status: BatchImportItemStatus
    let detail: String
    let lyricSuccessCount: Int
    let coverSuccessCount: Int
    let noResultCount: Int
    let failedCount: Int
    let patch: ImportedTrackEnrichmentPatch
}
