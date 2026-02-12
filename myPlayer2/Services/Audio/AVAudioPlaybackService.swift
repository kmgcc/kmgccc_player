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
    private(set) var currentTrack: Track? {
        didSet {
            guard oldValue?.id != currentTrack?.id else { return }
            NotificationCenter.default.post(name: .playbackTrackDidChange, object: nil)
        }
    }

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
    private let delayNode = AVAudioUnitDelay()
    private var audioFile: AVAudioFile?

    // MARK: - Playback State

    private var sampleRate: Double = 44100
    private var startingFramePosition: AVAudioFramePosition = 0
    private var queue: [Track] = []
    private var queueIndex: Int = 0
    private let shuffleQueue = ShuffleQueueManager(recentLimit: 15)
    private var lastKnownShuffleEnabled = AppSettings.shared.shuffleEnabled
    private var activeScheduleToken = UUID()
    private var completionWorkItem: DispatchWorkItem?
    private var drainStartUptime: TimeInterval?
    private var drainStartTime: Double = 0
    private var lastLookaheadMs: Double = AppSettings.shared.lookaheadMs

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
        engine.attach(delayNode)

        // Connect player to main mixer
        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: mainMixer, format: nil)

        // Route main mixer through delay before output
        engine.disconnectNodeOutput(mainMixer)
        engine.connect(mainMixer, to: delayNode, format: nil)
        engine.connect(delayNode, to: engine.outputNode, format: nil)

        // Apply initial lookahead delay
        configureDelay()

        // Apply initial volume
        applyVolume()

        // Prepare engine
        engine.prepare()
    }

    private func applyVolume() {
        playerNode.volume = Float(volume)
    }

    // MARK: - Lookahead (Audio Delay)

    private var lookaheadSeconds: Double {
        let ms = max(0, min(200, lastLookaheadMs))
        return ms / 1000.0
    }

    private func updateLookaheadIfNeeded(force: Bool = false) {
        let newMs = AppSettings.shared.lookaheadMs
        if force || abs(newMs - lastLookaheadMs) > 0.1 {
            lastLookaheadMs = newMs
            configureDelay()
        }
    }

    private func configureDelay() {
        let seconds = lookaheadSeconds
        delayNode.delayTime = seconds
        delayNode.feedback = 0
        delayNode.wetDryMix = seconds > 0 ? 100 : 0
        delayNode.lowPassCutoff = 20_000
        delayNode.reset()
    }

    private func resetDelayBuffer() {
        delayNode.reset()
    }

    private func cancelPendingCompletion() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        drainStartUptime = nil
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
        shuffleQueue.rebuild(with: [track.id], currentTrackID: track.id, resetHistory: true)
        playInternal(track: track)
    }

    private func playInternal(track: Track) {
        // Stop current playback but keep queue state.
        stopPlayback(clearQueue: false)
        updateLookaheadIfNeeded(force: true)
        resetDelayBuffer()

        // Resolve bookmark/local library path to get file URL
        let result = track.resolveFileURL()
        track.availability = result.newAvailability

        guard let fileURL = result.url else {
            print("❌ Cannot play track: file not accessible - \(track.title)")
            return
        }

        currentFileURL = fileURL

        // Update bookmark if stale
        if let refreshedData = result.refreshedBookmarkData {
            track.fileBookmarkData = refreshedData
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

        cancelPendingCompletion()
        playerNode.pause()
        resetDelayBuffer()
        isPlaying = false
        stopProgressTimer()

        print("⏸️ Paused at \(String(format: "%.1f", currentTime))s")
    }

    func resume() {
        guard !isPlaying, audioFile != nil else { return }

        updateLookaheadIfNeeded(force: true)
        resetDelayBuffer()
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

        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBuffer()
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
            shuffleQueue.reset()
        }
    }

    func seek(to seconds: Double) {
        guard let audioFile = audioFile else { return }

        let wasPlaying = isPlaying

        // Stop current playback
        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBuffer()
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
        updateLookaheadIfNeeded(force: true)
        currentTime = max(0, min(seconds - lookaheadSeconds, duration))

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
        shuffleQueue.rebuild(
            with: tracks.map(\.id),
            currentTrackID: tracks[index].id,
            resetHistory: true
        )
        lastKnownShuffleEnabled = shuffleEnabled
        playInternal(track: tracks[index])
    }

    func updateQueueTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        queue = tracks

        if let currentID = currentTrack?.id,
            let index = queue.firstIndex(where: { $0.id == currentID })
        {
            queueIndex = index
            shuffleQueue.rebuild(
                with: tracks.map(\.id),
                currentTrackID: currentID,
                resetHistory: false
            )
        } else {
            queueIndex = min(max(queueIndex, 0), max(0, queue.count - 1))
            let currentID = queue.indices.contains(queueIndex) ? queue[queueIndex].id : nil
            shuffleQueue.rebuild(
                with: tracks.map(\.id),
                currentTrackID: currentID,
                resetHistory: true
            )
        }
    }

    func next() {
        guard !queue.isEmpty else { return }
        syncShuffleStateIfNeeded()
        let nextIndex = computeNextIndex(autoAdvance: false)
        queueIndex = nextIndex
        playInternal(track: queue[nextIndex])
    }

    func previous() {
        guard !queue.isEmpty else { return }
        syncShuffleStateIfNeeded()

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
            let currentID = queue[queueIndex].id
            guard
                let nextID = shuffleQueue.nextTrackID(currentTrackID: currentID),
                let nextIndex = queue.firstIndex(where: { $0.id == nextID })
            else {
                return queueIndex
            }
            return nextIndex
        }

        let next = queueIndex + 1
        if next < queue.count {
            return next
        }
        return repeatMode == .all ? 0 : queueIndex
    }

    private func computePreviousIndex() -> Int {
        if shuffleEnabled, let lastID = shuffleQueue.previousTrackID(),
            let idx = queue.firstIndex(where: { $0.id == lastID })
        {
            return idx
        }
        let prev = queueIndex - 1
        if prev >= 0 {
            return prev
        }
        return repeatMode == .all ? max(0, queue.count - 1) : queueIndex
    }

    private func syncShuffleStateIfNeeded() {
        let enabled = shuffleEnabled
        guard enabled != lastKnownShuffleEnabled else { return }
        lastKnownShuffleEnabled = enabled
        if enabled {
            let currentID = queue.indices.contains(queueIndex) ? queue[queueIndex].id : nil
            shuffleQueue.rebuild(
                with: queue.map(\.id),
                currentTrackID: currentID,
                resetHistory: false
            )
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
        updateLookaheadIfNeeded()
        let nowUptime = ProcessInfo.processInfo.systemUptime

        if let drainStartUptime {
            let elapsed = max(0, nowUptime - drainStartUptime)
            currentTime = min(duration, drainStartTime + elapsed)
            return
        }

        guard isPlaying else { return }
        guard playerNode.isPlaying else {
            // Node stopped but we think we're playing - wait for completion handler
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

        // Apply lookahead delay so UI/lyrics match audible output
        let audibleTime = newTime - lookaheadSeconds
        currentTime = max(0, min(audibleTime, duration))
    }

    // MARK: - Playback Completion

    private func handlePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
        // Only handle if we think we're still playing
        guard isPlaying else { return }
        let delaySeconds = lookaheadSeconds
        if delaySeconds > 0 {
            beginDrain(lookaheadSeconds: delaySeconds, token: token)
            return
        }

        finalizePlaybackCompletion(token: token)
    }

    private func beginDrain(lookaheadSeconds: Double, token: UUID) {
        cancelPendingCompletion()
        drainStartUptime = ProcessInfo.processInfo.systemUptime
        drainStartTime = max(0, duration - lookaheadSeconds)
        currentTime = drainStartTime

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                self.finalizePlaybackCompletion(token: token)
            }
        }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + lookaheadSeconds, execute: work)
    }

    private func finalizePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
        cancelPendingCompletion()
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
