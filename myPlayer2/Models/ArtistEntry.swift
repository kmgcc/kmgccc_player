//
//  ArtistEntry.swift
//  myPlayer2
//
//  In-memory artist metadata loaded from disk sidecar + derived stats from song library.
//

import Foundation

struct ArtistEntry: Identifiable {
    // Persistent fields (from sidecar)
    let id: UUID
    let canonicalName: String
    var displayName: String
    var artworkFileName: String?
    var description: String
    var artworkData: Data?      // loaded from artwork file if artworkFileName is set
    var createdAt: Date
    var updatedAt: Date

    // Derived fields (populated at sync time, not persisted)
    var trackCount: Int
    var albumCount: Int
    var totalDuration: Double
    var isOrphaned: Bool        // runtime-only: true if no matching songs exist
}
