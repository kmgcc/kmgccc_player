//
//  Playlist.swift
//  myPlayer2
//
//  kmgccc_player - SwiftData Playlist Model
//  Represents a user-created playlist containing tracks.
//

import Foundation
import Observation

@Observable
final class Playlist: Identifiable, Hashable, Equatable {
    var id: UUID

    var name: String
    var userDescription: String = ""
    var createdAt: Date

    /// Tracks in this playlist (ordered).
    var tracks: [Track] = []

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

    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
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
