//
//  LibraryTrackSnapshotBuilder.swift
//  myPlayer2
//
//  kmgccc_player - Builds playlist view snapshots in background
//  Offloads track row computation from main thread.
//

import Foundation

/// Actor-isolated builder for creating playlist view snapshots.
/// Processes track data in background to keep UI responsive.
actor LibraryTrackSnapshotBuilder {
    
    static let shared = LibraryTrackSnapshotBuilder()
    
    private var buildTask: Task<PlaylistViewSnapshot, Error>?
    private var lastBuildID: UUID?
    
    private init() {}
    
    /// Build a snapshot for a playlist asynchronously.
    func buildSnapshot(
        playlistID: UUID,
        tracks: [Track],
        sortOrder: SortOrder
    ) async -> PlaylistViewSnapshot {
        // Process tracks in batches for cancellation responsiveness
        let batchSize = 50
        var trackIDs: [UUID] = []
        var trackSnapshots: [UUID: TrackRowSnapshot] = [:]
        var totalDuration: Double = 0
        
        // Process in batches
        for (index, track) in tracks.enumerated() {
            if Task.isCancelled {
                return await MainActor.run { PlaylistViewSnapshot.empty }
            }
            
            let snapshot = await MainActor.run {
                TrackRowSnapshot(
                    trackID: track.id,
                    title: track.title,
                    artist: track.artist,
                    album: track.album,
                    duration: track.duration,
                    durationText: Self.formatDuration(track.duration),
                    artworkChecksum: track.artworkData?.checksum ?? 0,
                    sortIndex: index + 1
                )
            }
            
            trackSnapshots[track.id] = snapshot
            trackIDs.append(track.id)
            totalDuration += track.duration
            
            // Yield every batch
            if index % batchSize == 0 {
                await Task.yield()
            }
        }
        
        return await MainActor.run {
            PlaylistViewSnapshot(
                playlistID: playlistID,
                trackIDs: trackIDs,
                trackSnapshots: trackSnapshots,
                totalDuration: totalDuration
            )
        }
    }
    
    /// Cancel current build if any.
    func cancelBuild() {
    }
    
    private static func formatDuration(_ duration: Double) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Sort Order

enum SortOrder: String, CaseIterable, Sendable {
    case manual = "manual"
    case title = "title"
    case artist = "artist"
    case album = "album"
    case duration = "duration"
    case dateAdded = "dateAdded"
}

// MARK: - Data Extensions

extension Data {
    /// Simple checksum for artwork deduplication.
    var checksum: UInt64 {
        guard count >= 8 else {
            var padded = self
            while padded.count < 8 { padded.append(0) }
            return padded.withUnsafeBytes { $0.load(as: UInt64.self) }
        }
        return withUnsafeBytes { $0.load(as: UInt64.self) }
    }
}
