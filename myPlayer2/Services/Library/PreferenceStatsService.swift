//
//  PreferenceStatsService.swift
//  myPlayer2
//
//  Smart Shuffle - Preference Statistics Service
//  Manages loading, caching, and persisting track preference statistics.
//

import Foundation
import SwiftData

/// Service responsible for managing track preference statistics.
/// Caches stats in memory and persists to meta.json sidecars.
@MainActor
final class PreferenceStatsService {

    static let shared = PreferenceStatsService()

    // MARK: - Cache

    /// In-memory cache of track stats (trackID -> stats).
    /// Access is serialized by this service's @MainActor isolation.
    private var statsCache: [UUID: TrackPreferenceStats] = [:]

    /// Set of track IDs with unsaved changes.
    private var dirtyTrackIDs: Set<UUID> = []

    // MARK: - Initialization

    private init() {}

    // MARK: - Stats Access

    /// Get stats for a track (from cache or creates default).
    func getStats(for trackID: UUID) -> TrackPreferenceStats {
        if let cached = statsCache[trackID] {
            return cached
        }

        // Return default stats for new tracks.
        return TrackPreferenceStats()
    }

    /// Get stats for multiple tracks.
    func getStats(for trackIDs: [UUID]) -> [UUID: TrackPreferenceStats] {
        var result: [UUID: TrackPreferenceStats] = [:]
        for trackID in trackIDs {
            result[trackID] = statsCache[trackID] ?? TrackPreferenceStats()
        }
        return result
    }

    /// Get cached base weight for a track (long-term preference only).
    /// Runtime shuffle penalties are applied by ShuffleSession and are not written here.
    func getEffectiveWeight(for trackID: UUID) -> Double {
        let stats = getStats(for: trackID)
        return stats.effectiveWeightCache
    }

    /// Get preference score for a track.
    func getPreferenceScore(for trackID: UUID) -> Double {
        let stats = getStats(for: trackID)
        return stats.preferenceScoreCache
    }

    // MARK: - Stats Updates

    /// Update stats for a track.
    /// 使用 V2 评分器计算基础权重。
    @discardableResult
    func updateStats(for trackID: UUID, duration: Double, update: (inout TrackPreferenceStats) -> Void) -> Bool {
        let originalStats = statsCache[trackID] ?? TrackPreferenceStats()
        var stats = originalStats
        update(&stats)

        // 使用 V2 评分器重新计算缓存值
        _ = PreferenceScorerV2.updateCachedScores(stats: &stats, duration: duration)

        guard stats != originalStats else {
            return false
        }

        statsCache[trackID] = stats
        dirtyTrackIDs.insert(trackID)
        return true
    }

    /// Legacy wrapper for backward compatibility (uses default duration)
    @discardableResult
    func updateStats(for trackID: UUID, update: (inout TrackPreferenceStats) -> Void) -> Bool {
        updateStats(for: trackID, duration: 0, update: update)
    }

    /// Apply a playback session outcome to a track's stats.
    ///
    /// This is the single authoritative runtime mapping from playback outcome to stats:
    /// play counts, complete/skip/quick-skip counts, played seconds, timestamps, and
    /// cached V2 preference scores all flow through this method.
    @discardableResult
    func applyPlaybackOutcome(trackID: UUID, outcome: PlaybackSessionOutcome, trackDuration: Double) -> Bool {
        switch outcome {
        case .tooShort:
            return false
        default:
            break
        }

        let finalizedAt = Date()
        return updateStats(for: trackID, duration: trackDuration) { stats in
            switch outcome {
            case .completed(_, _, let playedSeconds):
                stats.playCount += 1
                stats.completePlayCount += 1
                stats.totalPlayedSeconds += playedSeconds
                stats.lastPlayedAt = finalizedAt
                stats.lastCompletedAt = finalizedAt

            case .skipped(_, let progress, let playedSeconds, let allowsQuickSkip):
                stats.playCount += 1
                stats.skipCount += 1
                stats.totalPlayedSeconds += playedSeconds
                stats.lastPlayedAt = finalizedAt
                stats.lastSkippedAt = finalizedAt

                // Check for quick skip.
                let isQuick = playedSeconds < PlaybackSessionTracker.quickSkipDuration
                    || progress < PlaybackSessionTracker.quickSkipPercentage
                if allowsQuickSkip && isQuick {
                    stats.quickSkipCount += 1
                }

            case .interrupted(_, _, let playedSeconds):
                // Interrupted plays count as plays but not skips.
                stats.playCount += 1
                stats.totalPlayedSeconds += playedSeconds
                stats.lastPlayedAt = finalizedAt

            case .tooShort:
                break
            }
        }
    }

