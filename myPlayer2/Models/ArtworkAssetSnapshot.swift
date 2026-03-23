//
//  ArtworkAssetSnapshot.swift
//  myPlayer2
//
//  kmgccc_player - Immutable snapshot of extracted artwork data
//  Caches colors and images to prevent redundant extraction.
//

import AppKit
import Foundation

final class ArtworkAssetSnapshot: NSObject, Sendable {
    let trackID: UUID
    let artworkChecksum: UInt64
    let thumbnailImage: NSImage?
    let fullImage: NSImage?
    let dominantColor: NSColor?
    let accentColor: NSColor?
    let palette: [NSColor]
    let richPalette: [NSColor]
    let averageColor: NSColor?
    let extractedAt: Date
    
    var cacheKey: String {
        "\(trackID.uuidString)-\(artworkChecksum)"
    }
    
    init(
        trackID: UUID,
        artworkChecksum: UInt64,
        thumbnailImage: NSImage? = nil,
        fullImage: NSImage? = nil,
        dominantColor: NSColor? = nil,
        accentColor: NSColor? = nil,
        palette: [NSColor] = [],
        richPalette: [NSColor] = [],
        averageColor: NSColor? = nil
    ) {
        self.trackID = trackID
        self.artworkChecksum = artworkChecksum
        self.thumbnailImage = thumbnailImage
        self.fullImage = fullImage
        self.dominantColor = dominantColor
        self.accentColor = accentColor
        self.palette = palette
        self.richPalette = richPalette
        self.averageColor = averageColor
        self.extractedAt = Date()
        super.init()
    }
}

extension NSColor: @unchecked Sendable {}
