//
//  SearchDocument.swift
//  myPlayer2
//
//  Pure-data models for the persistent library search index.
//

import Foundation

nonisolated struct SearchDocumentSource: Sendable {
    let trackID: UUID
    let titleRaw: String
    let artistRaw: String
    let albumRaw: String
    let albumArtistRaw: String?
    let ttmlLyricsFileURL: URL?
    let plainLyricsFileURL: URL?
    let inlineTTMLText: String?
    let inlinePlainLyricsText: String?
    let playCount: Int
    let preferenceScore: Double
    let lastPlayedAt: Date?
    let updatedAt: Date
    /// Structured credits are indexed alongside the legacy raw artist field.
    /// The raw field stays untouched for display and round-trip fidelity.
    let artistCreditsRaw: String?
    /// Original/source path is searchable, but is not used as the display title.
    let filePathRaw: String?
    /// File format is indexed separately so callers can scope searches to a
    /// format without parsing a display path.
    let formatRaw: String?
}

nonisolated struct SearchIndexedDocument: Sendable {
    let trackID: UUID
    let titleRaw: String
    let titleNormalized: String
    let artistRaw: String
    let artistNormalized: String
    let albumRaw: String
    let albumNormalized: String
    let albumArtistRaw: String
    let albumArtistNormalized: String
    let artistCreditsRaw: String
    let artistCreditsNormalized: String
    let filePathRaw: String
    let filePathNormalized: String
    let formatRaw: String
    let formatNormalized: String
    let titleArtistCombinedNormalized: String
    let lyricsPlainTextRaw: String
    let lyricsPlainTextNormalized: String
    let lyricLineStartTimes: [Double?]
    let lyricsFilePath: String?
    let lyricsFileModifiedAt: Double?
    let lyricsFileSize: Int64?
    let lyricsHash: String?
    let playCount: Int
    let preferenceScore: Double
    let lastPlayedAt: Date?
    let updatedAt: Date
}

nonisolated enum LibrarySearchField: String, CaseIterable, Hashable, Sendable {
    case all
    case title
    case artist
    case album
    case albumArtist
    case path
    case format
    case lyrics
}

nonisolated enum LibrarySearchSort: String, CaseIterable, Equatable, Sendable {
    case relevance
    case title
    case artist
    case album
    case newest
}

nonisolated struct SearchHighlightRange: Sendable, Hashable {
    let location: Int
    let length: Int

    init(location: Int, length: Int) {
        self.location = max(0, location)
        self.length = max(0, length)
    }
}

nonisolated struct LibrarySearchHit: Sendable, Equatable {
    let trackID: UUID
    let score: Double
    let titleSortKey: String
    let artistSortKey: String
    let albumSortKey: String
    let newestSortValue: Double
    let lyricSnippetLine: String?
    let lyricSnippetStartTime: Double?
    let lyricHighlightRanges: [SearchHighlightRange]
    let matchedLyrics: Bool
}
