//
//  Playlist.swift
//  myPlayer2
//
//  TrueMusic - SwiftData Playlist Model
//  Represents a user-created playlist containing tracks.
//

import Foundation
import SwiftData

@Model
final class Playlist {
    // MARK: - Identifiers

    @Attribute(.unique) var id: UUID

    // MARK: - Properties

    var name: String
    var createdAt: Date

    // MARK: - Relationships

    /// Tracks in this playlist (ordered).
    /// Using array for ordered relationship.
    @Relationship var tracks: [Track] = []

    // MARK: - Initializer

    init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date = Date(),
        tracks: [Track] = []
    ) {
        self.id = id
        self.name = name
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
