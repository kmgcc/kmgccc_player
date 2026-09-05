//
//  SmartPlaybackController.swift
//  myPlayer2
//
//  Smart Shuffle - Playback Controller
//  Integrates shuffle session, playback tracking, and preference stats.
//  Manages the lifecycle of a playback session with smart shuffle behavior.
//

import AppKit
import Foundation
import SwiftData

/// Controller that manages smart playback with preference-based shuffle.
/// Coordinates between the shuffle session, playback tracking, and stats persistence.
@MainActor
final class SmartPlaybackController {

    private struct PendingHistoryRecord: Sendable {
        let trackID: UUID
        let playedAt: Date
        let title: String
        let artist: String
        let album: String
        let duration: Double
        let playedSeconds: Double
    }

    // MARK: - Components

    private let playbackHistoryStore: PlaybackHistoryStore
    private let preferenceStatsService: PreferenceStatsService
    private let libraryService: LocalLibraryService

    /// The active shuffle session.
    private var shuffleSession: ShuffleSession?

    /// Current playback session tracker.
    private var currentSessionTracker: PlaybackSessionTracker?

    /// Callbacks for playback control.
    var onPlayTrack: ((Track) -> Void)?
    var onTrackChanged: ((Track?) -> Void)?

    /// Whether shuffle mode is enabled.
    private(set) var isShuffleEnabled: Bool = false

    /// The current source pool of tracks.
    private var sourceTracks: [Track] = []

    /// Current track index in source array (for non-shuffle mode).
    private var currentSourceIndex: Int = -1

    /// History uses a main-actor SwiftData context. Keep its durable write out
    /// of the track-switch frame while retaining every event in order.
    private var pendingHistoryRecords: [PendingHistoryRecord] = []
    private var historyWriteTask: Task<Void, Never>?

    /// Last track in the explicit play-next block for sequential queues.
    private var playNextInsertionAnchorID: UUID?

    init(
        playbackHistoryStore: PlaybackHistoryStore,
        preferenceStatsService: PreferenceStatsService = .shared,
        libraryService: LocalLibraryService
    ) {
        self.playbackHistoryStore = playbackHistoryStore
        self.preferenceStatsService = preferenceStatsService
        self.libraryService = libraryService
        setupNotifications()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Setup

    private func setupNotifications() {
        // Listen for app termination to save pending stats.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // Listen for save requests.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSaveRequest),
            name: .preferenceStatsShouldSave,
            object: nil
        )
    }

    // MARK: - Session Management

    /// Start playback with a set of tracks.
    func startPlayback(tracks: [Track], startingAt index: Int, shuffle: Bool) {
        guard !tracks.isEmpty, index >= 0, index < tracks.count else { return }

        finalizeCurrentPlaybackSession(reason: .userJumpToTrack)

        sourceTracks = tracks
        isShuffleEnabled = shuffle
        currentSourceIndex = index
        playNextInsertionAnchorID = nil

        if shuffle {
            // Initialize shuffle session.
            let session = ShuffleSession(
                sourceTrackIDs: tracks.map { $0.id },
                preferenceStatsService: preferenceStatsService
            )
            session.start(from: tracks[index].id, tracks: tracks)
            session.trackLoader = { [weak self] trackID in
                self?.sourceTracks.first { $0.id == trackID }
            }
            shuffleSession = session
        } else {
            shuffleSession = nil
        }

        // Start playback session for the first track.
        startTrackSession(track: tracks[index])
        onPlayTrack?(tracks[index])
    }

