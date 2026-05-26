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
}

nonisolated struct SearchIndexedDocument: Sendable {
    let trackID: UUID
    let titleRaw: String
    let titleNormalized: String
    let artistRaw: String
    let artistNormalized: String
    let albumRaw: String
    let albumNormalized: String
    let titleArtistCombinedNormalized: String
    let lyricsPlainTextRaw: String
    let lyricsPlainTextNormalized: String
    let lyricsFilePath: String?
    let lyricsFileModifiedAt: Double?
    let lyricsFileSize: Int64?
    let lyricsHash: String?
    let playCount: Int
    let preferenceScore: Double
    let lastPlayedAt: Date?
    let updatedAt: Date
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
    let lyricSnippetLine: String?
    let lyricHighlightRanges: [SearchHighlightRange]
    let matchedLyrics: Bool
}
