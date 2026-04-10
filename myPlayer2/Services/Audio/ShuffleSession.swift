//
//  ShuffleSession.swift
//  myPlayer2
//
//  Smart Shuffle - Stateful Shuffle Session
//  Manages a persistent shuffle sequence with history navigation.
//

import Foundation
import SwiftData

/// Manages a single shuffle playback session.
///
/// Key behaviors:
/// - Generated sequence is persistent (going back then forward returns to same track)
/// - Dynamically extends when approaching end of queue
/// - Applies runtime weight adjustments based on recent history
/// - Supports both forward and backward navigation
@MainActor
final class ShuffleSession {

    // MARK: - Configuration

    /// Minimum remaining tracks before triggering queue extension.
    static let minRemainingThreshold: Int = 5

    /// How many tracks to generate when extending queue.
    static let extensionBatchSize: Int = 10

    /// Maximum history size to maintain for runtime adjustments.
    static let maxHistorySize: Int = 50

    // MARK: - Session State

    /// The source pool of track IDs available for this session.
    private(set) var sourceSnapshotTrackIDs: [UUID]

    /// The generated shuffle sequence.
    private(set) var generatedTrackIDs: [UUID] = []

    /// Current position in the generated sequence.
    private(set) var currentIndex: Int = -1

    /// Runtime history of played tracks (most recent last).
    private(set) var recentlyPlayedTrackIDs: [UUID] = []

    /// Track metadata cache for weight calculations.
    private var trackCache: [UUID: Track] = [:]

    /// Base weights from preference stats.
    private var baseWeights: [UUID: Double] = [:]

    /// Whether the session is active.
    private(set) var isActive: Bool = false

    /// Callback for loading track metadata (injected dependency).
    var trackLoader: ((UUID) -> Track?)?

    // MARK: - Initialization

    init(sourceTrackIDs: [UUID]) {
        self.sourceSnapshotTrackIDs = sourceTrackIDs
    }

    // MARK: - Session Lifecycle

