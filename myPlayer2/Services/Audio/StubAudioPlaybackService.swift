//
//  StubAudioPlaybackService.swift
//  myPlayer2
//
//  TrueMusic - Stub Audio Playback Service
//  Provides fake playback state for UI development.
//

import Foundation

/// Stub implementation for UI previews.
/// Simulates playback state without actual audio.
@Observable
@MainActor
final class StubAudioPlaybackService: AudioPlaybackServiceProtocol {

    // MARK: - State

    private(set) var isPlaying: Bool = false
    var volume: Double = 0.8
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentTrack: Track?

    // MARK: - Private

    private var timer: Timer?
    private var queue: [Track] = []
    private var currentIndex: Int = 0

    // MARK: - Playback Control

    func play(track: Track) {
        currentTrack = track
        duration = track.duration
        currentTime = 0
        isPlaying = true
        startTimer()
        print("▶️ [Stub] Playing: \(track.title)")
    }

    func playTracks(_ tracks: [Track], startingAt index: Int) {
        queue = tracks
        currentIndex = index
        if index >= 0 && index < tracks.count {
            play(track: tracks[index])
        }
    }

    func updateQueueTracks(_ tracks: [Track]) {
        queue = tracks
        if let currentID = currentTrack?.id,
            let idx = tracks.firstIndex(where: { $0.id == currentID })
        {
            currentIndex = idx
        } else {
            currentIndex = min(max(currentIndex, 0), max(0, tracks.count - 1))
        }
    }

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

    // MARK: - Timer

    private func startTimer() {
        stopTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
