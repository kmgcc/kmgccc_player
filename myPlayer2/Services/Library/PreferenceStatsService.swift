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
    private var statsCache: [UUID: TrackPreferenceStats] = [:]

    /// Set of track IDs with unsaved changes.
    private var dirtyTrackIDs: Set<UUID> = []

    /// Lock for thread-safe cache access.
    private let cacheLock = NSLock()

    // MARK: - Initialization

    private init() {}

    // MARK: - Stats Access

    /// Get stats for a track (from cache or creates default).
    func getStats(for trackID: UUID) -> TrackPreferenceStats {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = statsCache[trackID] {
            return cached
        }

        // Return default stats for new tracks.
        return TrackPreferenceStats()
    }

    /// Get stats for multiple tracks.
    func getStats(for trackIDs: [UUID]) -> [UUID: TrackPreferenceStats] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        var result: [UUID: TrackPreferenceStats] = [:]
        for trackID in trackIDs {
            result[trackID] = statsCache[trackID] ?? TrackPreferenceStats()
        }
        return result
    }

    /// Get effective weight for a track (used for weighted sampling).
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
        cacheLock.lock()
        defer { cacheLock.unlock() }

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
    /// Uses V2 scoring algorithm with proper duration-based weight calculation.
    @discardableResult
    func applyPlaybackOutcome(trackID: UUID, outcome: PlaybackSessionOutcome, trackDuration: Double) -> Bool {
        switch outcome {
        case .tooShort:
            return false
        default:
            break
        }

        return updateStats(for: trackID, duration: trackDuration) { stats in
            switch outcome {
            case .completed:
                stats.playCount += 1
                stats.completePlayCount += 1
                stats.totalPlayedSeconds += trackDuration // Assume full duration
                stats.lastPlayedAt = Date()
                stats.lastCompletedAt = Date()

            case .skipped(let progress, let playedSeconds):
                stats.playCount += 1
                stats.skipCount += 1
                stats.totalPlayedSeconds += playedSeconds
                stats.lastPlayedAt = Date()
                stats.lastSkippedAt = Date()

                // Check for quick skip.
                let isQuick = playedSeconds < PlaybackSessionTracker.quickSkipDuration
                    || progress < PlaybackSessionTracker.quickSkipPercentage
                if isQuick {
                    stats.quickSkipCount += 1
                }

            case .interrupted(let progress, let playedSeconds):
                // Interrupted plays count as plays but not skips.
                stats.playCount += 1
                stats.totalPlayedSeconds += playedSeconds
                stats.lastPlayedAt = Date()

                // If they got close to completion, count as complete.
                let remainingSeconds = trackDuration - playedSeconds
                let metCompletePercentage = progress >= PlaybackSessionTracker.completePlayPercentage
                let metCompleteRemaining = remainingSeconds <= PlaybackSessionTracker.completePlayRemainingSeconds

                if metCompletePercentage || metCompleteRemaining {
                    stats.completePlayCount += 1
                    stats.lastCompletedAt = Date()
                }
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
        cacheLock.lock()
        if let stats = sidecar.preferenceStats {
            statsCache[sidecar.id] = stats
        } else if let legacyPlayCount = sidecar.playCount, legacyPlayCount > 0 {
            // Migrate from legacy playCount.
            statsCache[sidecar.id] = TrackPreferenceStats.fromLegacy(playCount: legacyPlayCount)
        }
        cacheLock.unlock()
    }

    /// Replace stats with an exact value loaded from disk or bulk maintenance logic.
    func replaceStats(for trackID: UUID, with stats: TrackPreferenceStats, markDirty: Bool = false) {
        cacheLock.lock()
        statsCache[trackID] = stats
        if markDirty {
            dirtyTrackIDs.insert(trackID)
        } else {
            dirtyTrackIDs.remove(trackID)
        }
        cacheLock.unlock()
    }

    /// Save all dirty stats to their respective sidecars.
    /// - Parameter trackProvider: Optional closure to get Track objects for writing sidecars.
    func saveAllPending(trackProvider: ((UUID) -> Track?)? = nil) async {
        cacheLock.lock()
        let tracksToSave = Array(dirtyTrackIDs)
        dirtyTrackIDs.removeAll()
        cacheLock.unlock()

        guard !tracksToSave.isEmpty else { return }

        // If track provider provided, use it to get tracks and write sidecars.
        if let provider = trackProvider {
            for trackID in tracksToSave {
                if let track = provider(trackID) {
                    LocalLibraryService.shared.writeMetaOnly(for: track, reason: "playbackStats")
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
        }

        print("💾 Saved preference stats for \(tracksToSave.count) tracks")
    }

    /// Save stats for a specific track immediately.
    func saveStats(for track: Track) {
        LocalLibraryService.shared.writeMetaOnly(for: track, reason: "playbackStats")

        cacheLock.lock()
        dirtyTrackIDs.remove(track.id)
        cacheLock.unlock()
    }

    /// Mark a track as needing save (called when session ends).
    func markDirty(_ trackID: UUID) {
        cacheLock.lock()
        dirtyTrackIDs.insert(trackID)
        cacheLock.unlock()
    }

    // MARK: - Bulk Operations

    /// Load stats for all tracks from disk.
    func preloadStats(repository: LibraryRepositoryProtocol) async {
        let tracks = await repository.fetchTracks(in: nil)

        cacheLock.lock()
        for track in tracks {
            // Stats will be loaded when sidecar is read.
            // For now, just ensure cache entry exists.
            if statsCache[track.id] == nil {
                statsCache[track.id] = TrackPreferenceStats()
            }
        }
        cacheLock.unlock()

        print("📊 Preloaded stats for \(tracks.count) tracks")
    }

    /// Clear all cached stats (e.g., on logout or reset).
    func clearCache() {
        cacheLock.lock()
        statsCache.removeAll()
        dirtyTrackIDs.removeAll()
        cacheLock.unlock()
    }

    /// Get statistics summary for debugging.
    var cacheStatistics: (cached: Int, dirty: Int) {
        cacheLock.lock()
        let cached = statsCache.count
        let dirty = dirtyTrackIDs.count
        cacheLock.unlock()
        return (cached, dirty)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when preference stats should be saved to disk.
    static let preferenceStatsShouldSave = Notification.Name("preferenceStatsShouldSave")
}
