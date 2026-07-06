//
//  PlaylistViewSnapshot.swift
//  myPlayer2
//
//  kmgccc_player - Immutable snapshot of playlist view state
//  Prevents redundant view recomputation during scrolling.
//

import Foundation

/// Immutable snapshot of a playlist's view state.
/// Contains pre-computed data for display without repeated calculations.
struct PlaylistViewSnapshot: Sendable {
    let playlistID: UUID
    let trackIDs: [UUID]
    let trackSnapshots: [UUID: TrackRowSnapshot]
    let totalDuration: Double
    let trackCount: Int
    let createdAt: Date
    
    nonisolated init(
        playlistID: UUID,
        trackIDs: [UUID],
        trackSnapshots: [UUID: TrackRowSnapshot],
        totalDuration: Double
    ) {
        self.playlistID = playlistID
        self.trackIDs = trackIDs
        self.trackSnapshots = trackSnapshots
        self.totalDuration = totalDuration
        self.trackCount = trackIDs.count
        self.createdAt = Date()
    }
    
    /// Empty snapshot for loading states.
    nonisolated static var empty: PlaylistViewSnapshot {
        PlaylistViewSnapshot(
            playlistID: UUID(),
            trackIDs: [],
            trackSnapshots: [:],
            totalDuration: 0
        )
    }
}

/// Pre-computed data for a single track row.
struct TrackRowSnapshot: Sendable {
    let trackID: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let durationText: String
    let artworkChecksum: UInt64
    let artworkData: Data?
    let artworkCacheKey: String
    let isMissing: Bool
    let sortIndex: Int
    
    nonisolated var displayTitle: String {
        title.isEmpty ? "Unknown Title" : title
    }
    
    nonisolated var displayArtist: String {
        artist.isEmpty ? "Unknown Artist" : artist
    }
}

// MARK: - Convenience

extension PlaylistViewSnapshot {
    /// Get snapshot for a specific track.
    nonisolated func snapshot(for trackID: UUID) -> TrackRowSnapshot? {
        trackSnapshots[trackID]
    }
    
    /// Formatted total duration.
    nonisolated var totalDurationText: String {
        let hours = Int(totalDuration) / 3600
        let minutes = (Int(totalDuration) % 3600) / 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, Int(totalDuration) % 60)
        } else {
            return String(format: "%d:%02d", minutes, Int(totalDuration) % 60)
        }
    }
    
    /// Whether this snapshot contains any tracks.
    nonisolated var isEmpty: Bool {
        trackIDs.isEmpty
    }
}