    /// Update the queue tracks (e.g., when playlist changes).
    func updateQueue(tracks: [Track], preservePosition: Bool = true) {
        let currentTrackID = preservePosition ? currentTrack?.id : nil

        sourceTracks = tracks
        playNextInsertionAnchorID = nil

        if isShuffleEnabled, let session = shuffleSession {
            // Rebuild shuffle session with new tracks.
            session.rebuild(with: tracks.map { $0.id }, tracks: tracks)

            // Try to maintain current position.
            if let trackID = currentTrackID,
               tracks.contains(where: { $0.id == trackID }) {
                // Current track still in list, session handles position.
            } else if let firstTrack = tracks.first {
                // Current track removed, start from beginning.
                currentSourceIndex = 0
                startTrackSession(track: firstTrack)
                onPlayTrack?(firstTrack)
            }
        } else {
            // Update linear index.
            if let trackID = currentTrackID,
               let newIndex = tracks.firstIndex(where: { $0.id == trackID }) {
                currentSourceIndex = newIndex
            } else {
                currentSourceIndex = min(currentSourceIndex, max(0, tracks.count - 1))
            }
        }
    }

    /// Set shuffle mode.
    func setShuffle(_ enabled: Bool) {
        guard enabled != isShuffleEnabled else { return }

        isShuffleEnabled = enabled

        if enabled {
            // Enable shuffle: create session from current position.
            let session = ShuffleSession(sourceTrackIDs: sourceTracks.map { $0.id })
            let currentID = currentSourceIndex >= 0 ? sourceTracks[currentSourceIndex].id : nil
            session.start(from: currentID, tracks: sourceTracks)
            session.trackLoader = { [weak self] trackID in
                self?.sourceTracks.first { $0.id == trackID }
            }
            shuffleSession = session
        } else {
            // Disable shuffle: find current track in source array.
            if let session = shuffleSession,
               let currentID = session.currentTrackID,
               let index = sourceTracks.firstIndex(where: { $0.id == currentID }) {
                currentSourceIndex = index
            }
            shuffleSession = nil
        }
        playNextInsertionAnchorID = nil
    }

    /// Insert tracks after the current play-next block without starting playback.
    @discardableResult
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int {
        guard let currentTrack else { return 0 }
        let insertionTracks = Self.playableUniqueTracks(from: tracks, excluding: currentTrack.id)
        guard !insertionTracks.isEmpty else { return 0 }

        if isShuffleEnabled, let session = shuffleSession {
            sourceTracks = Self.replacingOrAppendingTracks(in: sourceTracks, with: insertionTracks)
            return session.insertTracksAfterCurrent(insertionTracks)
        }

        let insertionIDs = Set(insertionTracks.map(\.id))
        var queue = sourceTracks.filter { !insertionIDs.contains($0.id) }
        guard let currentIndex = queue.firstIndex(where: { $0.id == currentTrack.id }) else {
            return 0
        }

        let insertionIndex = playNextInsertionIndex(in: queue, currentIndex: currentIndex)
        queue.insert(contentsOf: insertionTracks, at: insertionIndex)

        sourceTracks = queue
        currentSourceIndex = sourceTracks.firstIndex(where: { $0.id == currentTrack.id }) ?? currentIndex
        playNextInsertionAnchorID = insertionTracks.last?.id
        return insertionTracks.count
    }

    /// Mark the currently active playback session so its already-started stats will be dropped once.
    func discardCurrentSessionStatsOnFinalizeOnce() {
        guard let tracker = currentSessionTracker else { return }
        tracker.discardStatsOnFinalizeOnce()
        Log.info(
            "[PlaybackSession] active session marked discard-on-finalize once trackID=\(currentTrack?.id.uuidString ?? "none")",
            category: .playback
        )
    }

    // MARK: - Navigation

    /// Get the current track.
    var currentTrack: Track? {
        if isShuffleEnabled, let session = shuffleSession,
           let trackID = session.currentTrackID {
            return sourceTracks.first { $0.id == trackID }
        }
        guard currentSourceIndex >= 0, currentSourceIndex < sourceTracks.count else { return nil }
        return sourceTracks[currentSourceIndex]
    }

