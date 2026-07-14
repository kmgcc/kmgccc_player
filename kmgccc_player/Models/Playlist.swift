//
//  Playlist.swift
//  myPlayer2
//
//  kmgccc_player - SwiftData Playlist Model
//  Represents a user-created playlist containing tracks.
//

import Foundation
import SwiftData

@Model
final class Playlist {
    @Attribute(.unique) var id: UUID

    var name: String
    var userDescription: String = ""
    var createdAt: Date

    /// Tracks in this playlist (ordered).
    /// Using array for ordered relationship.
    @Relationship var tracks: [Track] = []

    init(
        id: UUID = UUID(),
        name: String,
        userDescription: String = "",
        createdAt: Date = Date(),
        tracks: [Track] = []
    ) {
        self.id = id
        self.name = name
        self.userDescription = userDescription
        self.createdAt = createdAt
        self.tracks = tracks
    }

    // MARK: - Computed Properties

    /// Total duration of all tracks in seconds.
    var totalDuration: Double {
        tracks.reduce(0) { $0 + $1.duration }
    }

    /// Number of tracks in the playlist.
    var trackCount: Int {
        tracks.count
    }
}
