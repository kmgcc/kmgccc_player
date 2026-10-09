//
//  AVAudioPlaybackService.swift
//  myPlayer2
//
//  kmgccc_player - Renderer Playback Service
//  Local audio playback through AVSampleBufferAudioRenderer.
//  Integrated with Smart Shuffle for preference-based random playback.
//

import AVFoundation
import Foundation
import SwiftData
import SwiftUI

/// Local audio playback service using the sample-buffer renderer pipeline.
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

    var isReadyForSeek: Bool {
        audioFile != nil
    }

    var volume: Double {
        didSet {
            rendererPipeline.setVolume(Float(volume))
            scheduleListeningContextUpdate()
            AppSettings.shared.volume = volume
            // Forward the output volume for spectrum diagnostics; analysis PCM
            // remains upstream of renderer master gain.
            AudioVisualizationService.shared.updateVolume(Float(volume * (transportState?.envelopeGain ?? 1)))
        }
    }

    private weak var globalsController: AudioProcessingGlobalsController?
    private var processingGlobals = AudioProcessingGlobals()
    private var listeningContextTask: Task<Void, Never>?
    private var transportState: AudioTransportTransitionState?
    private var pauseTransitionPending = false
    private(set) var currentLoudnessGainDB = 0.0
    private(set) var currentLoudnessSource = "unavailable"
    private(set) var currentLoudnessPeakBasis = "unknown"
    private(set) var currentLoudnessDiagnostics: [DSPDiagnostic] = []
    private var activeNormalizationGain = 1.0
    private var activeDecodedStartFrame: AVAudioFramePosition = 0
    private var activeDecodedFrameCount: AVAudioFrameCount?
    private var prefetchedDecodedRange: (start: AVAudioFramePosition, count: AVAudioFrameCount?)?
    private var albumGainLock: (key: String, decision: LoudnessGainDecision)?
    private var queuedLoudnessDecisions: [UUID: LoudnessGainDecision] = [:]
    var loudnessGainProvider: ((Track, URL, AudioLoudnessConfiguration, Bool) -> LoudnessGainDecision)?

    // MARK: - Renderer Components

    private var audioFile: AVAudioFile?
    private let rendererPipeline = RendererPlaybackPipeline()
    private var spatialCurrentSegmentID: UUID?
    private var pendingRendererStartSegmentID: UUID?
    /// Identity of the explicit load/seek timeline; gapless appends keep it.
    private var rendererLoadSegmentID: UUID?
    private var spatialCurrentLogicalStart: Double = 0
    private var spatialClockTime: Double = 0

    private struct SpatialPendingBoundary {
        let trackID: UUID
        let descriptor: RendererSegmentDescriptor
        let token: UUID
        let duration: Double
    }
    private var spatialPendingBoundary: SpatialPendingBoundary?

    /// A renderer load is asynchronous because decoding is serialized on its
    /// private queue. Keep the latest explicit seek alive until that queue has
    /// committed the new synchronizer anchor; progress callbacks from the old
    /// renderer must not overwrite the target in the meantime.
    private struct SpatialPendingSeek {
        let segmentID: UUID
        let position: Double
        /// The transport intent can change while the renderer is committing
        /// the asynchronous timeline replacement. A paused lyric-row seek is
        /// followed by `resume()` in the same main-actor turn, so this must
        /// remain mutable instead of being frozen to the seek's initial state.
        var wasPlaying: Bool
    }
    private var spatialPendingSeek: SpatialPendingSeek?

    // MARK: - Playback State

    private var sampleRate: Double = 44100
    private var activeTimelineToken = UUID()
    private var completionWorkItem: DispatchWorkItem?
    /// The lookahead state applied to the active renderer timeline.
    private var activeLookaheadEnabled = false
    /// Drain bookkeeping keeps the visible media clock moving through the
    /// renderer's configured presentation lead after the source reaches EOF.
    private var drainStartUptime: TimeInterval?
    private var drainStartTime: Double = 0
    private var lastKnownShuffleEnabled = AppSettings.shared.shuffleEnabled
    private var activePlaybackOrderModeOverride: PlaybackOrderMode?
    private static let fixedAudioOutputDelaySeconds: Double = 0.18
    private static let outputLatencyRefreshInterval: TimeInterval = 0.25
    private var outputLatencySnapshot = AudioOutputLatencySnapshot.zero
    private var lastOutputLatencyRefreshUptime: TimeInterval = 0
    private var routedOutputDeviceUID: String?

    var audioOutputDelay: Double {
        // This value is intentionally limited to the application's own
        // visualization lookahead. Bluetooth/device latency is represented by
        // the AVSampleBufferAudioRenderer's output-device clock and must not be
        // added here, otherwise lyrics and analysis are delayed twice.
        lookaheadSeconds
    }

    /// URL exposed to the system media session. Keeping this tied to the
    /// resolved current resource gives macOS the same asset context that IINA
    /// publishes alongside its AVSampleBufferAudioRenderer output.
    var nowPlayingAssetURL: URL? {
        currentFileURL
    }

    var currentPlaybackOrderMode: PlaybackOrderMode {
        effectivePlaybackOrderMode
    }

    // MARK: - Off-Main Preparation

    /// Off-main file preparation (bookmark resolve + AVAudioFile open). See
    /// `AudioFilePreparationActor`.
    private let prepActor = AudioFilePreparationActor()
    private let authorizedSourceRootsProvider: AuthorizedSourceRootsProvider
    private let libraryPaths: LibraryPaths
    /// Monotonic id for the current play request. Bumped ONLY by
    /// `invalidatePreparation()` (called from `stopPlayback`). A prepared
    /// resource is consumed only if its captured generation still matches —
    /// this discards stale results from a track the user already switched away
    /// from. See `invalidatePreparation()` for why there is a single bump site.
    private var playGeneration: UInt64 = 0
    /// The in-flight preparation task, cancelled when a newer request starts.
    private var prepTask: Task<Void, Never>?

    // MARK: - Paused Restore (Playback Memory)

    /// The `playGeneration` of an armed paused-restore load. The load owning this
    /// exact generation must finish in a paused state. Scoping to a generation (instead of a bare flag)
    /// ensures a superseding normal play request — which bumps the generation —
    /// is never mistaken for the restore. Used to restore the last session at
    /// launch without auto-playing. Consumed in `finishStart`.
    private var restorePausedGeneration: UInt64?
    /// Position (seconds) to load the restored track at while staying paused.
    /// The seek is applied in `finishStart` once the renderer is ready, so
    /// it is deferred (not discarded) until the off-main prepare completes.
    private var pendingRestorePositionSeconds: Double?
    /// Saved position used only when a stopped renderer is retried by resume().
    private var pendingRetryPositionSeconds: Double?

    // MARK: - Gapless Scheduling

    /// Bumped whenever the scheduled queue is invalidated (stop, seek, manual
    /// switch, lookahead/device rebuild, failure). Async prefetch results whose
    /// captured value no longer matches are discarded. Distinct from
    /// `playGeneration`, which guards the *current* track's prepare.
    private var scheduleGeneration: UInt64 = 0
    /// The in-flight gapless prefetch of the upcoming track.
    private var prefetchTask: Task<Void, Never>?
    /// Whether a prefetch has already been attempted for the current committed
    /// item (regardless of outcome). Prevents re-spamming prefetch every progress
    /// tick after a fallback. Reset whenever the committed current item changes.
    private var prefetchAttemptedForCurrentItem = false
    /// Security-scope owner for the prefetched-but-not-yet-current item. This is
    /// the ONLY scope owner besides `currentFileLease` (which owns the committed
    /// current item). Released on discard, or TRANSFERRED into the current-file
    /// bookkeeping at a gapless boundary commit — never double-released.
    private var prefetchedResource: PreparedAudioResource?
    /// Seconds of remaining current-track audio at/under which the next track is
    /// prefetched and gapless-scheduled.
    private static let gaplessPrefetchLeadSeconds: Double = 20

    /// Reasons a natural boundary could not (or chose not to) go gapless. Logged
    /// for field diagnosis.
    private enum GaplessFallbackReason: String {
        case disabled
        case noNext
        case prefetchFailed
        case generationMismatch
        case stopAfterTrack
        case repeatOne
        case predictionMismatch
        case stateChanged
        case notScheduledInTime

        /// Reasons that indicate an unexpected internal state (vs. a normal,
        /// expected fallback like end-of-queue or a superseded prefetch). Only
        /// these are logged unconditionally; the rest are gated behind
        /// `LogConfig.gaplessVerbose`.
        var isUnexpected: Bool {
            switch self {
            case .notScheduledInTime: return true
            default: return false
            }
        }
    }

    /// Gapless is allowed when the user hasn't disabled it. The renderer keeps
    /// adjacent source segments on one continuous presentation timeline.
    private var gaplessEnabled: Bool {
        AppSettings.shared.audioGaplessSchedulingEnabled
    }

    // MARK: - Smart Shuffle Integration

    private let smartController: SmartPlaybackController

    // MARK: - Timer

    private var progressTimer: Timer?

    // MARK: - Current File Access

    private var currentFileURL: URL?
    private var currentFileLease: SecurityScopedResourceLease?

    /// Persists refreshed locators and availability through the active repository.
    var onAudioLocatorResolved: ((UUID, TrackMediaLocator, TrackAvailability) -> Void)?

    init(
        smartController: SmartPlaybackController,
        libraryPaths: LibraryPaths,
        authorizedSourceRootsProvider: AuthorizedSourceRootsProvider = AuthorizedSourceRootsProvider()
    ) {
        self.smartController = smartController
        self.libraryPaths = libraryPaths
        self.authorizedSourceRootsProvider = authorizedSourceRootsProvider
        self.volume = AppSettings.shared.volume
        setupSmartController()
        setupRendererPipeline()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleOutputDevicePreferenceChange),
            name: .audioOutputDevicePreferenceDidChange,
            object: nil
        )
        refreshOutputLatency(force: true)
        Log.info(
            "[PlaybackPipeline] AVAudioPlaybackService init id=\(ObjectIdentifier(self)) output=renderer",
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

    private func setupSmartController() {
        smartController.onPlayTrack = { [weak self] track in
            self?.playInternal(track: track)
        }
        smartController.onTrackChanged = { [weak self] track in
            self?.currentTrack = track
        }
    }

    private func setupRendererPipeline() {
        rendererPipeline.setVolume(Float(volume))
        AudioVisualizationService.shared.updateVolume(Float(volume))
        rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
        rendererPipeline.onProgress = { [weak self] clock in
            guard let self, self.spatialPendingSeek == nil else { return }
            self.spatialClockTime = clock
        }
        rendererPipeline.onTimelineMutationCommitted = { [weak self] segmentID, clock, _ in
            guard let self else { return }
            if self.pendingRendererStartSegmentID == segmentID {
                self.pendingRendererStartSegmentID = nil
            }
            guard let pending = self.spatialPendingSeek,
                  pending.segmentID == segmentID else { return }
            // `load(... autoplay:)` is queued before a possible `resume()`.
            // The renderer can therefore commit with autoplay=false even
            // though the user resumed while that load was in flight. The
            // pending seek owns the final transport intent for this timeline.
            let shouldPlay = pending.wasPlaying
            self.spatialPendingSeek = nil
            self.spatialClockTime = clock
            self.currentTime = pending.position
            self.isPlaying = shouldPlay
            self.smartController.endSeek()
            AudioAnalysisHub.shared.setPlaying(shouldPlay)
            if shouldPlay {
                self.startProgressTimer()
            } else {
                self.stopProgressTimer()
                if self.duration > 0 {
                    self.smartController.updateProgress(
                        currentTime: self.currentTime,
                        duration: self.duration
                    )
                }
            }
            // The coordinator already publishes the target immediately from
            // seek(to:). Republish at the commit boundary so the system media
            // session follows the same one-shot timeline transaction.
            NowPlayingService.shared.syncLocalPlaybackState()
        }
        rendererPipeline.onAnalysisPCM = { pcm in
            // Feed only when the renderer clock reaches the application-owned
            // lookahead delivery point, avoiding the renderer's larger decode
            // pre-roll. The output device's Core Audio clock is selected on the
            // renderer; no route-specific delay estimate belongs in this path.
            AudioAnalysisHub.shared.enqueueRendererPCM(pcm)
        }
        rendererPipeline.onSegmentExhausted = { [weak self] descriptor in
            // The source is fully queued, so give the existing prefetch owner
            // one more opportunity to prepare the next item. Progress-based
            // prefetch remains the normal early path.
            guard let self, descriptor.id == self.spatialCurrentSegmentID else { return }
            self.maybeTriggerGaplessPrefetch()
        }
        rendererPipeline.onSystemReconfigEvent = {
            Log.info(
                "[SpatialAudio] renderer output configuration changed; timeline recovery requested",
                category: .audio
            )
        }
        rendererPipeline.onFailure = { [weak self] segmentID, error in
            guard let self else { return }
            self.handleRendererFailure(segmentID: segmentID, error: error)
        }
    }

    /// The App controller survives library sessions; only the active service
    /// owns its renderer binding. Request IDs reject retired-session events.
    func bindAudioDSP(_ controller: AudioDSPController) {
        rendererPipeline.onDSPApplyEvent = { [weak controller] event in
            Task { @MainActor [weak controller] in controller?.receive(event) }
        }
        controller.bindPlayback { [weak self] configuration, revision, requestID in
            self?.rendererPipeline.applyDSP(configuration, revision: revision, requestID: requestID)
        }
    }

    func bindAudioProcessingGlobals(_ controller: AudioProcessingGlobalsController) {
        globalsController = controller
        rendererPipeline.onTransportStateChange = { [weak self] state, generation in
            Task { @MainActor [weak self] in
                guard let self, self.rendererPipeline.isTimelineCurrent(generation) else { return }
                self.transportState = state
                AudioVisualizationService.shared.updateVolume(Float(self.volume * state.envelopeGain))
                guard self.audioFile != nil else { self.publishProcessingRuntime(); return }
                let wasPlaying = self.isPlaying
                self.isPlaying = state.actualPlaying
                if state.actualPlaying && (!wasPlaying || self.progressTimer == nil) {
                    AudioAnalysisHub.shared.setPlaying(true)
                    self.startProgressTimer()
                } else if !state.actualPlaying && state.phase == "idle" {
                    self.pauseTransitionPending = false
                    AudioAnalysisHub.shared.setPlaying(false)
                    self.stopProgressTimer()
                    NowPlayingService.shared.syncLocalPlaybackState()
                }
                self.publishProcessingRuntime()
            }
        }
        controller.bindPlayback { [weak self] configuration, _, _ in
            guard let self else { return }
            self.processingGlobals = configuration
            self.rendererPipeline.setFadeConfiguration(configuration.fade)
            self.scheduleListeningContextUpdate(immediate: true)
        }
    }

    func unbindAudioProcessingGlobals() {
        globalsController = nil
        listeningContextTask?.cancel()
        rendererPipeline.onTransportStateChange = nil
        loudnessGainProvider = nil
    }

    func togglePlayPause() {
        if isPlaying && !pauseTransitionPending { pause() } else { resume() }
    }

    private func scheduleListeningContextUpdate(immediate: Bool = false) {
        listeningContextTask?.cancel()
        listeningContextTask = Task { @MainActor [weak self] in
            if !immediate { try? await Task.sleep(for: .milliseconds(35)) }
            guard !Task.isCancelled, let self else { return }
            let context = DSPEqualLoudnessContext(
                appGain: self.volume, deviceUID: self.routedOutputDeviceUID,
                referenceDB: self.routedOutputDeviceUID.flatMap { self.processingGlobals.deviceReferences[$0] }
            )
            self.rendererPipeline.setEqualLoudnessContext(context)
            self.publishProcessingRuntime()
        }
    }

    private func publishProcessingRuntime() {
        globalsController?.publishRuntimeState(AudioProcessingRuntimeState(
            transport: transportState, outputDeviceUID: routedOutputDeviceUID,
            appGain: volume, volumeSource: "appOnly",
            referenceDB: routedOutputDeviceUID.flatMap { processingGlobals.deviceReferences[$0] }
        ))
    }

    private func lockLoudnessGain(track: Track, url: URL) -> (gain: Double, decision: LoudnessGainDecision?) {
        guard processingGlobals.loudness.enabled else { return (1, nil) }
        let queue = currentQueueTracks()
        let continuousAlbum = !smartController.isShuffleEnabled && !track.albumGroupKey.isEmpty
            && queue.count > 1 && queue.allSatisfy { $0.albumGroupKey == track.albumGroupKey }
        let albumKey = track.albumGroupKey + ":" + queue.map { $0.id.uuidString }.joined(separator: ",")
        if (processingGlobals.loudness.mode == "album" || (processingGlobals.loudness.mode == "auto" && continuousAlbum)), let locked = albumGainLock, locked.key == albumKey {
            return (pow(10, locked.decision.gainDB / 20), locked.decision)
        }
        guard let decision = loudnessGainProvider?(track, url, processingGlobals.loudness, continuousAlbum) else { return (1, nil) }
        if processingGlobals.loudness.mode == "album" || (processingGlobals.loudness.mode == "auto" && continuousAlbum) {
            albumGainLock = (albumKey, decision)
        } else { albumGainLock = nil }
        return (pow(10, decision.gainDB / 20), decision)
    }

    private func publishLoudnessDecision(_ decision: LoudnessGainDecision?) {
        currentLoudnessGainDB = decision?.gainDB ?? 0
        currentLoudnessSource = decision?.source ?? (processingGlobals.loudness.enabled ? "unavailable" : "disabled")
        currentLoudnessPeakBasis = decision?.peakBasis ?? "unknown"
        currentLoudnessDiagnostics = decision?.diagnostics ?? []
    }

    /// Refresh the active Core Audio output route at the same cadence as the
    /// playback presentation timer. The renderer itself is bound to the
    /// reported device UID so its synchronizer follows the device clock. The
    /// latency fields are retained for diagnostics only; they never become a
    /// presentation offset.
    private func refreshOutputLatency(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastOutputLatencyRefreshUptime >= Self.outputLatencyRefreshInterval else {
            return
        }
        lastOutputLatencyRefreshUptime = now

        let snapshot = AudioOutputLatencyMonitor.currentSnapshot()
        let snapshotChanged = snapshot != outputLatencySnapshot
        let selectedOutputUID = AppSettings.shared.audioOutputDeviceUID ?? snapshot.deviceUID
        let outputDeviceChanged = selectedOutputUID != routedOutputDeviceUID
        outputLatencySnapshot = snapshot
        routedOutputDeviceUID = selectedOutputUID
        if snapshotChanged {
            Log.info(
                "[AudioClock] output=\(snapshot.deviceName) uid=\(snapshot.deviceUID ?? "default") transport=\(snapshot.transportType) deviceFrames=\(snapshot.deviceLatencyFrames) streamFrames=\(snapshot.streamLatencyFrames) reportedSeconds=\(String(format: "%.4f", snapshot.seconds)) presentationOffset=0",
                category: .audio
            )
        }
        if outputDeviceChanged {
            rendererPipeline.setAudioOutputDeviceUniqueID(selectedOutputUID)
            pauseTransitionPending = false
            scheduleListeningContextUpdate(immediate: true)
        }
    }

    @objc nonisolated private func handleOutputDevicePreferenceChange(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.refreshOutputLatency(force: true)
        }
    }

    // MARK: - Renderer Lookahead

    /// Whether the configured visualization lookahead is enabled for the next
    /// renderer timeline. The debug bypass preserves the existing user setting.
    private var desiredLookaheadEnabled: Bool {
        AppSettings.shared.audioLookaheadEnabled && !AppSettings.shared.audioDebugBypassDelayNode
    }

    /// Renderer PTS lead for the app-owned visualization delay. Device latency
    /// remains represented by the renderer's output clock.
    private var lookaheadSeconds: Double {
        activeLookaheadEnabled ? Self.fixedAudioOutputDelaySeconds : 0
    }

    private func applyLookaheadPreferenceChangeIfNeeded(reason: String) {
        let desired = desiredLookaheadEnabled
        guard desired != activeLookaheadEnabled else { return }

        Log.info(
            "[PlaybackPipeline] audio lookahead preference change reason=\(reason) desired=\(desired) wasPlaying=\(isPlaying) currentTime=\(String(format: "%.3f", currentTime))",
            category: .audio
        )

        let wasPlaying = isPlaying && !pauseTransitionPending
        let resumeTime = currentTime
        cancelPendingCompletion()
        invalidateScheduleToken()
        guard let file = audioFile else {
            return
        }

        let targetFrame = AVAudioFramePosition(resumeTime * sampleRate)
        guard targetFrame >= 0, targetFrame < file.length else {
            Log.warning("[PlaybackPipeline] cannot reschedule after lookahead change: invalid frame=\(targetFrame) total=\(file.length)", category: .audio)
            return
        }

        activeLookaheadEnabled = desired
        currentTime = max(0, min(resumeTime, duration))
        let provider = AVFilePCMProvider(file: file, startingFrame: activeDecodedStartFrame, frameCount: activeDecodedFrameCount)
        let segmentID = UUID()
        spatialCurrentSegmentID = segmentID
        rendererLoadSegmentID = segmentID
        pendingRendererStartSegmentID = nil
        spatialCurrentLogicalStart = 0
        spatialClockTime = resumeTime
        spatialPendingBoundary = nil
        spatialPendingSeek = SpatialPendingSeek(
            segmentID: segmentID,
            position: currentTime,
            wasPlaying: wasPlaying
        )
        rendererPipeline.setAnalysisLeadSeconds(lookaheadSeconds)
        refreshOutputLatency(force: true)
        rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
        AudioAnalysisHub.shared.enableRendererFeed()
        AudioAnalysisHub.shared.setPlaying(false)
        stopProgressTimer()
        rendererPipeline.load(
            source: provider,
            sourcePosition: targetFrame,
            presentationStartSeconds: lookaheadSeconds,
            clockTimeSeconds: resumeTime,
            segmentID: segmentID,
            autoplay: wasPlaying,
            normalizationGain: activeNormalizationGain
        )
    }

    private func cancelPendingCompletion() {
        completionWorkItem?.cancel()
        completionWorkItem = nil
        drainStartUptime = nil
    }

    // MARK: - Scheduling Helpers

    private func invalidateScheduleToken() {
        activeTimelineToken = UUID()
        _ = resetGaplessSchedulingState(reason: "invalidateScheduleToken")
    }

    /// Invalidate the renderer's pending gapless source and release its scope
    /// after the pipeline has discarded that source. Does not touch the current
    /// file's scope.
    private func resetGaplessSchedulingState(
        reason: String,
        discardPendingRendererSegment: Bool = true
    ) -> PreparedAudioResource? {
        scheduleGeneration &+= 1
        prefetchTask?.cancel()
        prefetchTask = nil
        prefetchAttemptedForCurrentItem = false
        let discardedResource = prefetchedResource
        prefetchedResource = nil
        if let discardedResource {
            gaplessLog("[Gapless] detached prefetched resource track=\(discardedResource.trackID.uuidString.prefix(8)) reason=\(reason)")
            if discardPendingRendererSegment,
               let currentSegmentID = spatialCurrentSegmentID {
                rendererPipeline.discardSegments(after: currentSegmentID) {
                    discardedResource.lease.release()
                }
            } else if discardPendingRendererSegment {
                discardedResource.lease.release()
            }
        }
        if let id = spatialPendingBoundary?.descriptor.id { queuedLoudnessDecisions.removeValue(forKey: id) }
        spatialPendingBoundary = nil
        prefetchedDecodedRange = nil
        return discardPendingRendererSegment ? nil : discardedResource
    }

    /// Release the prefetched item's security scope, if any. The single release
    /// path for `prefetchedResource` when it is discarded (not promoted).
    private func releasePrefetchedResource(reason: String) {
        guard let resource = prefetchedResource else { return }
        prefetchedResource = nil
        gaplessLog("[Gapless] released prefetched resource track=\(resource.trackID.uuidString.prefix(8)) lease=owned reason=\(reason)")
        guard let currentSegmentID = spatialCurrentSegmentID else {
            releaseSecurityScope(for: resource)
            return
        }
        rendererPipeline.discardSegments(after: currentSegmentID) {
            resource.lease.release()
        }
    }

    private func logGaplessFallback(_ reason: GaplessFallbackReason, context: String) {
        // Unexpected internal state is always surfaced (warning). Normal,
        // expected fallbacks (end-of-queue or superseded prefetch) are routine
        // diagnostics gated behind gaplessVerbose.
        if reason.isUnexpected {
            Log.warning("[Gapless] fallback reason=\(reason.rawValue) \(context)", category: .audio)
        } else {
            gaplessLog("[Gapless] fallback reason=\(reason.rawValue) \(context)")
        }
    }

    /// Routine gapless diagnostics. No-op unless `LogConfig.gaplessVerbose` is on,
    /// so normal Debug runs stay quiet; the `@autoclosure` keeps the string from
    /// being built when disabled. Use for expected prefetch/schedule/boundary/AAC
    /// trace; use `Log.warning`/`Log.error` directly for genuine problems.
    private func gaplessLog(_ message: @autoclosure () -> String) {
        if LogConfig.gaplessVerbose {
            Log.info(message(), category: .audio)
        }
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

    // MARK: - Playback Control

    func play(track: Track) {
        Log.debug("play(track:) called for: \(track.title)", category: .audio)
        let mode = applyPlaybackStartPolicy(.useSavedMode)
        smartController.startPlayback(tracks: [track], startingAt: 0, shuffle: mode == .shuffle)
    }

    func playTracks(_ tracks: [Track], startingAt index: Int, startPolicy: PlaybackStartPolicy) {
        guard index >= 0, index < tracks.count else { return }
        let mode = applyPlaybackStartPolicy(startPolicy)

        // Pass to smart controller
        smartController.startPlayback(tracks: tracks, startingAt: index, shuffle: mode == .shuffle)
    }

    /// Restore a saved session into a paused state: rebuilds the queue and loads
    /// the current track at `positionSeconds`. The user must press play to begin from the
    /// restored position. This is the playback-memory restore path; it deliberately
    /// does not auto-play (the launch auto-play chain stays disabled).
    func restorePausedPlayback(_ tracks: [Track], startingAt index: Int, positionSeconds: Double) {
        guard index >= 0, index < tracks.count else { return }
        let mode = applyPlaybackStartPolicy(.useSavedMode)

        Log.info(
            "[PlaybackPipeline] restorePausedPlayback queueCount=\(tracks.count) startIndex=\(index) position=\(String(format: "%.1f", positionSeconds)) mode=\(mode.rawValue)",
            category: .audio
        )

        // startPlayback runs synchronously through playInternal (which calls
        // stopPlayback → clears the restore arm, bumps playGeneration, creates
        // the prep task), so once it returns, playGeneration identifies exactly
        // this load. Arm the restore intent AFTER it returns — arming before
        // would be wiped by stopPlayback. finishStart consumes these.
        smartController.startPlayback(tracks: tracks, startingAt: index, shuffle: mode == .shuffle)
        restorePausedGeneration = playGeneration
        pendingRestorePositionSeconds = max(0, positionSeconds)
    }

    private func applyPlaybackStartPolicy(_ policy: PlaybackStartPolicy) -> PlaybackOrderMode {
        let mode = policy.resolvedMode()
        activePlaybackOrderModeOverride = policy.isTemporaryOverride ? mode : nil
        lastKnownShuffleEnabled = AppSettings.shared.shuffleEnabled
        return mode
    }

    private var effectivePlaybackOrderMode: PlaybackOrderMode {
        activePlaybackOrderModeOverride ?? AppSettings.shared.playbackOrderMode
    }

    func makePrepRequest(for track: Track) -> AudioPrepRequest {
        let root = track.libraryRootSnapshot.isEmpty
            ? libraryPaths.rootURL
            : URL(fileURLWithPath: track.libraryRootSnapshot, isDirectory: true)
        return AudioPrepRequest(
            trackID: track.id,
            locator: track.mediaLocator,
            libraryPaths: LibraryPaths(rootURL: root),
            authorizedSourceRoots: authorizedSourceRootsProvider.snapshot(),
            titleForLog: track.title
        )
    }

    private func playInternal(track: Track) {
        Log.info(
            "[PlaybackPipeline] load item requested track=\(track.id.uuidString) title=\(track.title)",
            category: .audio
        )

        let isRestoringPaused = (restorePausedGeneration != nil)
        let shouldKeepPlaying = isPlaying || !isRestoringPaused

        // Stop current audio immediately (matches "switch track = stop now").
        // stopPlayback runs invalidatePreparation() — bumping playGeneration and
        // cancelling any in-flight prepare — and clears currentTrack/audioFile +
        // releases the old file's security scope.
        stopPlayback(clearQueue: false, keepPlayingState: shouldKeepPlaying)

        if shouldKeepPlaying {
            isPlaying = true
        }

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
        pendingRetryPositionSeconds = nil

        // Cheap MainActor snapshot of the @Model fields the actor needs. Only
        // this Sendable value crosses into the actor — never the Track itself.
        let request = makePrepRequest(for: track)

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
        prepTask = nil
        let restorePaused = (restorePausedGeneration == generation)
        finishStart(resource, track: track, restorePaused: restorePaused)
    }

    /// Release a prepared resource's security scope, but only if it actually
    /// started one (library-relative paths never do).
    private func releaseSecurityScope(for resource: PreparedAudioResource) {
        resource.lease.release()
    }

    /// Install a prepared source into the renderer's continuous timeline.
    private func finishStart(_ resource: PreparedAudioResource, track: Track, restorePaused: Bool) {
        let scheduleToken = FirstUseHitchDiagnostics.begin(
            "Renderer.load",
            detail: "track=\(resource.trackID.uuidString.prefix(8))"
        )
        defer { FirstUseHitchDiagnostics.end(scheduleToken) }

        currentFileURL = resource.resolvedURL
        currentFileLease = resource.lease
        audioFile = resource.file
        sampleRate = resource.sampleRate
        duration = resource.duration
        currentTime = 0

        track.availability = resource.newAvailability
        if let refreshed = resource.refreshedLocator {
            track.mediaLocator = refreshed
            onAudioLocatorResolved?(track.id, refreshed, resource.newAvailability)
        }

        startSpatialRenderer(
            resource: resource,
            track: track,
            restorePaused: restorePaused
        )
    }

    private func startSpatialRenderer(
        resource: PreparedAudioResource,
        track: Track,
        restorePaused: Bool
    ) {
        let requestedPosition: Double
        if restorePaused {
            requestedPosition = pendingRestorePositionSeconds ?? 0
        } else {
            requestedPosition = pendingRetryPositionSeconds ?? 0
        }
        restorePausedGeneration = nil
        pendingRestorePositionSeconds = nil
        pendingRetryPositionSeconds = nil

        let shouldAutoplay = !restorePaused && isPlaying && !pauseTransitionPending
        let trim = resolveAACTrim(resource)
        activeDecodedStartFrame = trim?.headTrimFrames ?? 0
        activeDecodedFrameCount = trim?.scheduledFrameCount
        if let trim { duration = trim.scheduledDuration }
        let upperBound = duration > 0.5 ? duration - 0.5 : 0
        let position = max(0, min(requestedPosition, upperBound))
        let frame = AVAudioFramePosition(position * sampleRate)
        let provider = AVFilePCMProvider(file: resource.file, startingFrame: activeDecodedStartFrame, frameCount: activeDecodedFrameCount)
        let loudness = lockLoudnessGain(track: track, url: resource.resolvedURL)
        activeNormalizationGain = loudness.gain
        publishLoudnessDecision(loudness.decision)
        pauseTransitionPending = false
        let segmentID = UUID()

        activeLookaheadEnabled = desiredLookaheadEnabled
        spatialCurrentSegmentID = segmentID
        rendererLoadSegmentID = segmentID
        pendingRendererStartSegmentID = segmentID
        spatialCurrentLogicalStart = 0
        spatialClockTime = position
        spatialPendingSeek = nil
        spatialPendingBoundary = nil
        currentTime = position
        activeTimelineToken = UUID()

        refreshOutputLatency(force: true)
        AudioAnalysisHub.shared.enableRendererFeed()
        AudioAnalysisHub.shared.setPlaying(shouldAutoplay)
        rendererPipeline.setVolume(Float(volume))
        rendererPipeline.setAnalysisLeadSeconds(lookaheadSeconds)
        rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
        rendererPipeline.load(
            source: provider,
            sourcePosition: frame,
            // The descriptor anchor represents source time zero; the
            // pipeline adds `sourcePosition` to the first buffer PTS.
            presentationStartSeconds: lookaheadSeconds,
            clockTimeSeconds: position,
            segmentID: segmentID,
            autoplay: shouldAutoplay,
            normalizationGain: activeNormalizationGain,
            fadeOnStart: true
        )

        isPlaying = shouldAutoplay
        if isPlaying {
            startProgressTimer()
        } else if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }

        // The preparation path can update Now Playing while the player is
        // still paused. Re-publish after the renderer actually starts so
        // macOS sees an active local media session before deciding which
        // AirPods spatial modes to offer.
        NowPlayingService.shared.syncLocalPlaybackState()

        Log.info(
            "[RendererAudio] loaded track=\(track.id.uuidString) position=\(String(format: "%.3f", position))s duration=\(String(format: "%.1f", duration))s outputDelay=\(String(format: "%.3f", audioOutputDelay))s autoplay=\(shouldAutoplay)",
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
        prepTask = nil

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
        pendingRetryPositionSeconds = nil
        isPlaying = false
    }

    /// A terminal renderer failure stops this request without advancing the
    /// playback queue. Keep its identity and position so resume() can prepare
    /// the same track again from the saved time.
    private func handleRendererFailure(segmentID: UUID?, error: RendererPipelineError) {
        let isCurrentFailure: Bool
        if let segmentID {
            isCurrentFailure = segmentID == spatialCurrentSegmentID
                || segmentID == spatialPendingBoundary?.descriptor.id
                || segmentID == spatialPendingSeek?.segmentID
                || segmentID == pendingRendererStartSegmentID
        } else {
            isCurrentFailure = pendingRendererStartSegmentID != nil
        }
        guard isCurrentFailure else {
            Log.info(
                "[RendererAudio] discarded stale failure segment=\(segmentID?.uuidString ?? "unassociated") current=\(spatialCurrentSegmentID?.uuidString ?? "nil")",
                category: .audio
            )
            return
        }

        let currentLeaseToRelease = currentFileLease
        let prefetchedLeaseToRelease = prefetchedResource?.lease
        currentFileLease = nil
        prefetchedResource = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        scheduleGeneration &+= 1
        prefetchAttemptedForCurrentItem = false

        cancelPendingCompletion()
        activeTimelineToken = UUID()
        pendingRendererStartSegmentID = nil
        rendererLoadSegmentID = nil
        spatialCurrentSegmentID = nil
        spatialPendingBoundary = nil
        spatialPendingSeek = nil
        currentFileURL = nil
        smartController.endSeek()
        stopProgressTimer()
        isPlaying = false
        currentTime = max(0, min(currentTime, duration))
        audioFile = nil
        AudioAnalysisHub.shared.setPlaying(false)
        AudioAnalysisHub.shared.disableRendererFeed()

        Log.error(
            "[RendererAudio] stopped track=\(currentTrack?.id.uuidString ?? "nil") position=\(String(format: "%.3f", currentTime))s segment=\(segmentID?.uuidString ?? "unassociated") error=\(error)",
            category: .audio
        )
        rendererPipeline.stop {
            currentLeaseToRelease?.release()
            prefetchedLeaseToRelease?.release()
        }
        NowPlayingService.shared.syncLocalPlaybackState()
    }

    func pause() {
        guard isPlaying, !pauseTransitionPending else { return }
        pauseTransitionPending = true

        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] pause currentTime=\(String(format: "%.3f", currentTime)) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }
        cancelPendingCompletion()
        if spatialPendingSeek != nil {
            spatialPendingSeek = nil
            smartController.endSeek()
        }
        rendererPipeline.pause()
    }

    func resume() {
        guard let currentTrack else { return }
        if audioFile == nil {
            if prepTask != nil {
                if restorePausedGeneration == playGeneration {
                    pendingRetryPositionSeconds = pendingRestorePositionSeconds
                    pendingRestorePositionSeconds = nil
                    restorePausedGeneration = nil
                }
                isPlaying = true
            } else if !isPlaying {
                retryCurrentTrackAtSavedPosition(currentTrack)
            }
            return
        }
        guard !isPlaying || pauseTransitionPending else { return }
        pauseTransitionPending = false

        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] resume currentTime=\(String(format: "%.3f", currentTime)) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }
        applyLookaheadPreferenceChangeIfNeeded(reason: "resume")
        // A lyric-row tap can seek while paused and resume before the
        // asynchronous timeline load commits. Preserve that latest intent.
        if var pendingSeek = spatialPendingSeek {
            pendingSeek.wasPlaying = true
            spatialPendingSeek = pendingSeek
        }
        refreshOutputLatency(force: true)
        rendererPipeline.play()
        AudioAnalysisHub.shared.setPlaying(true)
        isPlaying = true
        startProgressTimer()
    }

    private func retryCurrentTrackAtSavedPosition(_ track: Track) {
        let position = max(0, min(currentTime, duration))
        pendingRetryPositionSeconds = position
        isPlaying = true
        invalidatePreparation()
        let generation = playGeneration
        let request = makePrepRequest(for: track)
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

    func stop() {
        stopPlayback(clearQueue: true, keepPlayingState: false)
    }

    private func stopPlayback(clearQueue: Bool, keepPlayingState: Bool = false) {
        Log.info(
            "[PlaybackPipeline] stopPlayback clearQueue=\(clearQueue) keepPlaying=\(keepPlayingState) currentTrack=\(currentTrack?.id.uuidString ?? "nil") operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
            category: .audio
        )
        // Drop any armed paused-restore intent: a new load is taking over.
        // restorePausedPlayback re-arms this *after* startPlayback returns, so
        // clearing here only discards stale intent from a superseded load.
        restorePausedGeneration = nil
        pendingRestorePositionSeconds = nil
        pendingRetryPositionSeconds = nil

        invalidatePreparation()
        cancelPendingCompletion()
        pauseTransitionPending = false
        queuedLoudnessDecisions.removeAll()
        if clearQueue { albumGainLock = nil }
        activeTimelineToken = UUID()
        let prefetchedToRelease = resetGaplessSchedulingState(
            reason: "stopPlayback",
            discardPendingRendererSegment: false
        )
        pendingRendererStartSegmentID = nil
        rendererLoadSegmentID = nil
        spatialCurrentSegmentID = nil
        spatialCurrentLogicalStart = 0
        spatialClockTime = 0
        spatialPendingSeek = nil
        smartController.endSeek()
        AudioAnalysisHub.shared.setPlaying(false)
        AudioAnalysisHub.shared.disableRendererFeed()
        stopProgressTimer()
        let currentLeaseToRelease = currentFileLease
        currentFileLease = nil
        currentFileURL = nil
        audioFile = nil
        activeDecodedStartFrame = 0
        activeDecodedFrameCount = nil
        prefetchedDecodedRange = nil
        activeNormalizationGain = 1
        publishLoudnessDecision(nil)
        rendererPipeline.stop {
            currentLeaseToRelease?.release()
            prefetchedToRelease?.lease.release()
        }

        if !keepPlayingState {
            isPlaying = false
        }
        currentTime = 0
        duration = 0
        currentTrack = nil

        if clearQueue {
            smartController.stop()
        }
    }

    func seek(to seconds: Double) {
        guard let audioFile = audioFile else {
            guard currentTrack != nil else { return }
            let position = max(0, min(seconds, duration))
            if restorePausedGeneration == playGeneration {
                pendingRestorePositionSeconds = position
            } else {
                pendingRetryPositionSeconds = position
            }
            currentTime = position
            smartController.beginSeek()
            smartController.recordSeek(to: position)
            smartController.endSeek()
            return
        }

        let wasPlaying = isPlaying && !pauseTransitionPending
        if LogConfig.audioVerbose {
            Log.info(
                "[AudioDiagnostics] seek target=\(String(format: "%.3f", seconds)) wasPlaying=\(wasPlaying) operation=\(FirstUseHitchDiagnostics.currentOperationStack())",
                category: .audio
            )
        }

        smartController.beginSeek()

        seekSpatialRenderer(to: seconds, file: audioFile, wasPlaying: wasPlaying)
    }

    private func seekSpatialRenderer(
        to seconds: Double,
        file: AVAudioFile,
        wasPlaying: Bool
    ) {
        cancelPendingCompletion()
        invalidateScheduleToken()
        let targetFrame = AVAudioFramePosition(seconds * sampleRate)
        guard targetFrame >= 0, targetFrame < file.length else {
            Log.warning("[SpatialAudio] seek target out of range frame=\(targetFrame)", category: .audio)
            smartController.endSeek()
            return
        }

        let position = max(0, min(seconds, duration))
        let provider = AVFilePCMProvider(file: file, startingFrame: activeDecodedStartFrame, frameCount: activeDecodedFrameCount)
        let segmentID = UUID()
        spatialCurrentSegmentID = segmentID
        rendererLoadSegmentID = segmentID
        pendingRendererStartSegmentID = nil
        spatialCurrentLogicalStart = 0
        spatialClockTime = position
        spatialPendingSeek = SpatialPendingSeek(
            segmentID: segmentID,
            position: position,
            wasPlaying: wasPlaying
        )
        spatialPendingBoundary = nil
        currentTime = position
        smartController.recordSeek(to: currentTime)

        refreshOutputLatency(force: true)
        rendererPipeline.setAnalysisLeadSeconds(lookaheadSeconds)
        rendererPipeline.setAnalysisDeliveryLeadSeconds(lookaheadSeconds)
        // Drop the old analysis window and stop its processing timer before the
        // asynchronous renderer load can begin. The commit callback above
        // restarts it only after the new timeline wins.
        AudioAnalysisHub.shared.enableRendererFeed()
        AudioAnalysisHub.shared.setPlaying(false)
        stopProgressTimer()
        rendererPipeline.load(
            source: provider,
            sourcePosition: targetFrame,
            // The descriptor anchor represents source time zero; the
            // pipeline adds `sourcePosition` to the first buffer PTS.
            presentationStartSeconds: lookaheadSeconds,
            clockTimeSeconds: position,
            segmentID: segmentID,
            autoplay: wasPlaying,
            normalizationGain: activeNormalizationGain
        )
        isPlaying = wasPlaying
    }

    // MARK: - Queue Management

    func updateQueueTracks(_ tracks: [Track]) {
        smartController.updateQueue(tracks: tracks, preservePosition: true)
    }

    @discardableResult
    func insertTracksAfterCurrent(_ tracks: [Track]) -> Int {
        smartController.insertTracksAfterCurrent(tracks)
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
        guard activePlaybackOrderModeOverride == nil else { return }
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
        applyLookaheadPreferenceChangeIfNeeded(reason: "progressTick")
        refreshOutputLatency()

        if let drainStartUptime {
            let elapsed = max(0, ProcessInfo.processInfo.systemUptime - drainStartUptime)
            currentTime = min(duration, drainStartTime + elapsed)
            if duration > 0 {
                smartController.updateProgress(currentTime: currentTime, duration: duration)
            }
            return
        }

        updateSpatialRendererProgress()
    }

    private func updateSpatialRendererProgress() {
        guard isPlaying, spatialPendingSeek == nil else { return }

        let mediaTime = spatialClockTime - spatialCurrentLogicalStart
        currentTime = max(0, min(mediaTime, duration))
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }

        maybeTriggerGaplessPrefetch()

        guard duration > 0, mediaTime >= duration - 0.02 else { return }
        if let pending = spatialPendingBoundary {
            if let reason = spatialGaplessBoundaryBlockReason(pending: pending) {
                logGaplessFallback(
                    reason,
                    context: "renderer boundary track=\(pending.descriptor.id.uuidString.prefix(8))"
                )
                abandonSpatialGaplessAndFinalize()
            } else {
                commitSpatialGaplessBoundary(pending)
            }
            return
        }

        let token = activeTimelineToken
        // The progress observer intentionally accepts a 20 ms boundary
        // tolerance. Include any not-yet-reached media tail in the drain so a
        // tick just before `duration` can never pause the renderer early.
        let drainDelay = lookaheadSeconds + max(0, duration - mediaTime)
        if drainDelay > 0 {
            beginDrain(delaySeconds: drainDelay, token: token)
        } else {
            finalizePlaybackCompletion(token: token)
        }
    }

    // MARK: - Gapless Prefetch

    /// Decide whether to prefetch the upcoming track for a seamless join. Called
    /// every progress tick; the guards make it fire at most once per current item.
    private func maybeTriggerGaplessPrefetch() {
        guard gaplessEnabled else { return }
        guard isPlaying else { return }
        guard !prefetchAttemptedForCurrentItem, prefetchTask == nil else { return }
        guard spatialPendingBoundary == nil else { return }
        guard duration > 0 else { return }

        // Next track must be deterministic. Repeat-one and stop-after-track do not
        // advance to a different track, so never prefetch in those modes.
        let playbackOrderMode = effectivePlaybackOrderMode
        if playbackOrderMode == .stopAfterTrack { return }
        if playbackOrderMode == .repeatOne { return }

        let remaining = duration - currentTime
        guard remaining <= Self.gaplessPrefetchLeadSeconds else { return }

        triggerGaplessPrefetch()
    }

    private func triggerGaplessPrefetch() {
        prefetchAttemptedForCurrentItem = true

        guard let nextTrack = smartController.peekNextForGapless() else {
            logGaplessFallback(.noNext, context: "prefetch")
            return
        }

        let generation = scheduleGeneration
        let request = makePrepRequest(for: nextTrack)

        gaplessLog("[Gapless] prefetch started track=\(nextTrack.id.uuidString.prefix(8)) title=\(nextTrack.title) generation=\(generation)")

        // Task {} (not detached) inherits this @MainActor context: the heavy work
        // runs off-main inside the actor, then resumes on main. Captures only
        // Sendable values + self (never the Track).
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resource = try await self.prepActor.prepare(request)
                self.finishPrefetchIfCurrent(resource, generation: generation)
            } catch {
                self.handlePrefetchFailure(error, trackID: request.trackID, generation: generation)
            }
        }
    }

    /// MainActor: a prefetch finished preparing. Validate it is still wanted,
    /// then append it to the renderer's active timeline.
    private func finishPrefetchIfCurrent(_ resource: PreparedAudioResource, generation: UInt64) {
        guard generation == scheduleGeneration else {
            logGaplessFallback(.generationMismatch, context: "prepared track=\(resource.trackID.uuidString.prefix(8))")
            releaseSecurityScope(for: resource)
            return
        }
        prefetchTask = nil
        guard gaplessEnabled, isPlaying, spatialPendingBoundary == nil else {
            logGaplessFallback(.stateChanged, context: "prepared track=\(resource.trackID.uuidString.prefix(8))")
            releaseSecurityScope(for: resource)
            return
        }
        gaplessLog("[Gapless] prefetch prepared track=\(resource.trackID.uuidString.prefix(8)) duration=\(String(format: "%.1f", resource.duration)) generation=\(generation)")
        scheduleNextSpatial(resource)
    }

    // MARK: - AAC Gapless Trim (Phase 1.2)

    /// One resolved AAC trim: frames to skip at the head (encoder priming) and
    /// drop at the tail (encoder padding), plus the resulting scheduled segment.
    private struct AACTrimDecision {
        let headTrimFrames: AVAudioFramePosition
        let tailTrimFrames: AVAudioFramePosition
        let scheduledFrameCount: AVAudioFrameCount
        let scheduledDuration: Double
    }

    /// Initial playback and gapless continuation use the same decoded AAC crop
    /// as offline loudness. Reloads retain the range selected for this segment.
    private func resolveAACTrim(_ resource: PreparedAudioResource) -> AACTrimDecision? {
        let range = AACDecodedFrameRange.resolve(
            metadata: resource.aacGaplessInfo, decodedFrames: Int64(resource.frameLength),
            enabled: AppSettings.shared.audioAACGaplessTrimEnabled
        )
        guard range.isTrimmed else {
            if range.reason != "fullFile" {
                Log.warning("[AACGapless] skipped reason=\(range.reason) track=\(resource.trackID.uuidString.prefix(8))", category: .audio)
            }
            return nil
        }
        let tail = Int64(resource.frameLength) - range.startingFrame - range.frameCount
        gaplessLog("[AACGapless] applying headTrimFrames=\(range.startingFrame) tailTrimFrames=\(tail) track=\(resource.trackID.uuidString.prefix(8))")
        return AACTrimDecision(headTrimFrames: range.startingFrame, tailTrimFrames: tail,
            scheduledFrameCount: AVAudioFrameCount(range.frameCount),
            scheduledDuration: Double(range.frameCount) / resource.sampleRate)
    }

    /// MainActor: append the prepared next source to the renderer timeline.
    private func scheduleNextSpatial(_ resource: PreparedAudioResource) {
        let trim = resolveAACTrim(resource)
        let startFrame = trim?.headTrimFrames ?? 0
        let frameCount = trim?.scheduledFrameCount
        let itemDuration = trim?.scheduledDuration
            ?? (resource.sampleRate > 0 ? Double(resource.file.length) / resource.sampleRate : resource.duration)
        let provider = AVFilePCMProvider(
            file: resource.file,
            startingFrame: startFrame,
            frameCount: frameCount
        )

        let nextTrack = currentQueueTracks().first { $0.id == resource.trackID }
        let loudness = nextTrack.map { lockLoudnessGain(track: $0, url: resource.resolvedURL) }
        guard let loadSegmentID = rendererLoadSegmentID,
              let descriptor = rendererPipeline.append(
                source: provider,
                expectedLoadSegmentID: loadSegmentID,
                normalizationGain: loudness?.gain ?? 1
              ) else {
            logGaplessFallback(
                .notScheduledInTime,
                context: "renderer append failed track=\(resource.trackID.uuidString.prefix(8))"
            )
            releaseSecurityScope(for: resource)
            return
        }

        if let decision = loudness?.decision { queuedLoudnessDecisions[descriptor.id] = decision }
        let token = UUID()
        prefetchedResource = resource
        prefetchedDecodedRange = (startFrame, frameCount)
        spatialPendingBoundary = SpatialPendingBoundary(
            trackID: resource.trackID,
            descriptor: descriptor,
            token: token,
            duration: itemDuration
        )
        gaplessLog(
            "[SpatialGapless] queued next track=\(resource.trackID.uuidString.prefix(8)) ptsStart=\(String(format: "%.6f", descriptor.presentationStartSeconds)) duration=\(String(format: "%.3f", itemDuration)) headTrim=\(startFrame)"
        )
    }

    private func handlePrefetchFailure(_ error: Error, trackID: UUID, generation: UInt64) {
        guard generation == scheduleGeneration else { return }
        prefetchTask = nil
        if error is CancellationError { return }
        if case AudioFilePreparationActor.PrepError.cancelled = error { return }
        logGaplessFallback(.prefetchFailed, context: "track=\(trackID.uuidString.prefix(8)) error=\(error)")
        // A failed prepare never returns a resource, so there is no scope to free.
    }

    // MARK: - Playback Completion

    private func beginDrain(delaySeconds: Double, token: UUID) {
        cancelPendingCompletion()
        drainStartUptime = ProcessInfo.processInfo.systemUptime
        drainStartTime = duration
        currentTime = drainStartTime

        let work = DispatchWorkItem { [weak self] in
            self?.finalizePlaybackCompletion(token: token)
        }
        completionWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delaySeconds),
            execute: work
        )
    }

    private func finalizePlaybackCompletion(token: UUID) {
        guard token == activeTimelineToken else { return }
        cancelPendingCompletion()
        stopProgressTimer()

        Log.info("[PlaybackPipeline] Playback completed: \(currentTrack?.title ?? "unknown")", category: .audio)

        rendererPipeline.pause()
        AudioAnalysisHub.shared.setPlaying(false)

        let playbackOrderMode = effectivePlaybackOrderMode

        if playbackOrderMode == .stopAfterTrack {
            smartController.finishCurrentTrackForStopAfterTrack()
            isPlaying = false
            currentTime = duration
            return
        }

        if playbackOrderMode == .repeatOne, currentTrack != nil {
            smartController.replayCurrentTrackAfterCompletion()
            return
        }

        // Auto-advance via smart controller, or stop at queue end.
        if smartController.autoAdvance() == nil {
            isPlaying = false
            currentTime = duration
        }
    }

    // MARK: - Gapless Boundary

    private func spatialGaplessBoundaryBlockReason(
        pending: SpatialPendingBoundary
    ) -> GaplessFallbackReason? {
        if !AppSettings.shared.audioGaplessSchedulingEnabled { return .disabled }
        let playbackOrderMode = effectivePlaybackOrderMode
        if playbackOrderMode == .stopAfterTrack { return .stopAfterTrack }
        if playbackOrderMode == .repeatOne { return .repeatOne }
        guard let predicted = smartController.peekNextForGapless() else { return .noNext }
        guard predicted.id == pending.trackID else { return .predictionMismatch }
        return nil
    }

    private func commitSpatialGaplessBoundary(_ pending: SpatialPendingBoundary) {
        guard let resource = prefetchedResource,
              resource.trackID == pending.trackID else {
            logGaplessFallback(
                .notScheduledInTime,
                context: "renderer boundary missing prefetched resource"
            )
            abandonSpatialGaplessAndFinalize()
            return
        }

        // The logical/UI boundary intentionally leads the audible renderer PTS
        // by the configured delay. Keep the outgoing lease alive through that
        // tail so automatic renderer recovery can still re-read it.
        let outgoingLease = currentFileLease
        let outgoingSegmentID = spatialCurrentSegmentID
        prefetchedResource = nil
        currentFileURL = resource.resolvedURL
        currentFileLease = resource.lease
        audioFile = resource.file
        activeDecodedStartFrame = prefetchedDecodedRange?.start ?? 0
        activeDecodedFrameCount = prefetchedDecodedRange?.count
        prefetchedDecodedRange = nil
        sampleRate = resource.sampleRate
        duration = pending.duration
        spatialCurrentSegmentID = pending.descriptor.id
        let decision = queuedLoudnessDecisions.removeValue(forKey: pending.descriptor.id)
        activeNormalizationGain = pow(10, (decision?.gainDB ?? 0) / 20)
        publishLoudnessDecision(decision)
        spatialCurrentLogicalStart = pending.descriptor.presentationStartSeconds - lookaheadSeconds
        spatialPendingBoundary = nil
        activeTimelineToken = pending.token
        prefetchAttemptedForCurrentItem = false
        currentTime = max(0, min(spatialClockTime - spatialCurrentLogicalStart, duration))

        guard let advancedTrack = smartController.commitGaplessAdvance() else {
            Log.error(
                "[SpatialGapless] commit found no predicted next track; stopping renderer",
                category: .audio
            )
            stopProgressTimer()
            isPlaying = false
            AudioAnalysisHub.shared.setPlaying(false)
            AudioAnalysisHub.shared.disableRendererFeed()
            let currentLeaseToRelease = currentFileLease
            currentFileLease = nil
            audioFile = nil
            rendererPipeline.stop {
                outgoingLease?.release()
                currentLeaseToRelease?.release()
            }
            return
        }

        advancedTrack.availability = resource.newAvailability
        if let refreshed = resource.refreshedLocator {
            advancedTrack.mediaLocator = refreshed
            onAudioLocatorResolved?(advancedTrack.id, refreshed, resource.newAvailability)
        }
        releaseOutgoingSpatialScopeAfterAudibleBoundary(
            lease: outgoingLease,
            through: outgoingSegmentID,
            delay: lookaheadSeconds
        )

        gaplessLog(
            "[SpatialGapless] boundary committed track=\(advancedTrack.id.uuidString) title=\(advancedTrack.title) logicalStart=\(String(format: "%.6f", spatialCurrentLogicalStart)) duration=\(String(format: "%.3f", duration))"
        )
        if duration > 0 {
            smartController.updateProgress(currentTime: currentTime, duration: duration)
        }
    }

    private func releaseOutgoingSpatialScopeAfterAudibleBoundary(
        lease: SecurityScopedResourceLease?,
        through segmentID: UUID?,
        delay: Double
    ) {
        guard let lease, let segmentID else { return }
        let retireOutgoingSegment = { [rendererPipeline] in
            rendererPipeline.retireSegments(through: segmentID) {
                lease.release()
            }
        }
        if delay <= 0 {
            retireOutgoingSegment()
        } else {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                retireOutgoingSegment()
            }
        }
    }

    private func abandonSpatialGaplessAndFinalize() {
        releasePrefetchedResource(reason: "rendererBoundaryFallback")
        spatialPendingBoundary = nil
        let token = activeTimelineToken
        let mediaTime = spatialClockTime - spatialCurrentLogicalStart
        let drainDelay = lookaheadSeconds + max(0, duration - mediaTime)
        if drainDelay > 0 {
            beginDrain(delaySeconds: drainDelay, token: token)
        } else {
            finalizePlaybackCompletion(token: token)
        }
    }

    // MARK: - File Access

    private func stopAccessingCurrentFile() {
        currentFileLease?.release()
        currentFileLease = nil
        currentFileURL = nil
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
        activePlaybackOrderModeOverride = nil
        AppSettings.shared.shuffleEnabled = enabled
        lastKnownShuffleEnabled = enabled
        smartController.setShuffle(enabled)
    }

    func discardCurrentPlaybackSessionStatsOnce() {
        smartController.discardCurrentSessionStatsOnFinalizeOnce()
    }

    func prepareForTermination() {
        invalidatePreparation()
        restorePausedGeneration = nil
        pendingRestorePositionSeconds = nil
        pendingRetryPositionSeconds = nil
        smartController.endSeek()
        smartController.prepareForTermination()
        cancelPendingCompletion()
        activeTimelineToken = UUID()
        let prefetchedToRelease = resetGaplessSchedulingState(
            reason: "termination",
            discardPendingRendererSegment: false
        )
        pendingRendererStartSegmentID = nil
        rendererLoadSegmentID = nil
        spatialCurrentSegmentID = nil
        spatialPendingSeek = nil
        spatialCurrentLogicalStart = 0
        spatialClockTime = 0
        stopProgressTimer()
        isPlaying = false
        AudioAnalysisHub.shared.setPlaying(false)
        AudioAnalysisHub.shared.disableRendererFeed()
        let currentLeaseToRelease = currentFileLease
        currentFileLease = nil
        currentFileURL = nil
        audioFile = nil
        rendererPipeline.stop {
            currentLeaseToRelease?.release()
            prefetchedToRelease?.lease.release()
        }
    }

}