    /// Go to next track (user-initiated).
    func nextTrack() {
        finalizeCurrentPlaybackSession(reason: .userNext)

        let nextTrack: Track?

        if isShuffleEnabled, let session = shuffleSession {
            guard let nextID = session.next() else { return }
            nextTrack = sourceTracks.first { $0.id == nextID }
        } else {
            let nextIndex = currentSourceIndex + 1
            if nextIndex < sourceTracks.count {
                currentSourceIndex = nextIndex
                nextTrack = sourceTracks[nextIndex]
            } else {
                // End of queue - wrap if repeat all.
                if sourceTracks.isEmpty {
                    return
                }
                currentSourceIndex = 0
                nextTrack = sourceTracks[0]
            }
        }

        if let track = nextTrack {
            startTrackSession(track: track)
            onPlayTrack?(track)
        }
    }

    /// Go to previous track (user-initiated).
    func previousTrack() {
        if isShuffleEnabled, let session = shuffleSession, session.getCurrentIndexInSequence() <= 0 {
            return
        }

        finalizeCurrentPlaybackSession(reason: .userPrevious)

        let prevTrack: Track?

        if isShuffleEnabled, let session = shuffleSession {
            guard let prevID = session.previous() else { return }
            prevTrack = sourceTracks.first { $0.id == prevID }
        } else {
            let prevIndex = currentSourceIndex - 1
            if prevIndex >= 0 {
                currentSourceIndex = prevIndex
                prevTrack = sourceTracks[prevIndex]
            } else {
                // Start of queue - wrap to end.
                if sourceTracks.isEmpty {
                    return
                }
                currentSourceIndex = sourceTracks.count - 1
                prevTrack = sourceTracks[currentSourceIndex]
            }
        }

        if let track = prevTrack {
            startTrackSession(track: track)
            onPlayTrack?(track)
        }
    }

    /// Auto-advance to next track (playback completed naturally).
    func autoAdvance() -> Track? {
        finalizeCurrentPlaybackSession(reason: .naturalCompletion)

        let nextTrack: Track?

        if isShuffleEnabled, let session = shuffleSession {
            guard let nextID = session.next() else { return nil }
            nextTrack = sourceTracks.first { $0.id == nextID }
        } else {
            let nextIndex = currentSourceIndex + 1
            if nextIndex < sourceTracks.count {
                currentSourceIndex = nextIndex
                nextTrack = sourceTracks[nextIndex]
            } else {
                return nil
            }
        }

        if let track = nextTrack {
            startTrackSession(track: track)
            onPlayTrack?(track)
        }

        return nextTrack
    }

    /// The track a *natural* auto-advance would play next, computed WITHOUT any
    /// mutation or session side effects. Used by gapless scheduling to prefetch
    /// the upcoming track and to validate a boundary before committing it.
    /// Returns nil at the end of the queue — matching `autoAdvance`, which stops
    /// rather than wraps on natural completion.
    func peekNextForGapless() -> Track? {
        if isShuffleEnabled, let session = shuffleSession {
            guard let nextID = session.peekNext(count: 1).first else { return nil }
            return sourceTracks.first { $0.id == nextID }
        }
        let nextIndex = currentSourceIndex + 1
        guard nextIndex >= 0, nextIndex < sourceTracks.count else { return nil }
        return sourceTracks[nextIndex]
    }

