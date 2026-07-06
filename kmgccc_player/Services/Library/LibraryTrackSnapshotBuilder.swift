//
//  LibraryTrackSnapshotBuilder.swift
//  myPlayer2
//
//  kmgccc_player - Builds playlist view snapshots in background
//  Offloads track row computation from main thread.
//

import CoreGraphics
import Foundation

struct TrackRowBuildInput: Sendable {
    let trackID: UUID
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let artworkData: Data?
    let isMissing: Bool
}

/// Actor-isolated builder for creating playlist view snapshots.
/// Processes track data in background to keep UI responsive.
actor LibraryTrackSnapshotBuilder {

    static let shared = LibraryTrackSnapshotBuilder()

    private var buildGeneration: UInt64 = 0

    private init() {}

    /// Build a snapshot for a playlist asynchronously.
    /// Returns nil when the build was cancelled or superseded, so callers can
    /// keep the current UI instead of replacing it with an empty snapshot.
    func buildSnapshot(
        playlistID: UUID,
        tracks: [TrackRowBuildInput],
        targetPixelSize: CGSize
    ) async -> PlaylistViewSnapshot? {
        let generation = buildGeneration
        let batchSize = 50
        var trackIDs: [UUID] = []
        var trackSnapshots: [UUID: TrackRowSnapshot] = [:]
        var totalDuration: Double = 0

        for (index, track) in tracks.enumerated() {
            if Task.isCancelled || generation != buildGeneration {
                return nil
            }

            let checksum = ArtworkLoader.checksum(for: track.artworkData)
            let cacheKey = ArtworkLoader.cacheKey(
                trackID: track.trackID,
                checksum: checksum,
                targetPixelSize: targetPixelSize
            )
            let snapshot = TrackRowSnapshot(
                trackID: track.trackID,
                title: track.title,
                artist: track.artist,
                album: track.album,
                duration: track.duration,
                durationText: Self.formatDuration(track.duration),
                artworkChecksum: checksum,
                artworkData: track.artworkData,
                artworkCacheKey: cacheKey,
                isMissing: track.isMissing,
                sortIndex: index + 1
            )

            trackSnapshots[track.trackID] = snapshot
            trackIDs.append(track.trackID)
            totalDuration += track.duration

            if (index + 1).isMultiple(of: batchSize) {
                await Task.yield()
            }
        }

        if generation != buildGeneration {
            return nil
        }

        return PlaylistViewSnapshot(
            playlistID: playlistID,
            trackIDs: trackIDs,
            trackSnapshots: trackSnapshots,
            totalDuration: totalDuration
        )
    }

    /// Cancel current build if any.
    func cancelBuild() {
        buildGeneration &+= 1
    }

    private static func formatDuration(_ duration: Double) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
