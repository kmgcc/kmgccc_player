//
//  AMLLDBIndexEntry.swift
//  myPlayer2
//
//  kmgccc_player - AMLLDB Index Entry SwiftData Model
//  Stores metadata for AMLLDB lyrics index entries.
//

import Foundation
import SwiftData

/// Represents a single entry in the AMLLDB lyrics index.
/// Used for local fuzzy searching of song lyrics.
@Model
final class AMLLDBIndexEntry {
    
    // MARK: - Identifiers
    
    /// NetEase Cloud Music ID (unique identifier)
    @Attribute(.unique) var ncmMusicId: String
    
    // MARK: - Song Metadata
    
    /// Song title
    var musicName: String
    
    /// Artist name(s) - comma separated for multiple artists
    var artists: String
    
    /// Album name
    var album: String
    
    // MARK: - File Reference
    
    /// Raw lyric file name in the AMLLDB repository (e.g., "1740814274356-146098469-efb9e56e.ttml")
    var rawLyricFile: String
    
    // MARK: - Update Tracking
    
    /// When this entry was last updated in the local database
    var lastUpdated: Date
    
    // MARK: - Initializer
    
    init(
        ncmMusicId: String,
        musicName: String,
        artists: String,
        album: String,
        rawLyricFile: String,
        lastUpdated: Date = Date()
    ) {
        self.ncmMusicId = ncmMusicId
        self.musicName = musicName
        self.artists = artists
        self.album = album
        self.rawLyricFile = rawLyricFile
        self.lastUpdated = lastUpdated
    }
}

// MARK: - Search Helpers

extension AMLLDBIndexEntry {
    /// Combined searchable text (title + artists) for fuzzy matching
    var searchableText: String {
        "\(musicName) \(artists)"
    }
    
    /// Check if this entry matches the given title query (case-insensitive)
    func matchesTitle(_ query: String) -> Bool {
        musicName.localizedCaseInsensitiveContains(query)
    }
    
    /// Check if this entry matches the given artist query (case-insensitive)
    func matchesArtist(_ query: String) -> Bool {
        artists.localizedCaseInsensitiveContains(query)
    }
}