    /// Commit a natural advance whose audio is ALREADY scheduled and playing on
    /// the player node (gapless transition). Mirrors `autoAdvance()` EXCEPT it
    /// never calls `onPlayTrack` — there is no audio to (re)start. It determines
    /// the next track first (no side effects), and only if one exists does it
    /// finalize the current session as a natural completion, advance the
    /// index/shuffle position, start the next session, and notify
    /// `onTrackChanged` (which updates `currentTrack`). Returns the advanced-to
    /// track, or nil when there is no next track (no state is mutated in that
    /// case). The returned track equals `peekNextForGapless()` by construction.
    func commitGaplessAdvance() -> Track? {
        let nextTrack: Track?
        if isShuffleEnabled, let session = shuffleSession {
            nextTrack = session.peekNext(count: 1).first.flatMap { id in
                sourceTracks.first { $0.id == id }
            }
        } else {
            let nextIndex = currentSourceIndex + 1
            nextTrack = (nextIndex >= 0 && nextIndex < sourceTracks.count)
                ? sourceTracks[nextIndex]
                : nil
        }

        guard let track = nextTrack else { return nil }

        finalizeCurrentPlaybackSession(reason: .naturalCompletion)

        if isShuffleEnabled, let session = shuffleSession {
            // Advances currentIndex to the same id that peekNext returned.
            _ = session.next()
        } else {
            currentSourceIndex += 1
        }

        // Fires onTrackChanged → currentTrack = track. Deliberately NO onPlayTrack:
        // the audio for this track is already rendering on the player node.
        startTrackSession(track: track)
        return track
    }

    /// Jump to a specific track.
    func jumpToTrack(_ track: Track) {
        finalizeCurrentPlaybackSession(reason: .userJumpToTrack)

        if let index = sourceTracks.firstIndex(where: { $0.id == track.id }) {
            currentSourceIndex = index
        }

        if isShuffleEnabled, let session = shuffleSession {
            // Reset session to start from this track.
            session.start(from: track.id, tracks: sourceTracks)
        }

        startTrackSession(track: track)
        onPlayTrack?(track)
    }

    // MARK: - Playback Session Tracking

    /// Start tracking a new playback session.
    private func startTrackSession(track: Track) {
        // End any existing session (safety net - should have been finalized already).
        if currentSessionTracker != nil {
            Log.warning("[PlaybackSession] startTrackSession called with existing tracker! Finalizing...", category: .playback)
            finalizeCurrentPlaybackSession(reason: .systemInterrupt)
        }

        // Create new tracker.
        currentSessionTracker = PlaybackSessionTracker(track: track)
        Log.debug("[PlaybackSession] Started new session for: \(track.title) (ID: \(track.id.uuidString.prefix(8)))", category: .playback)

        // Notify about track change.
        onTrackChanged?(track)
    }

    /// Update progress during playback.
    func updateProgress(currentTime: Double, duration: Double) {
        // Update tracker
        if let tracker = currentSessionTracker {
            tracker.updateProgress(currentTime: currentTime)
        } else {
            Log.warning("[PlaybackSession] updateProgress called but no active tracker!", category: .playback)
        }
    }

    /// Mark that a seek operation is starting.
    func beginSeek() {
        currentSessionTracker?.beginSeek()
    }

    /// Record a successful seek target so the tracker can exclude the position jump.
    func recordSeek(to currentTime: Double) {
        currentSessionTracker?.recordSeek(to: currentTime)
    }

    /// Mark that a seek operation has completed.
    func endSeek() {
        currentSessionTracker?.endSeek()
    }

