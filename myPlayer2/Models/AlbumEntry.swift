//
//  AlbumEntry.swift
//  myPlayer2
//
//  In-memory album metadata loaded from disk sidecar + derived stats from song library.
//

import Foundation

struct AlbumEntry: Identifiable {
    // Persistent fields (from sidecar)
    let id: UUID
    let canonicalKey: String        // normalized album+artist key
    var displayTitle: String
    var primaryArtistCanonicalName: String
    var primaryArtistDisplayName: String
    var artworkFileName: String?
    var description: String
    var year: Int?
    var artworkData: Data?          // user-set artwork or first track's artwork (not persisted in sidecar)
    var createdAt: Date
    var updatedAt: Date

    // Derived fields (populated at sync time, not persisted)
    var trackCount: Int
    var totalDuration: Double
    var isOrphaned: Bool            // runtime-only: true if no matching songs exist
}