    /// Start a new shuffle session from a specific track.
    func start(from trackID: UUID?, tracks: [Track]) {
        // Build track cache.
        trackCache = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })

        // Initialize base weights from preference stats.
        initializeWeights(tracks: tracks)

        // Clear existing sequence.
        generatedTrackIDs.removeAll()
        recentlyPlayedTrackIDs.removeAll()
        currentIndex = -1

        // If starting track specified, add it as first in sequence.
        if let startID = trackID, sourceSnapshotTrackIDs.contains(startID) {
            generatedTrackIDs.append(startID)
            currentIndex = 0
            appendToHistory(startID)
        }

        // Generate initial batch.
        extendQueueIfNeeded()

        isActive = true
    }

    /// Rebuild session with new source tracks while preserving history where possible.
    func rebuild(with newTrackIDs: [UUID], tracks: [Track]) {
        // Update track cache with new tracks.
        for track in tracks {
            trackCache[track.id] = track
        }

        // Filter existing sequence to only include tracks still in source.
        let newSourceSet = Set(newTrackIDs)
        let filteredSequence = generatedTrackIDs.filter { newSourceSet.contains($0) }

        // Update current index to maintain position if possible.
        if let currentTrackID = currentTrackID,
           let newIndex = filteredSequence.firstIndex(of: currentTrackID) {
            currentIndex = newIndex
        } else if currentIndex >= filteredSequence.count {
            currentIndex = max(0, filteredSequence.count - 1)
        }

        generatedTrackIDs = filteredSequence
        sourceSnapshotTrackIDs = newTrackIDs

        // Update weights with new tracks.
        initializeWeights(tracks: tracks)

        // Clean up history to only include valid tracks.
        recentlyPlayedTrackIDs = recentlyPlayedTrackIDs.filter { newSourceSet.contains($0) }

        // Extend if needed.
        extendQueueIfNeeded()
    }

    /// Reset the session completely.
    func reset() {
        generatedTrackIDs.removeAll()
        currentIndex = -1
        recentlyPlayedTrackIDs.removeAll()
        trackCache.removeAll()
        baseWeights.removeAll()
        isActive = false
    }

    // MARK: - Navigation

    /// Get the current track ID.
    var currentTrackID: UUID? {
        guard currentIndex >= 0, currentIndex < generatedTrackIDs.count else { return nil }
        return generatedTrackIDs[currentIndex]
    }

    /// Move to the next track.
    /// Returns the next track ID or nil if at end and can't extend.
    func next() -> UUID? {
        guard isActive else { return nil }

        // Check if we have a pre-generated next track.
        let nextIndex = currentIndex + 1

        if nextIndex < generatedTrackIDs.count {
            // Move forward in existing sequence.
            currentIndex = nextIndex
            let trackID = generatedTrackIDs[currentIndex]
            appendToHistory(trackID)
            extendQueueIfNeeded()
            return trackID
        }

        // Need to generate a new track.
        guard let newTrackID = generateNextTrack() else {
            return nil
        }

        generatedTrackIDs.append(newTrackID)
        currentIndex = generatedTrackIDs.count - 1
        appendToHistory(newTrackID)
        extendQueueIfNeeded()

        return newTrackID
    }

    /// Move to the previous track.
    /// Returns the previous track ID or nil if at start.
    func previous() -> UUID? {
        guard isActive, currentIndex > 0 else { return nil }

        currentIndex -= 1
        let trackID = generatedTrackIDs[currentIndex]

        // Don't modify history when going backward - it preserves the "forward goes back"
        // behavior when the user goes back then forward.

        return trackID
    }

    /// Peek at the next N tracks without advancing.
    func peekNext(count: Int) -> [UUID] {
        guard isActive else { return [] }

        let startIndex = currentIndex + 1
        let endIndex = min(startIndex + count, generatedTrackIDs.count)

        guard startIndex < endIndex else { return [] }
        return Array(generatedTrackIDs[startIndex..<endIndex])
    }

    /// Peek at the previous N tracks without moving.
    func peekPrevious(count: Int) -> [UUID] {
        guard isActive, currentIndex > 0 else { return [] }

        let endIndex = currentIndex
        let startIndex = max(0, endIndex - count)

        guard startIndex < endIndex else { return [] }
        return Array(generatedTrackIDs[startIndex..<endIndex])
    }

    // MARK: - Queue Extension

    /// Check if queue needs extension and extend if necessary.
    private func extendQueueIfNeeded() {
        let remaining = generatedTrackIDs.count - (currentIndex + 1)

        if remaining < Self.minRemainingThreshold {
            extendQueue(by: Self.extensionBatchSize)
        }
    }

    /// Generate additional tracks and append to the sequence.
    private func extendQueue(by count: Int) {
        guard !sourceSnapshotTrackIDs.isEmpty else { return }

        // Get already scheduled track IDs to avoid duplicates in near future.
        let alreadyScheduled = Set(generatedTrackIDs.dropFirst(max(0, currentIndex - 5)))

        // Generate candidates excluding recently scheduled.
        var availableCandidates = sourceSnapshotTrackIDs.filter { !alreadyScheduled.contains($0) }

        // If we filtered too aggressively, relax constraints.
        if availableCandidates.isEmpty {
            availableCandidates = sourceSnapshotTrackIDs
        }

        // Get current adjusted weights.
        let adjustedWeights = getAdjustedWeights()

        // Generate weighted samples.
        let newTracks = WeightedRandomSampler.sampleMultiple(
            from: availableCandidates,
            weights: adjustedWeights,
            count: count,
            exclude: currentTrackID
        )

        generatedTrackIDs.append(contentsOf: newTracks)
    }

    /// Generate a single next track.
    private func generateNextTrack() -> UUID? {
        guard !sourceSnapshotTrackIDs.isEmpty else { return nil }

        let adjustedWeights = getAdjustedWeights()

        // Exclude the current track from selection.
        return WeightedRandomSampler.sample(
            from: sourceSnapshotTrackIDs,
            weights: adjustedWeights,
            exclude: currentTrackID
        )
    }

    // MARK: - Weight Management (V2 Algorithm)

    /// Initialize base weights from track preference stats using V2 scoring.
    /// Base weights are cached and represent long-term preference only.
    private func initializeWeights(tracks: [Track]) {
        baseWeights.removeAll()

        for track in tracks {
            let stats = PreferenceStatsService.shared.getStats(for: track.id)
            let result = PreferenceScorerV2.calculateScore(
                stats: stats,
                duration: track.duration,
                manualLikeState: stats.manualLikeState
            )
            baseWeights[track.id] = result.baseWeight
        }
    }

    /// Update base weight for a specific track (called when stats change).
    func updateWeight(for trackID: UUID, weight: Double) {
        baseWeights[trackID] = weight
    }

    /// Get runtime-adjusted weights using V2 penalty system.
    /// Applies recent-history / same-artist / same-album penalties to base weights.
    /// This is temporary adjustment for sampling only, not persisted.
    private func getAdjustedWeights() -> [UUID: Double] {
        var adjustedWeights: [UUID: Double] = [:]

        for (trackID, baseWeight) in baseWeights {
            guard let track = trackCache[trackID] else {
                adjustedWeights[trackID] = baseWeight
                continue
            }

            let runtimeWeight = PreferenceScorerV2.applyRuntimePenalties(
                baseWeight: baseWeight,
                track: track,
                recentHistory: recentlyPlayedTrackIDs,
                tracks: trackCache
            )
            adjustedWeights[trackID] = runtimeWeight
        }

        return adjustedWeights
    }

    // MARK: - History Management

    /// Add a track to the recent history.
    private func appendToHistory(_ trackID: UUID) {
        recentlyPlayedTrackIDs.append(trackID)

        // Trim history if it gets too large.
        if recentlyPlayedTrackIDs.count > Self.maxHistorySize {
            recentlyPlayedTrackIDs.removeFirst(recentlyPlayedTrackIDs.count - Self.maxHistorySize)
        }
    }

    /// Get the recent history (most recent last).
    var recentHistory: [UUID] {
        recentlyPlayedTrackIDs
    }

    /// Check if a track was recently played.
    func wasRecentlyPlayed(_ trackID: UUID, within: Int = 10) -> Bool {
        let recent = Array(recentlyPlayedTrackIDs.suffix(within))
        return recent.contains(trackID)
    }

    // MARK: - Statistics

    /// Get session statistics for debugging/monitoring.
    var statistics: SessionStatistics {
        SessionStatistics(
            totalSourceTracks: sourceSnapshotTrackIDs.count,
            generatedSequenceLength: generatedTrackIDs.count,
            currentPosition: currentIndex,
            historySize: recentlyPlayedTrackIDs.count,
            remainingTracks: generatedTrackIDs.count - (currentIndex + 1)
        )
    }
}

// MARK: - Session Statistics

struct SessionStatistics {
    let totalSourceTracks: Int
    let generatedSequenceLength: Int
    let currentPosition: Int
    let historySize: Int
    let remainingTracks: Int
}