    /// Unified entry point for finalizing playback sessions.
    /// ALL paths that end a song must go through here.
    private func finalizeCurrentPlaybackSession(
        reason: PlaybackSessionEndReason,
        source: String = #function
    ) {
        guard let tracker = currentSessionTracker else {
            return
        }

        guard let track = currentTrack else {
            Log.warning("[PlaybackSession] No current track to finalize (source: \(source))", category: .playback)
            currentSessionTracker = nil
            return
        }

        let trackID = track.id
        let trackTitle = track.title

        switch reason {
        case .naturalCompletion, .repeatOneReplay, .stopAfterTrack:
            tracker.markCompleted(reason: reason)
        case .userNext, .userPrevious, .userJumpToTrack, .userJumpWithinQueue, .systemInterrupt, .appTermination:
            tracker.markEnded(reason: reason)
        }

        // Finalize and get outcome
        let outcome = tracker.finalize()

        if tracker.consumePendingStatsDiscardFlag() {
            Log.info(
                "[PlaybackSession] finalized without stats writeback due to one-shot discard trackID=\(trackID.uuidString)",
                category: .playback
            )
            currentSessionTracker = nil
            return
        }

        let accumulatedSeconds = tracker.totalPlayedSeconds
        let isValidPlay = tracker.isValidPlay
        let isCompleted = tracker.isCompleted

        if case .tooShort = outcome {
            // Keep the history timeline aligned with the existing effective-play
            // threshold. Merely opening a track or scrubbing briefly is not a
            // playback-history event.
        } else {
            let startedAt = tracker.startedAt
            let title = track.title
            let artist = track.artist
            let album = track.album
            let duration = track.duration
            enqueuePlaybackHistoryRecord(
                PendingHistoryRecord(
                    trackID: trackID,
                    playedAt: startedAt,
                    title: title,
                    artist: artist,
                    album: album,
                    duration: duration,
                    playedSeconds: accumulatedSeconds
                )
            )
        }

        // Apply to stats
        let didChangeStats = preferenceStatsService.applyPlaybackOutcome(
            trackID: trackID,
            outcome: outcome,
            trackDuration: track.duration
        )

        // Get updated stats for logging
        let updatedStats = preferenceStatsService.getStats(for: trackID)

        if didChangeStats {
            // Write to disk
            preferenceStatsService.saveStats(for: track)
        }

        if didChangeStats {
            shuffleSession?.updateWeight(for: trackID, weight: updatedStats.effectiveWeightCache)
        }

        // Single-line summary
        Log.info(
            "[PlaybackStats] finalized title=\(trackTitle) reason=\(reason) played=\(String(format: "%.1f", accumulatedSeconds))s completed=\(isCompleted) statsChanged=\(didChangeStats) playCount=\(updatedStats.playCount) skipCount=\(updatedStats.skipCount)",
            category: .playback
        )

        // Detailed verbose log
        if LogConfig.playbackStatsVerbose {
            print(String(repeating: "=", count: 60))
            print("🎵 [PlaybackSession] FINALIZED - \(trackTitle)")
            print("   Source: \(source)")
            print("   Track ID: \(trackID)")
            print("   End Reason: \(reason)")
            print("   Accumulated Played Seconds: \(String(format: "%.2f", accumulatedSeconds))")
            print("   Is Valid Play (>=2s): \(isValidPlay)")
            print("   Is Completed: \(isCompleted)")

            // Calculate V2 preference score for debugging
            let scoreResult = PreferenceScorerV2.calculateScore(
                stats: updatedStats,
                duration: track.duration,
                manualLikeState: updatedStats.manualLikeState
            )
            print("   📊 V2 Score: conf=\(String(format: "%.2f", scoreResult.features.confidence))")
            print("               raw=\(String(format: "%.3f", scoreResult.rawPreference))")
            print("               bounded=\(String(format: "%.3f", scoreResult.boundedPreference))")
            print("               baseWeight=\(String(format: "%.3f", scoreResult.baseWeight))")

            // Log outcome details
            switch outcome {
            case .tooShort:
                print("   ⏭️ Outcome: TOO SHORT (ignored)")
            case .completed:
                print("   ✅ Outcome: COMPLETED")
                print("      playCount: \(updatedStats.playCount)")
                print("      completePlayCount: \(updatedStats.completePlayCount)")
            case .skipped(_, let progress, let playedSeconds, let allowsQuickSkip):
                print("   ⏭️ Outcome: SKIPPED")
                print("      Progress: \(String(format: "%.1f", progress * 100))%")
                print("      Played: \(String(format: "%.1f", playedSeconds))s")
                print("      playCount: \(updatedStats.playCount)")
                print("      skipCount: \(updatedStats.skipCount)")
                if allowsQuickSkip && tracker.isQuickSkip() {
                    print("      ⚡ QUICK SKIP detected!")
                    print("      quickSkipCount: \(updatedStats.quickSkipCount)")
                }
            case .interrupted(_, let progress, _):
                print("   ⏸️ Outcome: INTERRUPTED")
                print("      Progress: \(String(format: "%.1f", progress * 100))%")
                print("      playCount: \(updatedStats.playCount)")
            }

            print("   Stats Changed: \(didChangeStats)")

            if didChangeStats {
                print("   💾 Queueing meta-only sidecar write on background writer...")
                print("   ✅ Meta write delegated to LocalLibraryService background pipeline")
            } else {
                print("   ⏭️ No stats delta, skipping disk write")
            }

            print(String(repeating: "=", count: 60))
        }

        currentSessionTracker = nil
    }

