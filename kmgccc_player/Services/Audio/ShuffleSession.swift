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
    private let preferenceStatsService: PreferenceStatsService

    // MARK: - Configuration

    /// Minimum remaining tracks before triggering queue extension.
    static let minRemainingThreshold: Int = 5

    /// How many tracks to generate when extending queue.
    static let extensionBatchSize: Int = 10

    /// Maximum history size to maintain for runtime adjustments.
    static let maxHistorySize: Int = 50

    /// Probability, per weight computation, of injecting a rediscovery boost.
    /// Keeps the shuffle from ossifying into a fixed high-preference rotation
    /// without overwhelming the normal experience.
    static let explorationProbability: Double = 0.2

    /// How many top rediscovery-eligible candidates to amplify when exploring.
    static let rediscoveryBoostCount: Int = 3

    /// Minimum eligibility score for a track to qualify for rediscovery amplification.
    static let rediscoveryEligibilityThreshold: Double = 0.5

    /// Recently-played window excluded from rediscovery (so just-skipped tracks
    /// are never pulled back in by exploration).
    static let rediscoveryRecentExclusion: Int = 10

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

    /// Last track in the explicit play-next block.
    private var playNextInsertionAnchorID: UUID?

    /// Callback for loading track metadata (injected dependency).
    var trackLoader: ((UUID) -> Track?)?

    init(
        sourceTrackIDs: [UUID],
        preferenceStatsService: PreferenceStatsService = .shared
    ) {
        self.sourceSnapshotTrackIDs = sourceTrackIDs
        self.preferenceStatsService = preferenceStatsService
    }

    // MARK: - Session Lifecycle

    /// Start a new shuffle session from a specific track.
    func start(from trackID: UUID?, tracks: [Track]) {
        // Build track cache tolerantly — never crash on duplicate Track.id.
        var cache: [UUID: Track] = [:]
        var duplicateIDs: Set<UUID> = []
        var dedupedTracks: [Track] = []
        var seen: Set<UUID> = []

        for track in tracks {
            if cache[track.id] == nil {
                cache[track.id] = track
            } else {
                duplicateIDs.insert(track.id)
            }
            if seen.insert(track.id).inserted {
                dedupedTracks.append(track)
            }
        }

        if !duplicateIDs.isEmpty {
            print("[ShuffleSession] ignored duplicate track ids: count=\(duplicateIDs.count)")
        }

        trackCache = cache

        // Initialize base weights from preference stats using deduped tracks.
        initializeWeights(tracks: dedupedTracks)

        // Clear existing sequence.
        generatedTrackIDs.removeAll()
        recentlyPlayedTrackIDs.removeAll()
        currentIndex = -1
        playNextInsertionAnchorID = nil

        // If starting track specified, add it as first in sequence.
        if let startID = trackID,
           sourceSnapshotTrackIDs.contains(startID),
           trackCache[startID] != nil {
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
        playNextInsertionAnchorID = nil

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
        playNextInsertionAnchorID = nil
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

    /// Insert tracks into the generated sequence after the current play-next block.
    @discardableResult
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int {
        guard isActive, currentIndex >= 0, currentIndex < generatedTrackIDs.count else {
            return 0
        }

        let currentID = generatedTrackIDs[currentIndex]
        let insertionTracks = Self.playableUniqueTracks(from: tracks, excluding: currentID)
        guard !insertionTracks.isEmpty else { return 0 }

        for track in insertionTracks {
            trackCache[track.id] = track
            if !sourceSnapshotTrackIDs.contains(track.id) {
                sourceSnapshotTrackIDs.append(track.id)
            }
            updateBaseWeight(for: track)
        }

        let insertionIDs = Set(insertionTracks.map(\.id))
        let keptSequence = generatedTrackIDs.enumerated().compactMap { index, trackID in
            index > currentIndex && insertionIDs.contains(trackID) ? nil : trackID
        }
        let insertionIndex = playNextInsertionIndex(in: keptSequence, currentIndex: currentIndex)

        generatedTrackIDs = keptSequence
        generatedTrackIDs.insert(contentsOf: insertionTracks.map(\.id), at: insertionIndex)
        playNextInsertionAnchorID = insertionTracks.last?.id
        extendQueueIfNeeded()
        return insertionTracks.count
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
            let stats = preferenceStatsService.getStats(for: track.id)
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
    /// Composition: baseWeight (long-term preference + manual like)
    ///   × runtime penalties (recent same-track / artist / album)
    ///   × freshness multiplier (gentle boost for long-unplayed tracks)
    ///   × occasional rediscovery amplification (low-exposure / stale candidates).
    /// This is temporary adjustment for sampling only, not persisted.
    private func getAdjustedWeights() -> [UUID: Double] {
        var adjustedWeights: [UUID: Double] = [:]
        let now = Date()

        for (trackID, baseWeight) in baseWeights {
            guard let track = trackCache[trackID] else {
                adjustedWeights[trackID] = baseWeight
                continue
            }

            var weight = PreferenceScorerV2.applyRuntimePenalties(
                baseWeight: baseWeight,
                track: track,
                recentHistory: recentlyPlayedTrackIDs,
                tracks: trackCache
            )

            // Gentle, always-on freshness boost (long-unplayed tracks resurface).
            let stats = preferenceStatsService.getStats(for: trackID)
            weight *= PreferenceScorerV2.freshnessMultiplier(
                stats: stats,
                duration: track.duration,
                now: now
            )

            adjustedWeights[trackID] = weight
        }

        // Occasionally amplify a few rediscovery-eligible candidates so songs the
        // shuffle has long ignored get a real chance, without recurring every round.
        if Double.random(in: 0..<1) < Self.explorationProbability {
            applyRediscoveryBoost(to: &adjustedWeights, now: now)
        }

        return adjustedWeights
    }

    private func updateBaseWeight(for track: Track) {
        let stats = preferenceStatsService.getStats(for: track.id)
        let result = PreferenceScorerV2.calculateScore(
            stats: stats,
            duration: track.duration,
            manualLikeState: stats.manualLikeState
        )
        baseWeights[track.id] = result.baseWeight
    }

    private func playNextInsertionIndex(in sequence: [UUID], currentIndex: Int) -> Int {
        if let anchorID = playNextInsertionAnchorID,
           let anchorIndex = sequence.firstIndex(of: anchorID),
           anchorIndex >= currentIndex {
            return min(anchorIndex + 1, sequence.count)
        }
        return min(currentIndex + 1, sequence.count)
    }

    private static func playableUniqueTracks(from tracks: [Track], excluding excludedID: UUID?) -> [Track] {
        var seenIDs = Set<UUID>()
        return tracks.filter { track in
            guard track.id != excludedID else { return false }
            guard track.availability != .missing else { return false }
            return seenIDs.insert(track.id).inserted
        }
    }

    /// Amplify the most rediscovery-eligible candidates (low exposure / long
    /// unplayed, not recently played, not disliked / frequently quick-skipped).
    private func applyRediscoveryBoost(to weights: inout [UUID: Double], now: Date) {
        let recentSet = Set(recentlyPlayedTrackIDs.suffix(Self.rediscoveryRecentExclusion))

        let eligible: [(id: UUID, score: Double)] = weights.keys.compactMap { id in
            guard !recentSet.contains(id), let track = trackCache[id] else { return nil }
            let score = PreferenceScorerV2.rediscoveryEligibility(
                stats: preferenceStatsService.getStats(for: id),
                duration: track.duration,
                now: now
            )
            return score >= Self.rediscoveryEligibilityThreshold ? (id, score) : nil
        }

        guard !eligible.isEmpty else { return }

        let boostRange = PreferenceAlgorithmV2.rediscoveryMaxBoost - 1.0
        for entry in eligible.sorted(by: { $0.score > $1.score }).prefix(Self.rediscoveryBoostCount) {
            let factor = 1.0 + boostRange * entry.score
            weights[entry.id, default: 1.0] *= factor
        }
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

    /// Get the full generated sequence.
    func getFullSequence() -> [UUID] {
        return generatedTrackIDs
    }

    /// Get current index in the sequence.
    func getCurrentIndexInSequence() -> Int {
        return currentIndex
    }

    /// Jump to a specific track in the sequence without reshuffling.
    /// Adjusts history and position but keeps the generated sequence stable.
    func jumpTo(trackID: UUID) {
        guard let targetIndex = generatedTrackIDs.firstIndex(of: trackID) else { return }
        
        // If target is before current, we need to adjust history
        if targetIndex < currentIndex {
            // Move tracks from current position back to history
            // This ensures forward navigation works correctly after jump
        }
        
        // Update current index
        currentIndex = targetIndex
        playNextInsertionAnchorID = nil
        
        // Update history to include tracks before current position
        recentlyPlayedTrackIDs = Array(generatedTrackIDs.prefix(targetIndex))
        
        // Add current track to history
        if targetIndex < generatedTrackIDs.count {
            appendToHistory(generatedTrackIDs[targetIndex])
        }
        
        // Ensure queue is extended if needed
        extendQueueIfNeeded()
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
