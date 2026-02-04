//
//  AVAudioPlaybackService.swift
//  myPlayer2
//
//  TrueMusic - AVAudioEngine Playback Service
//  Real audio playback using AVAudioEngine + AVAudioPlayerNode.
//

import AVFoundation
import Foundation

/// Real audio playback service using AVAudioEngine.
@Observable
@MainActor
final class AVAudioPlaybackService: AudioPlaybackServiceProtocol {

    // MARK: - Published State

    private(set) var isPlaying: Bool = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var currentTrack: Track?

    var volume: Double {
        didSet {
            applyVolume()
            // Persist to AppSettings
            AppSettings.shared.volume = volume
        }
    }

    // MARK: - Audio Engine Components

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFile: AVAudioFile?

    // MARK: - Playback State

    private var sampleRate: Double = 44100
    private var startingFramePosition: AVAudioFramePosition = 0

    // MARK: - Timer

    private var progressTimer: Timer?

    // MARK: - Current File Access

    private var currentFileURL: URL?

    // MARK: - Level Meter Integration

    /// The main mixer node (exposed for level meter tap)
    var mainMixerNode: AVAudioMixerNode {
        engine.mainMixerNode
    }

    // MARK: - Initialization

    init() {
        // Restore volume from settings
        self.volume = AppSettings.shared.volume
        setupEngine()
        print("🎵 AVAudioPlaybackService initialized")
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        // Attach player node to engine
        engine.attach(playerNode)

        // Connect player to main mixer
        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: mainMixer, format: nil)

        // Apply initial volume
        applyVolume()

        // Prepare engine
        engine.prepare()
    }

    private func applyVolume() {
        playerNode.volume = Float(volume)
    }

    // MARK: - Playback Control

    func play(track: Track) {
        print("🎵 play(track:) called for: \(track.title)")

        // Stop any current playback
        stop()

        // Resolve bookmark to get file URL
        let result = track.resolveFileURL()

        guard let fileURL = result.url else {
            print("❌ Cannot play track: file not accessible - \(track.title)")
            return
        }

        currentFileURL = fileURL

        // Update bookmark if stale
        if let refreshedData = result.refreshedBookmarkData {
            track.fileBookmarkData = refreshedData
            track.availability = result.newAvailability
        }

        do {
            // Load audio file
            audioFile = try AVAudioFile(forReading: fileURL)

            guard let audioFile = audioFile else { return }

            // Get file properties
            sampleRate = audioFile.processingFormat.sampleRate
            let fileDuration = Double(audioFile.length) / sampleRate

            // Set state BEFORE starting playback
            currentTrack = track
            duration = fileDuration
            currentTime = 0
            startingFramePosition = 0

            // Reconnect player with correct format
            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            // Start engine if not running
            if !engine.isRunning {
                try engine.start()
            }

            // Schedule entire file
            playerNode.scheduleFile(audioFile, at: nil) { [weak self] in
                Task { @MainActor in
                    self?.handlePlaybackCompletion()
                }
            }

            // Start playback
            playerNode.play()

            // Set isPlaying AFTER playerNode.play()
            isPlaying = true

            // Start progress timer
            startProgressTimer()

            print("▶️ Playing: \(track.title) (duration: \(String(format: "%.1f", fileDuration))s)")

        } catch {
            print("❌ Failed to load audio file: \(error)")
            stopAccessingCurrentFile()
        }
    }

    func pause() {
        guard isPlaying else { return }

        playerNode.pause()
        isPlaying = false
        stopProgressTimer()

        print("⏸️ Paused at \(String(format: "%.1f", currentTime))s")
    }

    func resume() {
        guard !isPlaying, audioFile != nil else { return }

        playerNode.play()
        isPlaying = true
        startProgressTimer()

        print("▶️ Resumed from \(String(format: "%.1f", currentTime))s")
    }

    func stop() {
        print("⏹️ stop() called")

        playerNode.stop()
        stopProgressTimer()
        stopAccessingCurrentFile()

        // Reset all state
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrack = nil
        audioFile = nil
        startingFramePosition = 0
    }

    func seek(to seconds: Double) {
        guard let audioFile = audioFile else { return }

        let wasPlaying = isPlaying

        // Stop current playback
        playerNode.stop()
        isPlaying = false

        // Calculate frame position
        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let totalFrames = audioFile.length

        guard targetFrame >= 0, targetFrame < totalFrames else {
            print("⚠️ Seek position out of range")
            return
        }

        let frameCount = AVAudioFrameCount(totalFrames - targetFrame)

        // Schedule from new position
        startingFramePosition = targetFrame
        currentTime = seconds

        playerNode.scheduleSegment(
            audioFile,
            startingFrame: targetFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackCompletion()
            }
        }

        if wasPlaying {
            playerNode.play()
            isPlaying = true
            startProgressTimer()
        }

        print("⏩ Seeked to \(String(format: "%.1f", seconds))s")
    }

    // MARK: - Queue Management (simplified for now)

    func playTracks(_ tracks: [Track], startingAt index: Int) {
        guard index >= 0, index < tracks.count else { return }
        play(track: tracks[index])
        // TODO: Store queue for next/previous
    }

    func next() {
        // TODO: Implement queue-based next
        stop()
    }

    func previous() {
        // TODO: Implement queue-based previous
        // For now, restart current track
        if currentTime > 3 {
            seek(to: 0)
        } else {
            seek(to: 0)
        }
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()

        // Use Timer for progress updates (10 times per second)
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            Task { @MainActor in
                self?.updateProgress()
            }
        }

        // Add to common run loop mode to ensure updates during UI interactions
        if let timer = progressTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        guard isPlaying else { return }
        guard playerNode.isPlaying else {
            // Node stopped but we think we're playing - sync state
            return
        }

        guard let nodeTime = playerNode.lastRenderTime,
            nodeTime.isSampleTimeValid,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            // lastRenderTime not yet available, wait for next tick
            return
        }

        let currentFrame = startingFramePosition + playerTime.sampleTime
        let newTime = Double(currentFrame) / sampleRate

        // Clamp to duration and ensure non-negative
        currentTime = max(0, min(newTime, duration))
    }

    // MARK: - Playback Completion

    private func handlePlaybackCompletion() {
        // Only handle if we think we're still playing
        guard isPlaying else { return }

        // Check if playerNode actually stopped
        guard !playerNode.isPlaying else { return }

        isPlaying = false
        currentTime = duration
        stopProgressTimer()

        print("✅ Playback completed: \(currentTrack?.title ?? "unknown")")

        // TODO: Auto-play next track in queue
    }

    // MARK: - File Access

    private func stopAccessingCurrentFile() {
        if let url = currentFileURL {
            url.stopAccessingSecurityScopedResource()
            currentFileURL = nil
        }
    }
}