    private func enqueuePlaybackHistoryRecord(_ record: PendingHistoryRecord) {
        pendingHistoryRecords.append(record)
        guard historyWriteTask == nil else { return }

        historyWriteTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // The control relay animation is 580 ms. Leave a little room
                // after it before touching the main-actor SwiftData context.
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self else { return }
                guard !self.pendingHistoryRecords.isEmpty else {
                    self.historyWriteTask = nil
                    return
                }

                let record = self.pendingHistoryRecords.removeFirst()
                self.playbackHistoryStore.record(
                    trackID: record.trackID,
                    playedAt: record.playedAt,
                    title: record.title,
                    artist: record.artist,
                    album: record.album,
                    duration: record.duration,
                    playedSeconds: record.playedSeconds
                )

                if self.pendingHistoryRecords.isEmpty {
                    self.historyWriteTask = nil
                    return
                }
            }
        }
    }

    /// Application termination is the one boundary where the durable history
    /// write must complete before the process exits.
    private func flushPendingPlaybackHistory() {
        historyWriteTask?.cancel()
        historyWriteTask = nil
        for record in pendingHistoryRecords {
            playbackHistoryStore.record(
                trackID: record.trackID,
                playedAt: record.playedAt,
                title: record.title,
                artist: record.artist,
                album: record.album,
                duration: record.duration,
                playedSeconds: record.playedSeconds
            )
        }
        pendingHistoryRecords.removeAll(keepingCapacity: false)
    }

    func finishCurrentTrackForStopAfterTrack() {
        finalizeCurrentPlaybackSession(reason: .stopAfterTrack)
    }

    func replayCurrentTrackAfterCompletion() {
        guard let track = currentTrack else { return }
        finalizeCurrentPlaybackSession(reason: .repeatOneReplay)
        startTrackSession(track: track)
        onPlayTrack?(track)
    }

    /// Stop playback completely.
    func stop() {
        finalizeCurrentPlaybackSession(reason: .systemInterrupt)
        currentSessionTracker = nil
        shuffleSession = nil
        sourceTracks.removeAll()
        currentSourceIndex = -1
    }

    // MARK: - Notifications

    @objc private func handleAppWillTerminate(_ notification: Notification) {
        prepareForTermination()
    }

    func prepareForTermination() {
        finalizeCurrentPlaybackSession(reason: .appTermination)
        flushPendingPlaybackHistory()
        // Capture the latest in-memory values before the process termination
        // deadline. The bound library session will retry the sidecar writes on
        // its next lifecycle opportunity.
        preferenceStatsService.checkpointPendingStats()
    }

    @objc private func handleSaveRequest(_ notification: Notification) {
        // Handle save request from stats service.
        if let trackIDs = notification.userInfo?["trackIDs"] as? [UUID] {
            for trackID in trackIDs {
                if let track = sourceTracks.first(where: { $0.id == trackID }) {
                    libraryService.writeMetaOnlyInBackground(for: track, reason: "playbackStats")
                }
            }
        }
    }

    // MARK: - Queue Information

    /// Get all tracks in current playback order (for Fullscreen Queue View).
    /// For shuffle mode, returns the full generated sequence including played, current, and upcoming.
    func getCurrentQueue() -> [Track] {
        guard isShuffleEnabled, let session = shuffleSession else {
            // Sequential mode: return all tracks
            return sourceTracks
        }
        
        // Shuffle mode: get the full generated sequence
        let sequenceIDs = session.getFullSequence()
        return sequenceIDs.compactMap { id in sourceTracks.first { $0.id == id } }
    }
    
    /// Get the current track's index in the queue display order.
    func getCurrentQueueIndex() -> Int? {
        guard currentTrack != nil else { return nil }
        
        if isShuffleEnabled, let session = shuffleSession {
            return session.getCurrentIndexInSequence()
        } else {
            return currentSourceIndex
        }
    }
    
    /// Jump to a specific track in the queue without reshuffling.
    /// For shuffle mode, maintains the session stability.
    func jumpToTrackInQueue(_ track: Track) {
        guard sourceTracks.contains(where: { $0.id == track.id }) else { return }
        
        finalizeCurrentPlaybackSession(reason: .userJumpWithinQueue)
        
        if isShuffleEnabled, let session = shuffleSession {
            // Jump to this track in the shuffle session without reshuffling
            session.jumpTo(trackID: track.id)
        } else {
            // Sequential mode: update index
            if let index = sourceTracks.firstIndex(where: { $0.id == track.id }) {
                currentSourceIndex = index
            }
        }
        playNextInsertionAnchorID = nil
        
        startTrackSession(track: track)
        onPlayTrack?(track)
    }

    /// Get upcoming tracks (for UI preview).
    func getUpcomingTracks(count: Int) -> [Track] {
        guard isShuffleEnabled, let session = shuffleSession else {
            // Linear mode: return next N tracks.
            let startIndex = currentSourceIndex + 1
            let endIndex = min(startIndex + count, sourceTracks.count)
            guard startIndex < endIndex else { return [] }
            return Array(sourceTracks[startIndex..<endIndex])
        }

        // Shuffle mode: use session's peek.
        let upcomingIDs = session.peekNext(count: count)
        return upcomingIDs.compactMap { id in sourceTracks.first { $0.id == id } }
    }

    /// Get previous tracks (for UI history).
    func getPreviousTracks(count: Int) -> [Track] {
        guard isShuffleEnabled, let session = shuffleSession else {
            // Linear mode: return previous N tracks.
            let endIndex = currentSourceIndex
            let startIndex = max(0, endIndex - count)
            guard startIndex < endIndex else { return [] }
            return Array(sourceTracks[startIndex..<endIndex])
        }

        // Shuffle mode: use session's peek.
        let previousIDs = session.peekPrevious(count: count)
        return previousIDs.compactMap { id in sourceTracks.first { $0.id == id } }
    }

    private func playNextInsertionIndex(in queue: [Track], currentIndex: Int) -> Int {
        if let anchorID = playNextInsertionAnchorID,
           let anchorIndex = queue.firstIndex(where: { $0.id == anchorID }),
           anchorIndex >= currentIndex {
            return min(anchorIndex + 1, queue.count)
        }
        return min(currentIndex + 1, queue.count)
    }

    private static func playableUniqueTracks(from tracks: [Track], excluding excludedID: UUID?) -> [Track] {
        var seenIDs = Set<UUID>()
        return tracks.filter { track in
            guard track.id != excludedID else { return false }
            guard track.availability != .missing else { return false }
            return seenIDs.insert(track.id).inserted
        }
    }

    private static func replacingOrAppendingTracks(in sourceTracks: [Track], with replacements: [Track]) -> [Track] {
        guard !replacements.isEmpty else { return sourceTracks }

        let replacementByID = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
        var merged = sourceTracks.map { replacementByID[$0.id] ?? $0 }
        var existingIDs = Set(merged.map(\.id))

        for track in replacements where existingIDs.insert(track.id).inserted {
            merged.append(track)
        }

        return merged
    }
}
