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
    /// Optional output-chain delay used for visualization sync. Always attached,
    /// but only inserted into the signal path while `activeLookaheadEnabled` is
    /// true (user opt-in). See `rebuildOutputChain`.
    private let delayNode = AVAudioUnitDelay()
    private var audioFile: AVAudioFile?

    // MARK: - Playback State

    private var sampleRate: Double = 44100
    private var startingFramePosition: AVAudioFramePosition = 0
    private var activeScheduleToken = UUID()
    private var completionWorkItem: DispatchWorkItem?
    /// The lookahead-delay state actually realized in the audio graph. Distinct
    /// from `AppSettings.shared.audioLookaheadEnabled` (the desired state): the
    /// toggle is applied to the live graph only at the start of a track, so an
    /// in-flight track keeps a stable pipeline. All delay handling (progress
    /// compensation, drain, buffer resets) keys off this realized flag.
    private var activeLookaheadEnabled = false
    /// Drain bookkeeping: when lookahead is active, ~lookahead seconds of audio
    /// still sit in the delay buffer after the player finishes scheduling, so
    /// completion is deferred and progress is advanced from these anchors.
    private var drainStartUptime: TimeInterval?
    private var drainStartTime: Double = 0
    private var lastProgressUpdateUptime: TimeInterval?
    private var lastProgressAudibleTime: Double = 0
    private var lastKnownShuffleEnabled = AppSettings.shared.shuffleEnabled
    private var lastKnownRepeatMode = AppSettings.shared.repeatMode

    // MARK: - Off-Main Preparation

    /// Off-main file preparation (bookmark resolve + AVAudioFile open). See
    /// `AudioFilePreparationActor`.
    private let prepActor = AudioFilePreparationActor()
    /// Monotonic id for the current play request. Bumped ONLY by
    /// `invalidatePreparation()` (called from `stopPlayback`). A prepared
    /// resource is consumed only if its captured generation still matches —
    /// this discards stale results from a track the user already switched away
    /// from. See `invalidatePreparation()` for why there is a single bump site.
    private var playGeneration: UInt64 = 0
    /// The in-flight preparation task, cancelled when a newer request starts.
    private var prepTask: Task<Void, Never>?

    // MARK: - Smart Shuffle Integration

    private let smartController = SmartPlaybackController()

    // MARK: - Timer

    private var progressTimer: Timer?

    // MARK: - Current File Access

    private var currentFileURL: URL?
    /// Whether `currentFileURL` holds an active security-scoped access that must
    /// be released on stop/replace. Mirrors
    /// `PreparedAudioResource.didStartSecurityScopedAccess` for the
    /// currently-loaded file. False for library-relative paths.
    private var currentFileSecurityScoped = false

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
        Log.info(
            "[PlaybackPipeline] AVAudioPlaybackService init id=\(ObjectIdentifier(self)) engine=deferred",
            category: .audio
        )
    }

    deinit {
        Log.info(
            "[PlaybackPipeline] AVAudioPlaybackService deinit id=\(ObjectIdentifier(self))",
            category: .audio
        )
    }

    // MARK: - Setup

    /// Sets up the audio engine with nodes and connections.
    /// Called once when engine is first accessed via lazy initialization.
    private func setupEngine(_ engine: AVAudioEngine) {
        engine.attach(playerNode)
        engine.attach(delayNode)

        let mainMixer = engine.mainMixerNode
        engine.connect(playerNode, to: mainMixer, format: nil)
        // Realize the output chain from the current user preference. The mixer
        // tap (FFT/LED) is installed separately on mainMixerNode and is not
        // affected by output-chain (re)wiring.
        rebuildOutputChain(engine, lookahead: desiredLookaheadEnabled)

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

    @objc nonisolated private func handleEngineConfigurationChange(_ notification: Notification) {
        // AVAudioEngine may post this notification from its internal engine queue.
        // Keep the ObjC entrypoint nonisolated so Swift 6 does not assert that
        // the CoreAudio callback is already running on MainActor.
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

        AudioAnalysisHub.shared.prepareForEngineConfigurationChange()
        defer {
            AudioAnalysisHub.shared.restoreAfterEngineConfigurationChange()
        }

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

        if let file = audioFile {
            engine.connect(playerNode, to: mainMixer, format: file.processingFormat)
        } else {
            engine.connect(playerNode, to: mainMixer, format: nil)
        }
        // Preserve whatever chain the current track is using; a device change
        // mid-track must not silently switch the lookahead state.
        rebuildOutputChain(engine, lookahead: activeLookaheadEnabled)
    }

    // MARK: - Lookahead (Audio Delay)

    /// Wires `mainMixer → output` (no delay) or `mainMixer → delay → output`,
    /// fully tearing down any prior mixer/delay output connections first so no
    /// duplicate or dangling edges remain. Updates `activeLookaheadEnabled` to
    /// the realized state.
    ///
    /// AVAudioEngine asserts (`!IsRunning()`) if you disconnect a node that
    /// feeds the output while the engine is running, so this stops the engine
    /// first when needed. **Every caller is responsible for restarting the
    /// engine afterward** (all current callers do, before scheduling/playing).
    private func rebuildOutputChain(_ engine: AVAudioEngine, lookahead: Bool) {
        if engine.isRunning {
            engine.stop()
        }
        let mainMixer = engine.mainMixerNode
        engine.disconnectNodeOutput(mainMixer)
        engine.disconnectNodeOutput(delayNode)

        if lookahead {
            engine.connect(mainMixer, to: delayNode, format: nil)
            engine.connect(delayNode, to: engine.outputNode, format: nil)
            activeLookaheadEnabled = true
            configureDelay()
        } else {
            engine.connect(mainMixer, to: engine.outputNode, format: nil)
            activeLookaheadEnabled = false
        }
    }

    /// The lookahead state the user *wants* realized, gated by the debug
    /// bypass. When `audioDebugBypassDelayNode` is true this is always false,
    /// forcing the no-delay direct chain. Default behavior (bypass off) is
    /// unchanged.
    private var desiredLookaheadEnabled: Bool {
        AppSettings.shared.audioLookaheadEnabled && !AppSettings.shared.audioDebugBypassDelayNode
    }

    /// Realized lookahead in seconds (0 when the feature is off in the live
    /// graph). Reads the persisted `lookaheadMs` only when active.
    private var lookaheadSeconds: Double {
        guard activeLookaheadEnabled else { return 0 }
        let ms = max(0, min(200, AppSettings.shared.lookaheadMs))
        return ms / 1000.0
    }

    /// Applies `lookaheadMs` to the delay node. No-op unless lookahead is the
    /// realized state, so a disabled feature never touches the delay node.
    private func configureDelay() {
        guard activeLookaheadEnabled else { return }
        let seconds = lookaheadSeconds
        delayNode.delayTime = seconds
        delayNode.feedback = 0
        delayNode.wetDryMix = seconds > 0 ? 100 : 0
        delayNode.lowPassCutoff = 20_000
        delayNode.reset()
    }

    /// Clears buffered delay-line audio. No-op when lookahead is off.
    private func resetDelayBufferIfActive() {
        guard activeLookaheadEnabled else { return }
        delayNode.reset()
    }

    /// If the user toggled the feature since the current chain was built, rebuild
    /// the output chain to match. Intended to be called at track start while the
    /// player is stopped — this is what makes the toggle "next-playback".
    private func applyLookaheadPreferenceForNewPlayback() {
        let desired = desiredLookaheadEnabled
        guard desired != activeLookaheadEnabled else { return }
        Log.info(
            "[PlaybackPipeline] audio lookahead chain rebuild desired=\(desired)",
            category: .audio
        )
        rebuildOutputChain(engine, lookahead: desired)
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

    /// Invalidate any in-flight file preparation: bump the generation so a
    /// returning `PreparedAudioResource` fails the guard in
    /// `finishStartIfCurrent`, and cancel the background task. This is the
    /// SINGLE generation-bump site. `stopPlayback` calls it, and every
    /// `playInternal` runs `stopPlayback` first — so a new play request
    /// naturally observes a freshly-bumped generation to adopt as its own. Do
    /// NOT add a second bump in `playInternal`; the single site is intentional.
    private func invalidatePreparation() {
        playGeneration &+= 1
        prepTask?.cancel()
        prepTask = nil
    }

    private func scheduleFile(_ file: AVAudioFile) {
        let token = UUID()
        activeScheduleToken = token
        Log.info(
            "[AudioDiagnostics] scheduleFile frames=\(file.length) operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
            category: .audio
        )
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
        Log.info(
            "[AudioDiagnostics] scheduleSegment startFrame=\(startingFrame) frameCount=\(frameCount) operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
            category: .audio
        )
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
        Log.info(
            "[PlaybackPipeline] load item requested track=\(track.id.uuidString) title=\(track.title)",
            category: .audio
        )

        // Stop current audio immediately (matches "switch track = stop now").
        // stopPlayback runs invalidatePreparation() — bumping playGeneration and
        // cancelling any in-flight prepare — and clears currentTrack/audioFile +
        // releases the old file's security scope.
        stopPlayback(clearQueue: false)

        // Adopt the generation stopPlayback just bumped. There is NO second bump
        // here on purpose (see invalidatePreparation()): this request owns the
        // current generation, so its own prepared resource passes the guard,
        // while any earlier in-flight prepare holds an older (cancelled) one.
        let generation = playGeneration

        // Presentation updates immediately; audio follows after the off-main
        // prepare. duration is a placeholder reconciled in finishStart.
        currentTrack = track
        duration = track.duration
        currentTime = 0
        startingFramePosition = 0

        // Cheap MainActor snapshot of the @Model fields the actor needs. Only
        // this Sendable value crosses into the actor — never the Track itself.
        let request = AudioPrepRequest(
            trackID: track.id,
            libraryRelativePath: track.libraryRelativePath,
            fileBookmarkData: track.fileBookmarkData,
            titleForLog: track.title
        )

        // Task {} (not detached) inherits this @MainActor context: the await
        // suspends and the actor runs the heavy work off-main, then resumes on
        // main. The closure captures only Sendable values (request, generation)
        // and self — never `track`, so there is no Swift 6 non-Sendable capture.
        // The Track is re-acquired from currentTrack on resume.
        prepTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resource = try await self.prepActor.prepare(request)
                self.finishStartIfCurrent(resource, generation: generation)
            } catch {
                self.handlePrepareFailureIfCurrent(
                    error,
                    trackID: request.trackID,
                    generation: generation
                )
            }
        }
    }

    /// MainActor: consume a prepared resource only if it is still the current
    /// generation AND the current track still matches; otherwise discard it and
    /// release its security scope.
    private func finishStartIfCurrent(_ resource: PreparedAudioResource, generation: UInt64) {
        guard generation == playGeneration else {
            // Superseded by a newer play request — release and drop.
            releaseSecurityScope(for: resource)
            Log.info(
                "[PlaybackPipeline] prepared resource discarded gen=\(generation) current=\(playGeneration) track=\(resource.trackID.uuidString)",
                category: .audio
            )
            return
        }
        guard let track = currentTrack, track.id == resource.trackID else {
            // currentTrack moved without a generation bump (e.g. cleared): drop.
            releaseSecurityScope(for: resource)
            Log.info(
                "[PlaybackPipeline] prepared resource dropped; currentTrack mismatch track=\(resource.trackID.uuidString)",
                category: .audio
            )
            return
        }
        finishStart(resource, track: track)
    }

    /// Release a prepared resource's security scope, but only if it actually
    /// started one (library-relative paths never do).
    private func releaseSecurityScope(for resource: PreparedAudioResource) {
        if resource.didStartSecurityScopedAccess {
            resource.resolvedURL.stopAccessingSecurityScopedResource()
        }
    }

    /// MainActor: lightweight engine scheduling for an already-prepared file.
    /// No file open / bookmark resolve happens here — only engine ops, which
    /// must run on main (AVAudioEngine is not Sendable).
    private func finishStart(_ resource: PreparedAudioResource, track: Track) {
        let scheduleToken = FirstUseHitchDiagnostics.begin(
            "AudioEngine.schedule",
            detail: "track=\(resource.trackID.uuidString.prefix(8))"
        )
        defer { FirstUseHitchDiagnostics.end(scheduleToken) }

        currentFileURL = resource.resolvedURL
        currentFileSecurityScoped = resource.didStartSecurityScopedAccess
        audioFile = resource.file
        sampleRate = resource.sampleRate
        duration = resource.duration
        currentTime = 0
        startingFramePosition = 0

        track.availability = resource.newAvailability
        if let refreshed = resource.refreshedBookmarkData {
            track.fileBookmarkData = refreshed
        }

        // Realize any pending lookahead toggle now, while the player is stopped
        // (stopPlayback ran in playInternal). This is the "next-playback" point.
        applyLookaheadPreferenceForNewPlayback()

        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: resource.file.processingFormat)

        do {
            if !engine.isRunning {
                try engine.start()
            }
        } catch {
            Log.error("[PlaybackPipeline] engine start failed: \(error)", category: .audio)
            stopAccessingCurrentFile()
            audioFile = nil
            isPlaying = false
            return
        }

        configureDelay()
        resetDelayBufferIfActive()
        scheduleFile(resource.file)
        playerNode.play()
        isPlaying = true
        startProgressTimer()

        Log.info(
            "[PlaybackPipeline] item loaded track=\(resource.trackID.uuidString) duration=\(String(format: "%.1f", resource.duration))s engineRunning=\(engine.isRunning)",
            category: .audio
        )
    }

    /// MainActor: failure handling for a prepare that belongs to the current
    /// generation. Preserves the original behavior — mark availability, log,
    /// stop on this track (no auto-skip). Cancelled / superseded prepares are
    /// dropped silently.
    private func handlePrepareFailureIfCurrent(
        _ error: Error,
        trackID: UUID,
        generation: UInt64
    ) {
        guard generation == playGeneration else { return }
        if error is CancellationError { return }
        if case AudioFilePreparationActor.PrepError.cancelled = error { return }

        // Re-acquire the current track (never captured in the Task).
        guard let track = currentTrack, track.id == trackID else { return }

        switch error {
        case AudioFilePreparationActor.PrepError.missingFile,
             AudioFilePreparationActor.PrepError.bookmarkUnresolved:
            // Resolution failed: mark missing (matches old resolveFileURL path).
            track.availability = .missing
        case AudioFilePreparationActor.PrepError.openFailed:
            // Resolved but failed to open: keep availability (matches old catch).
            break
        default:
            break
        }

        Log.error(
            "[PlaybackPipeline] prepare failed track=\(track.id.uuidString) title=\(track.title) error=\(error)",
            category: .audio
        )
        stopAccessingCurrentFile()
        isPlaying = false
    }

    func pause() {
        guard isPlaying else { return }

        Log.info(
            "[AudioDiagnostics] pause currentTime=\(String(format: "%.3f", currentTime)) operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
            category: .audio
        )
        cancelPendingCompletion()
        playerNode.pause()
        resetDelayBufferIfActive()
        isPlaying = false
        stopProgressTimer()

        print("⏸️ Paused at \(String(format: "%.1f", currentTime))s")
    }

    func resume() {
        guard !isPlaying, audioFile != nil else { return }

        Log.info(
            "[AudioDiagnostics] resume currentTime=\(String(format: "%.3f", currentTime)) operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
            category: .audio
        )
        configureDelay()
        resetDelayBufferIfActive()
        playerNode.play()
        isPlaying = true
        startProgressTimer()

        print("▶️ Resumed from \(String(format: "%.1f", currentTime))s")
    }

    func stop() {
        stopPlayback(clearQueue: true)
    }

    private func stopPlayback(clearQueue: Bool) {
        Log.info(
            "[PlaybackPipeline] stopPlayback clearQueue=\(clearQueue) currentTrack=\(currentTrack?.id.uuidString ?? "nil") operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
            category: .audio
        )
        invalidatePreparation()
        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBufferIfActive()
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
        guard let audioFile = audioFile else {
            return
        }

        let wasPlaying = isPlaying
        Log.info(
            "[AudioDiagnostics] seek target=\(String(format: "%.3f", seconds)) wasPlaying=\(wasPlaying) operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
            category: .audio
        )

        smartController.beginSeek()

        cancelPendingCompletion()
        invalidateScheduleToken()
        playerNode.stop()
        resetDelayBufferIfActive()
        isPlaying = false

        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        let totalFrames = audioFile.length

        guard targetFrame >= 0, targetFrame < totalFrames else {
            print("⚠️ Seek position out of range")
            smartController.endSeek()
            return
        }

        let frameCount = AVAudioFrameCount(totalFrames - targetFrame)

        startingFramePosition = targetFrame
        // We schedule from frame(`seconds`); audio is heard `lookaheadSeconds`
        // later, so the initial displayed (audible) position is offset back by
        // the same amount that `updateProgress` subtracts — no double
        // compensation. With lookahead off this is exactly `seconds`.
        currentTime = max(0, min(seconds - lookaheadSeconds, duration))
        smartController.recordSeek(to: currentTime)

        scheduleSegment(audioFile, startingFrame: targetFrame, frameCount: frameCount)

        if wasPlaying {
            playerNode.play()
            isPlaying = true
            startProgressTimer()
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
        lastProgressUpdateUptime = ProcessInfo.processInfo.systemUptime
        lastProgressAudibleTime = currentTime

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
        let previousUptime = lastProgressUpdateUptime
        let previousAudibleTime = lastProgressAudibleTime
        lastProgressUpdateUptime = nowUptime

        // Drain phase (lookahead only): the player has finished, but the delay
        // buffer is still emptying. Advance the clock from the drain anchors so
        // the UI keeps moving through the tail instead of freezing.
        if let drainStartUptime {
            let elapsed = max(0, nowUptime - drainStartUptime)
            currentTime = min(duration, drainStartTime + elapsed)
            lastProgressAudibleTime = currentTime
            if duration > 0 {
                smartController.updateProgress(currentTime: currentTime, duration: duration)
            }
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

        // Show the position the user actually hears. `lookaheadSeconds` is 0 when
        // the feature is off, so this reduces to the raw player time.
        let audibleTime = newTime - lookaheadSeconds
        currentTime = max(0, min(audibleTime, duration))
        lastProgressAudibleTime = currentTime

        if let previousUptime {
            let timerGap = nowUptime - previousUptime
            let clockDelta = currentTime - previousAudibleTime
            if timerGap >= 0.24 || abs(clockDelta - timerGap) >= 0.18 {
                Log.warning(
                    "[AudioClockGap] timerGapMs=\(String(format: "%.1f", timerGap * 1000)) clockDeltaMs=\(String(format: "%.1f", clockDelta * 1000)) playerNodePlaying=\(playerNode.isPlaying) engineRunning=\(isEngineInitialized ? engine.isRunning : false) operation=\(FirstUseHitchDiagnostics.currentMainOperationDescription() ?? "none")",
                    category: .audio
                )
            }
        }

        // Update smart controller with progress
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }
    }

    // MARK: - Playback Completion

    private func handlePlaybackCompletion(token: UUID) {
        guard token == activeScheduleToken else { return }
        guard isPlaying else { return }

        // With lookahead active, the player finishes ~lookahead seconds before
        // the audio is actually heard. Defer finalize so the buffered tail plays
        // out (no truncated ending / premature track switch). Off → finalize now.
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
            smartController.finishCurrentTrackForStopAfterTrack()
            isPlaying = false
            currentTime = duration
            return
        }

        if repeatMode == .one, currentTrack != nil {
            smartController.replayCurrentTrackAfterCompletion()
            return
        }

        // Auto-advance via smart controller, or stop at queue end.
        if smartController.autoAdvance() == nil {
            isPlaying = false
            currentTime = duration
        }
    }

    // MARK: - File Access

    private func stopAccessingCurrentFile() {
        if let url = currentFileURL {
            if currentFileSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
            currentFileURL = nil
            currentFileSecurityScoped = false
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
