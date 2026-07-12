//
//  StubAudioPlaybackService.swift
//  myPlayer2
//
//  kmgccc_player - Stub Audio Playback Service
//  Provides fake playback state for UI development.
//

import Foundation
import Observation

/// Stub implementation for UI previews.
/// Simulates playback state without actual audio.
@Observable
@MainActor
final class StubAudioPlaybackService: AudioPlaybackServiceProtocol {

    private(set) var isPlaying: Bool = false
    var volume: Double = 0.8
    private(set) var currentTime: Double = 0
    var audioOutputDelay: Double { 0 }
    private(set) var duration: Double = 0
    private(set) var currentTrack: Track?
    var currentPlaybackOrderMode: PlaybackOrderMode {
        AppSettings.shared.playbackOrderMode
    }

    // MARK: - Private

    private var queue: [Track] = []
    private var currentIndex: Int = 0
    private var playNextInsertionAnchorID: UUID?

    // MARK: - Playback Control

    func play(track: Track) {
        currentTrack = track
        duration = track.duration
        currentTime = 0
        isPlaying = true
        startTimer()
        print("▶️ [Stub] Playing: \(track.title)")
    }

    func playTracks(_ tracks: [Track], startingAt index: Int, startPolicy: PlaybackStartPolicy) {
        queue = tracks
        currentIndex = index
        playNextInsertionAnchorID = nil
        if index >= 0 && index < tracks.count {
            play(track: tracks[index])
        }
    }

    func restorePausedPlayback(_ tracks: [Track], startingAt index: Int, positionSeconds: Double) {
        queue = tracks
        guard index >= 0, index < tracks.count else { return }
        currentIndex = index
        playNextInsertionAnchorID = nil
        let track = tracks[index]
        currentTrack = track
        duration = track.duration
        currentTime = min(max(0, positionSeconds), track.duration)
        isPlaying = false
    }

    func updateQueueTracks(_ tracks: [Track]) {
        queue = tracks
        playNextInsertionAnchorID = nil
        if let currentID = currentTrack?.id,
            let idx = tracks.firstIndex(where: { $0.id == currentID })
        {
            currentIndex = idx
        } else {
            currentIndex = min(max(currentIndex, 0), max(0, tracks.count - 1))
        }
    }

    @discardableResult
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int {
        guard let currentID = currentTrack?.id else { return 0 }
        var seenIDs = Set<UUID>()
        let insertionTracks = tracks.filter { track in
            guard track.id != currentID else { return false }
            guard track.availability != .missing else { return false }
            return seenIDs.insert(track.id).inserted
        }
        guard !insertionTracks.isEmpty else { return 0 }

        let insertionIDs = Set(insertionTracks.map(\.id))
        var updatedQueue = queue.filter { !insertionIDs.contains($0.id) }
        guard let currentQueueIndex = updatedQueue.firstIndex(where: { $0.id == currentID }) else {
            return 0
        }

        let insertionIndex: Int
        if let anchorID = playNextInsertionAnchorID,
           let anchorIndex = updatedQueue.firstIndex(where: { $0.id == anchorID }),
           anchorIndex >= currentQueueIndex {
            insertionIndex = min(anchorIndex + 1, updatedQueue.count)
        } else {
            insertionIndex = min(currentQueueIndex + 1, updatedQueue.count)
        }

        updatedQueue.insert(contentsOf: insertionTracks, at: insertionIndex)
        queue = updatedQueue
        currentIndex = queue.firstIndex(where: { $0.id == currentID }) ?? currentQueueIndex
        playNextInsertionAnchorID = insertionTracks.last?.id
        return insertionTracks.count
    }

    func refreshTracks(_ tracks: [Track]) {
        let refreshedByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        guard !refreshedByID.isEmpty else { return }

        queue = queue.map { refreshedByID[$0.id] ?? $0 }
        if let currentID = currentTrack?.id, let refreshedTrack = refreshedByID[currentID] {
            currentTrack = refreshedTrack
            duration = refreshedTrack.duration
            NotificationCenter.default.post(name: .playbackTrackDidChange, object: nil)
        }
    }

    func currentQueueTracks() -> [Track] {
        queue
    }

    func currentQueueDisplayIndex() -> Int? {
        guard !queue.isEmpty, currentIndex >= 0, currentIndex < queue.count else { return nil }
        return currentIndex
    }

    func playTrackFromQueue(_ track: Track) {
        guard let index = queue.firstIndex(where: { $0.id == track.id }) else { return }
        currentIndex = index
        play(track: track)
    }

    func setShuffleEnabled(_ enabled: Bool) {
        AppSettings.shared.shuffleEnabled = enabled
    }

    func discardCurrentPlaybackSessionStatsOnce() {}

    func pause() {
        isPlaying = false
        stopTimer()
        print("⏸️ [Stub] Paused")
    }

    func resume() {
        guard currentTrack != nil else { return }
        isPlaying = true
        startTimer()
        print("▶️ [Stub] Resumed")
    }

    func stop() {
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrack = nil
        stopTimer()
    }

    func next() {
        guard !queue.isEmpty else { return }
        currentIndex = (currentIndex + 1) % queue.count
        play(track: queue[currentIndex])
    }

    func previous() {
        if currentTime > 3 {
            seek(to: 0)
        } else {
            guard !queue.isEmpty else { return }
            currentIndex = (currentIndex - 1 + queue.count) % queue.count
            play(track: queue[currentIndex])
        }
    }

    func seek(to seconds: Double) {
        currentTime = min(max(0, seconds), duration)
        print("⏩ [Stub] Seeked to \(String(format: "%.1f", seconds))s")
    }

    private var tickTask: Task<Void, Never>?

    private func startTimer() {
        tickTask?.cancel()
        tickTask = Task { @MainActor in
            while isPlaying {
                tick()
                try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
                if Task.isCancelled { break }
            }
        }
    }

    private func stopTimer() {
        tickTask?.cancel()
        tickTask = nil
    }

    private func tick() {
        guard isPlaying else { return }
        currentTime += 0.1
        if currentTime >= duration {
            currentTime = duration
            isPlaying = false
            stopTimer()
        }
    }
}
