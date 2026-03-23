//
//  TrackVisualSnapshot.swift
//  myPlayer2
//
//  kmgccc_player - Static visual properties for a track
//  Separates visual data from dynamic playback state for performance.
//

import AppKit
import Foundation

/// Immutable snapshot of static visual properties for a track.
/// These properties change only when the track or its artwork changes,
/// not during playback progress updates.
struct TrackVisualSnapshot: Hashable, Sendable, Equatable {
    let trackID: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    
    // Artwork (cached from ArtworkAssetStore)
    let artworkChecksum: UInt64
    let thumbnailImage: NSImage?
    let fullImage: NSImage?
    
    // Extracted colors (cached from ArtworkAssetStore)
    let dominantColor: NSColor?
    let accentColor: NSColor?
    let palette: [NSColor]
    let richPalette: [NSColor]
    let averageColor: NSColor?
    
    // When this snapshot was created
    let createdAt: Date
    
    init(
        trackID: UUID,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        artworkChecksum: UInt64 = 0,
        thumbnailImage: NSImage? = nil,
        fullImage: NSImage? = nil,
        dominantColor: NSColor? = nil,
        accentColor: NSColor? = nil,
        palette: [NSColor] = [],
        richPalette: [NSColor] = [],
        averageColor: NSColor? = nil
    ) {
        self.trackID = trackID
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.artworkChecksum = artworkChecksum
        self.thumbnailImage = thumbnailImage
        self.fullImage = fullImage
        self.dominantColor = dominantColor
        self.accentColor = accentColor
        self.palette = palette
        self.richPalette = richPalette
        self.averageColor = averageColor
        self.createdAt = Date()
    }
    
    // MARK: - Derived Properties
    
    /// The best color for theming.
    var themeColor: NSColor? {
        accentColor ?? dominantColor ?? averageColor
    }
    
    /// Formatted duration string.
    var durationText: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
    
    /// Display title (falls back to "Unknown Title").
    var displayTitle: String {
        title.isEmpty ? "Unknown Title" : title
    }
    
    /// Display artist (falls back to "Unknown Artist").
    var displayArtist: String {
        artist.isEmpty ? "Unknown Artist" : artist
    }
    
    // MARK: - Hashable
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(trackID)
        hasher.combine(artworkChecksum)
    }
    
    static func == (lhs: TrackVisualSnapshot, rhs: TrackVisualSnapshot) -> Bool {
        lhs.trackID == rhs.trackID && lhs.artworkChecksum == rhs.artworkChecksum
    }
}

// MARK: - Convenience

extension TrackVisualSnapshot {
    /// Create from a Track model and ArtworkAssetSnapshot.
    static func from(track: Track, artwork: ArtworkAssetSnapshot?) -> TrackVisualSnapshot {
        TrackVisualSnapshot(
            trackID: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkChecksum: artwork?.artworkChecksum ?? 0,
            thumbnailImage: artwork?.thumbnailImage,
            fullImage: artwork?.fullImage,
            dominantColor: artwork?.dominantColor,
            accentColor: artwork?.accentColor,
            palette: artwork?.palette ?? [],
            richPalette: artwork?.richPalette ?? [],
            averageColor: artwork?.averageColor
        )
    }
    
    /// Empty snapshot for placeholder states.
    static var empty: TrackVisualSnapshot {
        TrackVisualSnapshot(
            trackID: UUID(),
            title: "",
            artist: "",
            album: "",
            duration: 0
        )
    }
}