    /// Set manual like state for a track.
    func setManualLikeState(trackID: UUID, state: ManualLikeState) {
        updateStats(for: trackID) { stats in
            stats.manualLikeState = state
        }
    }

    /// Toggle manual like state (none -> liked -> disliked -> none).
    func toggleManualLikeState(trackID: UUID) -> ManualLikeState {
        let current = getStats(for: trackID).manualLikeState
        let next: ManualLikeState
        switch current {
        case .none: next = .liked
        case .liked: next = .disliked
        case .disliked: next = .none
        }
        setManualLikeState(trackID: trackID, state: next)
        return next
    }

    // MARK: - Persistence

    /// Load stats from a track sidecar.
    func loadStats(from sidecar: TrackSidecar) {
        if let stats = sidecar.preferenceStats {
            statsCache[sidecar.id] = stats
        } else if let legacyPlayCount = sidecar.playCount, legacyPlayCount > 0 {
            // Migrate from legacy playCount.
            statsCache[sidecar.id] = TrackPreferenceStats.fromLegacy(playCount: legacyPlayCount)
        }
    }

    /// Replace stats with an exact value loaded from disk or bulk maintenance logic.
    func replaceStats(for trackID: UUID, with stats: TrackPreferenceStats, markDirty: Bool = false) {
        statsCache[trackID] = stats
        if markDirty {
            dirtyTrackIDs.insert(trackID)
        } else {
            dirtyTrackIDs.remove(trackID)
        }
    }

    func removeStats(for trackIDs: Set<UUID>) {
        guard !trackIDs.isEmpty else { return }
        for trackID in trackIDs {
            statsCache.removeValue(forKey: trackID)
            dirtyTrackIDs.remove(trackID)
        }
    }

    /// Save all dirty stats to their respective sidecars synchronously on the main actor.
    /// - Parameter trackProvider: Optional closure to get Track objects for writing sidecars.
    func saveAllPendingNow(trackProvider: ((UUID) -> Track?)? = nil) {
        let tracksToSave = Array(dirtyTrackIDs)

        guard !tracksToSave.isEmpty else { return }

        // If track provider provided, use it to get tracks and write sidecars.
        var savedCount = 0
        if let provider = trackProvider {
            for trackID in tracksToSave {
                if let track = provider(trackID) {
                    LocalLibraryService.shared.writeMetaOnly(for: track, reason: "playbackStats")
                    dirtyTrackIDs.remove(trackID)
                    savedCount += 1
                }
            }
        } else {
            // Fallback: use the cached stats directly via a notification.
            // The AVAudioPlaybackService will handle this with proper track references.
            NotificationCenter.default.post(
                name: .preferenceStatsShouldSave,
                object: nil,
                userInfo: ["trackIDs": tracksToSave]
            )
            dirtyTrackIDs.removeAll()
            savedCount = tracksToSave.count
        }

        print("💾 Saved preference stats for \(savedCount) tracks")
    }

    /// Async wrapper for callers already using task-based lifecycle hooks.
    func saveAllPending(trackProvider: ((UUID) -> Track?)? = nil) async {
        saveAllPendingNow(trackProvider: trackProvider)
    }

    /// Save stats for a specific track immediately.
    func saveStats(for track: Track) {
        LocalLibraryService.shared.writeMetaOnly(for: track, reason: "playbackStats")

        dirtyTrackIDs.remove(track.id)
    }

    /// Mark a track as needing save (called when session ends).
    func markDirty(_ trackID: UUID) {
        dirtyTrackIDs.insert(trackID)
    }

    // MARK: - Bulk Operations

    /// Load stats for all tracks from disk.
    func preloadStats(repository: LibraryRepositoryProtocol) async {
        let tracks = await repository.fetchTracks(in: nil)

        for track in tracks {
            // Stats will be loaded when sidecar is read.
            // For now, just ensure cache entry exists.
            if statsCache[track.id] == nil {
                statsCache[track.id] = TrackPreferenceStats()
            }
        }

        print("📊 Preloaded stats for \(tracks.count) tracks")
    }

    /// Clear all cached stats (e.g., on logout or reset).
    func clearCache() {
        statsCache.removeAll()
        dirtyTrackIDs.removeAll()
    }

    /// Get statistics summary for debugging.
    var cacheStatistics: (cached: Int, dirty: Int) {
        let cached = statsCache.count
        let dirty = dirtyTrackIDs.count
        return (cached, dirty)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when preference stats should be saved to disk.
    static let preferenceStatsShouldSave = Notification.Name("preferenceStatsShouldSave")
}
