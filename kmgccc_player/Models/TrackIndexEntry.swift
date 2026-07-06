//
//  TrackIndexEntry.swift
//  myPlayer2
//
//  SwiftData index cache only (non-authoritative).
//

import Foundation
import SwiftData

@Model
final class TrackIndexEntry {
    @Attribute(.unique) var id: UUID
    var libraryRelativePath: String
    var normalizedTitle: String
    var normalizedArtist: String
    var duration: Double
    var indexedAt: Date

    init(
        id: UUID,
        libraryRelativePath: String,
        normalizedTitle: String,
        normalizedArtist: String,
        duration: Double,
        indexedAt: Date = Date()
    ) {
        self.id = id
        self.libraryRelativePath = libraryRelativePath
        self.normalizedTitle = normalizedTitle
        self.normalizedArtist = normalizedArtist
        self.duration = duration
        self.indexedAt = indexedAt
    }
}
