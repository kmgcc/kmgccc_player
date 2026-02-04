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
    private var queue: [Track] = []
    private var queueIndex: Int = 0
    private var shuffleHistory: [Int] = []
    private var activeScheduleToken = UUID()

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

    // MARK: - Scheduling Helpers

    private func invalidateScheduleToken() {
        activeScheduleToken = UUID()
    }

    private func scheduleFile(_ file: AVAudioFile) {
        let token = UUID()
        activeScheduleToken = token
        playerNode.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackCompletion(token: token)
            }
        }
    }

    private func scheduleSegment(
        _ file: AVAudioFile,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) {
        let token = UUID()
        activeScheduleToken = token
        playerNode.scheduleSegment(
            file,
            startingFrame: startingFrame,
            frameCount: frameCount,
            at: nil
        ) { [weak self] in
            Task { @MainActor in
                self?.handlePlaybackCompletion(token: token)
            }
        }
    }

    // MARK: - Playback Control

    func play(track: Track) {
        print("🎵 play(track:) called for: \(track.title)")
        // Single-track play resets queue to just this track.
        queue = [track]
        queueIndex = 0
        shuffleHistory.removeAll()
        playInternal(track: track)
    }

    private func playInternal(track: Track) {
        // Stop current playback but keep queue state.
        stopPlayback(clearQueue: false)

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
            scheduleFile(audioFile)

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
        stopPlayback(clearQueue: true)
    }

    private func stopPlayback(clearQueue: Bool) {
        print("⏹️ stop() called")

        invalidateScheduleToken()
        playerNode.stop()
        stopProgressTimer()
        stopAccessingCurrentFile()

        // Reset playback state
        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrack = nil
        audioFile = nil
        startingFramePosition = 0

        if clearQueue {
            queue.removeAll()
            queueIndex = 0
            shuffleHistory.removeAll()
        }
    }

    func seek(to seconds: Double) {
        guard let audioFile = audioFile else { return }

        let wasPlaying = isPlaying

        // Stop current playback
        invalidateScheduleToken()
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

        scheduleSegment(audioFile, startingFrame: targetFrame, frameCount: frameCount)

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
        queue = tracks
        queueIndex = index
        shuffleHistory.removeAll()
        playInternal(track: tracks[index])
    }

    func next() {
        guard !queue.isEmpty else { return }
        let nextIndex = computeNextIndex(autoAdvance: false)
        queueIndex = nextIndex
        playInternal(track: queue[nextIndex])
    }

    func previous() {
        guard !queue.isEmpty else { return }

        // Standard behavior: if you're a few seconds in, restart.
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        let prevIndex = computePreviousIndex()
        queueIndex = prevIndex
        playInternal(track: queue[prevIndex])
    }

    private enum RepeatMode: String {
        case off
        case all
        case one
    }

    private var repeatMode: RepeatMode {
        RepeatMode(rawValue: AppSettings.shared.repeatMode) ?? .off
    }

    private var shuffleEnabled: Bool {
        AppSettings.shared.shuffleEnabled
    }

    private func computeNextIndex(autoAdvance: Bool) -> Int {
        if autoAdvance, repeatMode == .one {
            return queueIndex
        }

        if shuffleEnabled, queue.count > 1 {
            // Pick a random next different from current; store history for previous().
            shuffleHistory.append(queueIndex)
            var candidate = queueIndex
            var tries = 0
            while candidate == queueIndex && tries < 8 {
                candidate = Int.random(in: 0..<queue.count)
                tries += 1
            }
            return candidate == queueIndex ? (queueIndex + 1) % queue.count : candidate
        }

        let next = queueIndex + 1
        if next < queue.count {
            return next
        }
        return repeatMode == .all ? 0 : queueIndex
    }

    private func computePreviousIndex() -> Int {
        if shuffleEnabled, let last = shuffleHistory.popLast() {
            return last
        }
        let prev = queueIndex - 1
        if prev >= 0 {
            return prev
        }
        return repeatMode == .all ? max(0, queue.count - 1) : queueIndex
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

    private func handlePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
        // Only handle if we think we're still playing
        guard isPlaying else { return }

        stopProgressTimer()

        print("✅ Playback completed: \(currentTrack?.title ?? "unknown")")

        guard !queue.isEmpty else {
            isPlaying = false
            currentTime = duration
            return
        }

        if repeatMode == .one {
            playInternal(track: queue[queueIndex])
            return
        }

        let nextIndex = computeNextIndex(autoAdvance: true)
        if nextIndex == queueIndex, repeatMode == .off, !shuffleEnabled {
            // End of queue and no repeat.
            isPlaying = false
            currentTime = duration
            return
        }

        queueIndex = nextIndex
        playInternal(track: queue[nextIndex])
    }

    // MARK: - File Access

    private func stopAccessingCurrentFile() {
        if let url = currentFileURL {
            url.stopAccessingSecurityScopedResource()
            currentFileURL = nil
        }
    }
}
