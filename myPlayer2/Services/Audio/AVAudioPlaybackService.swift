//
//  AVAudioPlaybackService.swift
//  myPlayer2
//
//  kmgccc_player - AVAudioEngine Playback Service
//  Real audio playback using AVAudioEngine + AVAudioPlayerNode.
//  Integrated with Smart Shuffle for preference-based random playback.
//

import AVFoundation
import Foundation
import SwiftData
import SwiftUI

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
            playerNode.volume = Float(volume)
            AppSettings.shared.volume = volume
        }
    }

    // MARK: - Audio Engine Components

    /// Lazy initialization: engine is only created on first access.
    /// This defers ~15-30ms of AVAudioEngine construction from app launch to first use.
    @ObservationIgnored
    private lazy var engine: AVAudioEngine = {
        let e = AVAudioEngine()
        setupEngine(e)
        return e
    }()

    /// Set once engine has been accessed (for guard checks without triggering lazy init)
    @ObservationIgnored
    private var isEngineInitialized: Bool { engineAccessed }
    @ObservationIgnored
    private var engineAccessed = false

    private let playerNode = AVAudioPlayerNode()
    private let delayNode = AVAudioUnitDelay()
    private var audioFile: AVAudioFile?

    // MARK: - Playback State

    private var sampleRate: Double = 44100
    private var startingFramePosition: AVAudioFramePosition = 0
    private var activeScheduleToken = UUID()
    private var completionWorkItem: DispatchWorkItem?
    private var drainStartUptime: TimeInterval?
    private var drainStartTime: Double = 0
    private var lastKnownShuffleEnabled = AppSettings.shared.shuffleEnabled
    private var lastKnownRepeatMode = AppSettings.shared.repeatMode

    // MARK: - Smart Shuffle Integration

    private let smartController = SmartPlaybackController()

    // MARK: - Timer

    private var progressTimer: Timer?

    // MARK: - Current File Access

    private var currentFileURL: URL?

    // MARK: - Seek Detection

    private var isSeeking = false
    private var seekStartTime: Double = 0

    // MARK: - Level Meter Integration

    /// The main mixer node (exposed for level meter tap)
    /// Accessing this property triggers lazy engine initialization.
    var mainMixerNode: AVAudioMixerNode {
        engineAccessed = true
        return engine.mainMixerNode
    }

    // MARK: - Initialization

    init() {
        self.volume = AppSettings.shared.volume
        // Engine is now lazily initialized on first access (see `engine` property)
        setupSmartController()
        Log.debug("AVAudioPlaybackService initialized with Smart Shuffle (engine deferred)", category: .audio)
    }

    // MARK: - Setup

    /// Sets up the audio engine with nodes and connections.
    /// Called once when engine is first accessed via lazy initialization.
    private func setupEngine(_ engine: AVAudioEngine) {
        engine.attach(playerNode)
        engine.attach(delayNode)

        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: mainMixer, format: nil)

        engine.disconnectNodeOutput(mainMixer)
        engine.connect(mainMixer, to: delayNode, format: nil)
        engine.connect(delayNode, to: engine.outputNode, format: nil)

        configureDelay()
        playerNode.volume = Float(volume)
        engine.prepare()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleEngineConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: engine
        )
    }

    private func setupSmartController() {
        smartController.onPlayTrack = { [weak self] track in
            self?.playInternal(track: track)
        }
        smartController.onTrackChanged = { [weak self] track in
            self?.currentTrack = track
        }
    }

    // MARK: - Engine Management

    @objc private func handleEngineConfigurationChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.reconnectEngineAndResume()
        }
    }

    private func reconnectEngineAndResume() async {
        let wasPlaying = isPlaying
        let savedTime = currentTime
        let savedTrack = currentTrack
        let savedVolume = volume

        Log.debug("Audio device changed. Was playing: \(wasPlaying), position: \(String(format: "%.1f", savedTime))s", category: .audio)

        playerNode.stop()
        stopProgressTimer()
        reconnectAudioGraph()

        do {
            if !engine.isRunning {
                try engine.start()
                Log.info("Engine restarted after device change", category: .audio)
            }
        } catch {
            Log.error("Failed to restart engine after device change: \(error)", category: .audio)
            isPlaying = false
            return
        }

        if wasPlaying, let _ = savedTrack, let file = audioFile {
            let targetFrame = AVAudioFramePosition(savedTime * sampleRate)
            let totalFrames = file.length

            guard targetFrame >= 0, targetFrame < totalFrames else {
                Log.warning("Cannot resume: invalid position", category: .audio)
                isPlaying = false
                return
            }

            let frameCount = AVAudioFrameCount(totalFrames - targetFrame)
            startingFramePosition = targetFrame

            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
            scheduleSegment(file, startingFrame: targetFrame, frameCount: frameCount)
            playerNode.play()
            isPlaying = true
            startProgressTimer()
            playerNode.volume = Float(savedVolume)

            Log.info("Resumed playback at \(String(format: "%.1f", savedTime))s after device change", category: .playback)
        } else {
            isPlaying = false
        }
    }

    private func reconnectAudioGraph() {
        let mainMixer = engine.mainMixerNode

        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(mainMixer)
        engine.disconnectNodeOutput(delayNode)

        if let file = audioFile {
            engine.connect(playerNode, to: mainMixer, format: file.processingFormat)
        } else {
            engine.connect(playerNode, to: mainMixer, format: nil)
        }
        engine.connect(mainMixer, to: delayNode, format: nil)
        engine.connect(delayNode, to: engine.outputNode, format: nil)
        configureDelay()
    }

    // MARK: - Lookahead (Audio Delay)

    private var lookaheadSeconds: Double {
        let ms = max(0, min(200, AppSettings.shared.lookaheadMs))
        return ms / 1000.0
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
            Task { @MainActor [weak self] in
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
            Task { @MainActor [weak self] in
                self?.handlePlaybackCompletion(token: token)
            }
        }
    }

    // MARK: - Playback Control

    func play(track: Track) {
        Log.debug("play(track:) called for: \(track.title)", category: .audio)
        let shuffleEnabled = AppSettings.shared.shuffleEnabled
        smartController.startPlayback(tracks: [track], startingAt: 0, shuffle: shuffleEnabled)
    }

    func playTracks(_ tracks: [Track], startingAt index: Int) {
        guard index >= 0, index < tracks.count else { return }
        let shuffleEnabled = AppSettings.shared.shuffleEnabled

        // Update last known settings
        lastKnownShuffleEnabled = shuffleEnabled
        lastKnownRepeatMode = AppSettings.shared.repeatMode

        // Pass to smart controller
        smartController.startPlayback(tracks: tracks, startingAt: index, shuffle: shuffleEnabled)
    }

    private func playInternal(track: Track) {
        stopPlayback(clearQueue: false)
        configureDelay()
        resetDelayBuffer()

        let result = track.resolveFileURL()
        track.availability = result.newAvailability

        guard let fileURL = result.url else {
            print("❌ Cannot play track: file not accessible - \(track.title)")
            return
        }

        currentFileURL = fileURL

        if let refreshedData = result.refreshedBookmarkData {
            track.fileBookmarkData = refreshedData
        }

        do {
            audioFile = try AVAudioFile(forReading: fileURL)

            guard let audioFile = audioFile else { return }

            sampleRate = audioFile.processingFormat.sampleRate
            let fileDuration = Double(audioFile.length) / sampleRate

            currentTrack = track
            duration = fileDuration
            currentTime = 0
            startingFramePosition = 0

            engine.disconnectNodeOutput(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: audioFile.processingFormat)

            if !engine.isRunning {
                try engine.start()
            }

            scheduleFile(audioFile)
            playerNode.play()
            isPlaying = true
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

        configureDelay()
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
        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBuffer()
        stopProgressTimer()
        stopAccessingCurrentFile()

        isPlaying = false
        currentTime = 0
        duration = 0
        currentTrack = nil
        audioFile = nil
        startingFramePosition = 0

        if clearQueue {
            smartController.stop()
        }
    }

    func seek(to seconds: Double) {
        guard let audioFile = audioFile else { return }

        let wasPlaying = isPlaying

        // Mark that we're seeking
        isSeeking = true
        smartController.beginSeek()
        seekStartTime = seconds

        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBuffer()
        isPlaying = false

        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let totalFrames = audioFile.length

        guard targetFrame >= 0, targetFrame < totalFrames else {
            print("⚠️ Seek position out of range")
            isSeeking = false
            smartController.endSeek()
            return
        }

        let frameCount = AVAudioFrameCount(totalFrames - targetFrame)

        startingFramePosition = targetFrame
        currentTime = max(0, min(seconds - lookaheadSeconds, duration))

        scheduleSegment(audioFile, startingFrame: targetFrame, frameCount: frameCount)

        if wasPlaying {
            playerNode.play()
            isPlaying = true
            startProgressTimer()
        }

        // Clear seeking flag after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isSeeking = false
            self?.smartController.endSeek()
        }

        print("⏩ Seeked to \(String(format: "%.1f", seconds))s")
    }

    // MARK: - Queue Management

    func updateQueueTracks(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        smartController.updateQueue(tracks: tracks, preservePosition: true)
    }

    func refreshTracks(_ tracks: [Track]) {
        let refreshedByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
        guard !refreshedByID.isEmpty else { return }

        // Update current track if it was refreshed
        if let currentID = currentTrack?.id, let refreshedTrack = refreshedByID[currentID] {
            currentTrack = refreshedTrack
            duration = refreshedTrack.duration
            NotificationCenter.default.post(name: .playbackTrackDidChange, object: nil)
        }
    }

    func next() {
        syncShuffleStateIfNeeded()
        smartController.nextTrack()
    }

    func previous() {
        syncShuffleStateIfNeeded()

        // Standard behavior: if you're a few seconds in, restart.
        if currentTime > 3 {
            seek(to: 0)
            return
        }

        smartController.previousTrack()
    }

    private func syncShuffleStateIfNeeded() {
        let enabled = AppSettings.shared.shuffleEnabled
        guard enabled != lastKnownShuffleEnabled else { return }

        lastKnownShuffleEnabled = enabled
        smartController.setShuffle(enabled)
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        stopProgressTimer()

        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
            [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateProgress()
            }
        }

        if let timer = progressTimer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateProgress() {
        let nowUptime = ProcessInfo.processInfo.systemUptime

        if let drainStartUptime {
            let elapsed = max(0, nowUptime - drainStartUptime)
            currentTime = min(duration, drainStartTime + elapsed)
            return
        }

        guard isPlaying else { return }
        guard playerNode.isPlaying else { return }

        guard let nodeTime = playerNode.lastRenderTime,
            nodeTime.isSampleTimeValid,
            let playerTime = playerNode.playerTime(forNodeTime: nodeTime)
        else {
            return
        }

        let currentFrame = startingFramePosition + playerTime.sampleTime
        let newTime = Double(currentFrame) / sampleRate

        let audibleTime = newTime - lookaheadSeconds
        let previousTime = currentTime
        currentTime = max(0, min(audibleTime, duration))

        // Update smart controller with progress
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }
    }

    // MARK: - Playback Completion

    private func handlePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
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

        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(lookaheadSeconds * 1_000_000_000))
            self.finalizePlaybackCompletion(token: token)
        }
    }

    private func finalizePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
        cancelPendingCompletion()
        stopProgressTimer()

        print("✅ Playback completed: \(currentTrack?.title ?? "unknown")")

        let stopAfterTrack = AppSettings.shared.stopAfterTrack
        let repeatMode = RepeatMode(rawValue: AppSettings.shared.repeatMode) ?? .off

        if stopAfterTrack {
            isPlaying = false
            currentTime = duration
            return
        }

        if repeatMode == .one, let track = currentTrack {
            playInternal(track: track)
            return
        }

        // Auto-advance via smart controller
        smartController.autoAdvance()
    }

    // MARK: - File Access

    private func stopAccessingCurrentFile() {
        if let url = currentFileURL {
            url.stopAccessingSecurityScopedResource()
            currentFileURL = nil
        }
    }

    // MARK: - Queue Access for Fullscreen Queue View

    func currentQueueTracks() -> [Track] {
        return smartController.getCurrentQueue()
    }

    func currentQueueDisplayIndex() -> Int? {
        return smartController.getCurrentQueueIndex()
    }

    func playTrackFromQueue(_ track: Track) {
        smartController.jumpToTrackInQueue(track)
    }

    func setShuffleEnabled(_ enabled: Bool) {
        AppSettings.shared.shuffleEnabled = enabled
        lastKnownShuffleEnabled = enabled
        smartController.setShuffle(enabled)
    }

    func discardCurrentPlaybackSessionStatsOnce() {
        smartController.discardCurrentSessionStatsOnFinalizeOnce()
    }

    // MARK: - Repeat Mode

    private enum RepeatMode: String {
        case off
        case all
        case one
    }
}
