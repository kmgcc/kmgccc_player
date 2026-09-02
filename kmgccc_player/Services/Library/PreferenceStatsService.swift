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
    private weak var libraryService: LocalLibraryService?

    /// Small crash-safe journal used when the app's three-second termination
    /// deadline expires before sidecar writes finish.
    private static let pendingJournalKey = "preferenceStats.pendingSidecarWrites.v1"
    private var pendingRecoveryStats: [UUID: TrackPreferenceStats]
    private var backgroundSaveTask: Task<Void, Never>?

    // MARK: - Browsing-burst Detection

    /// Timestamps of recent skip settlements, used to detect rapid "browsing /
    /// finding a song" behavior so each individual skip carries less weight.
    private var recentSkipTimestamps: [Date] = []

    /// Rolling window for browsing detection.
    private static let browsingWindowSeconds: TimeInterval = 25

    /// Number of skips within the window that flags a browsing burst.
    private static let browsingBurstThreshold: Int = 3

    /// Record a skip timestamp and report whether we are in a browsing burst.
    private func registerSkipAndDetectBrowsing(now: Date) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.browsingWindowSeconds)
        recentSkipTimestamps = recentSkipTimestamps.filter { $0 >= cutoff }
        recentSkipTimestamps.append(now)
        return recentSkipTimestamps.count >= Self.browsingBurstThreshold
    }

    init() {
        pendingRecoveryStats = Self.loadPendingJournal()
    }

    func bindPersistence(to libraryService: LocalLibraryService) {
        precondition(self.libraryService == nil || self.libraryService === libraryService)
        self.libraryService = libraryService
    }

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

        // Browsing-burst state is shared across tracks, so compute it before the
        // per-track update closure. Only actual skips participate.
        let isBrowsingBurst: Bool
        if case .skipped = outcome {
            isBrowsingBurst = registerSkipAndDetectBrowsing(now: finalizedAt)
        } else {
            isBrowsingBurst = false
        }

        return updateStats(for: trackID, duration: trackDuration) { stats in
            switch outcome {
            case .completed(_, _, let playedSeconds):
                stats.playCount += 1
                stats.completePlayCount += 1
                stats.totalPlayedSeconds += playedSeconds
                stats.lastPlayedAt = finalizedAt
                stats.lastCompletedAt = finalizedAt

            case .skipped(_, let progress, let playedSeconds, let allowsQuickSkip):
                // Every settled skip is at least a play.
                stats.playCount += 1
                stats.totalPlayedSeconds += playedSeconds
                stats.lastPlayedAt = finalizedAt

                if progress >= PlaybackSessionTracker.substantialPlayPercentage {
                    // Listened to most of the track before moving on — treat as a
                    // normal play, no skip / quick-skip penalty.
                    break
                }

                stats.skipCount += 1
                stats.lastSkippedAt = finalizedAt

                // Proportion-aware quick-skip detection (short songs are judged by
                // how much played, not a fixed second count).
                let isQuick = allowsQuickSkip && (
                    progress < PlaybackSessionTracker.quickSkipPercentage ||
                    (playedSeconds < PlaybackSessionTracker.quickSkipDuration &&
                     progress < PlaybackSessionTracker.quickSkipMaxProgress)
                )

                // Quick skips are downgraded to a plain skip when browsing rapidly
                // (likely finding a song) or when the user has manually liked the
                // track — in those cases a quick skip is only a mild signal.
                let suppressQuickSkip = isBrowsingBurst || stats.manualLikeState == .liked
                if isQuick && !suppressQuickSkip {
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
        if let recovered = pendingRecoveryStats[sidecar.id] {
            statsCache[sidecar.id] = recovered
            dirtyTrackIDs.insert(sidecar.id)
            return
        }
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
            pendingRecoveryStats.removeValue(forKey: trackID)
        }
        persistPendingJournal()
    }

    /// Save all dirty stats to their respective sidecars without blocking the main actor.
    /// - Parameter trackProvider: Optional closure to get Track objects for writing sidecars.
    /// - Parameter synchronously: Explicitly perform writes before returning. This is used
    ///   only after a library session has quiesced; normal lifecycle notifications stay async.
    func saveAllPendingNow(
        trackProvider: ((UUID) -> Track?)? = nil,
        synchronously: Bool = false
    ) {
        let tracksToSave = Array(dirtyTrackIDs)

        guard !tracksToSave.isEmpty else { return }

        if let trackProvider {
            if synchronously {
                for trackID in tracksToSave {
                    guard let track = trackProvider(trackID) else { continue }
                    pendingRecoveryStats[trackID] = getStats(for: trackID)
                    persistenceService.writeMetaOnly(for: track, reason: "playbackStats")
                    dirtyTrackIDs.remove(trackID)
                    pendingRecoveryStats.removeValue(forKey: trackID)
                }
                persistPendingJournal()
                return
            }

            guard backgroundSaveTask == nil else { return }
            backgroundSaveTask = Task { @MainActor [weak self] in
                guard let self else { return }
                await self.performSaveAllPending(trackProvider: trackProvider)
                self.backgroundSaveTask = nil
            }
            return
        }

        for trackID in tracksToSave {
            pendingRecoveryStats[trackID] = getStats(for: trackID)
        }
        persistPendingJournal()

        // A provider-less caller cannot verify sidecar completion. Keep entries
        // dirty and journaled so the next provider-backed save can retry them.
        NotificationCenter.default.post(
            name: .preferenceStatsShouldSave,
            object: nil,
            userInfo: ["trackIDs": tracksToSave]
        )
    }

    /// Async wrapper for callers already using task-based lifecycle hooks.
    func saveAllPending(trackProvider: ((UUID) -> Track?)? = nil) async {
        if let backgroundSaveTask {
            await backgroundSaveTask.value
        }
        await performSaveAllPending(trackProvider: trackProvider)
    }

    private func performSaveAllPending(trackProvider: ((UUID) -> Track?)?) async {
        let tracksToSave = Array(dirtyTrackIDs)
        guard !tracksToSave.isEmpty else { return }

        guard let trackProvider else {
            saveAllPendingNow()
            return
        }

        var snapshots: [TrackPersistenceSnapshot] = []
        snapshots.reserveCapacity(tracksToSave.count)
        for trackID in tracksToSave {
            guard let track = trackProvider(trackID) else { continue }
            snapshots.append(
                TrackPersistenceSnapshot(
                    track: track,
                    preferenceStats: getStats(for: trackID)
                )
            )
        }
        guard !snapshots.isEmpty else { return }

        for snapshot in snapshots {
            pendingRecoveryStats[snapshot.id] = snapshot.preferenceStats
        }
        persistPendingJournal()

        let libraryService = persistenceService
        let capturedPaths = libraryService.paths
        let snapshotsToPersist = snapshots
        let successfulTrackIDs = await Task.detached(priority: .utility) { @Sendable in
            var successful: Set<UUID> = []
            for snapshot in snapshotsToPersist {
                let result = autoreleasepool {
                    LocalLibraryService.persistTrackSnapshotOnBackground(
                        snapshot,
                        paths: capturedPaths,
                        mode: .metaOnly,
                        reason: "playbackStats"
                    )
                }
                if result.succeeded {
                    successful.insert(result.trackID)
                }
            }
            return successful
        }.value

        for snapshot in snapshotsToPersist {
            if successfulTrackIDs.contains(snapshot.id),
               statsCache[snapshot.id] == snapshot.preferenceStats {
                dirtyTrackIDs.remove(snapshot.id)
                pendingRecoveryStats.removeValue(forKey: snapshot.id)
            } else if let currentStats = statsCache[snapshot.id] {
                dirtyTrackIDs.insert(snapshot.id)
                pendingRecoveryStats[snapshot.id] = currentStats
            }
        }
        persistPendingJournal()
        let failedCount = snapshotsToPersist.count - successfulTrackIDs.count
        Log.info(
            "[PreferenceStats] background save completed saved=\(successfulTrackIDs.count) failed=\(failedCount)",
            category: .library
        )
    }

    /// Save stats for a specific track immediately.
    func saveStats(for track: Track) {
        Task { @MainActor in
            await saveAllPending { trackID in
                trackID == track.id ? track : nil
            }
        }
    }

    /// Mark a track as needing save (called when session ends).
    func markDirty(_ trackID: UUID) {
        dirtyTrackIDs.insert(trackID)
    }

    /// Capture pending in-memory values before the app starts its bounded
    /// termination work. Sidecar writes can then finish asynchronously.
    func checkpointPendingStats() {
        for trackID in dirtyTrackIDs {
            pendingRecoveryStats[trackID] = getStats(for: trackID)
        }
        persistPendingJournal()
    }

    // MARK: - Bulk Operations

    /// Load stats for all tracks from disk.
    func preloadStats(repository: LibraryRepositoryProtocol) async {
        let tracks = await repository.fetchTracks(in: nil)

        for track in tracks {
            // Stats will be loaded when sidecar is read.
            // For now, just ensure cache entry exists.
            if statsCache[track.id] == nil {
                if let recovered = pendingRecoveryStats[track.id] {
                    statsCache[track.id] = recovered
                    dirtyTrackIDs.insert(track.id)
                } else {
                    statsCache[track.id] = TrackPreferenceStats()
                }
            }
        }

        print("📊 Preloaded stats for \(tracks.count) tracks")
    }

    /// Clear all cached stats (e.g., on logout or reset).
    func clearCache() {
        statsCache.removeAll()
        dirtyTrackIDs.removeAll()
        recentSkipTimestamps.removeAll()
    }

    private var persistenceService: LocalLibraryService {
        guard let libraryService else {
            preconditionFailure("PreferenceStatsService must be bound to a library service before persistence")
        }
        return libraryService
    }

    /// Get statistics summary for debugging.
    var cacheStatistics: (cached: Int, dirty: Int) {
        let cached = statsCache.count
        let dirty = dirtyTrackIDs.count
        return (cached, dirty)
    }

    private static func loadPendingJournal() -> [UUID: TrackPreferenceStats] {
        guard let data = UserDefaults.standard.data(forKey: pendingJournalKey),
              let stored = try? JSONDecoder().decode([String: TrackPreferenceStats].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: stored.compactMap { key, value in
            UUID(uuidString: key).map { ($0, value) }
        })
    }

    private func persistPendingJournal() {
        guard !pendingRecoveryStats.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.pendingJournalKey)
            return
        }
        let stored = Dictionary(uniqueKeysWithValues: pendingRecoveryStats.map {
            ($0.key.uuidString, $0.value)
        })
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: Self.pendingJournalKey)
    }
}

// MARK: - Notifications

extension Notification.Name {
    /// Posted when preference stats should be saved to disk.
    static let preferenceStatsShouldSave = Notification.Name("preferenceStatsShouldSave")
}
