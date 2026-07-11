//
//  AudioVisualizationService.swift
//  myPlayer2
//
//  kmgccc_player - 9-Band Audio Visualizer Service
//  Provides an adaptive, loudness-aware 9-band spectrum for skins.
//  Subscribes to AudioAnalysisHub for FFT data.
//

import Accelerate
import Foundation
import os

nonisolated final class AudioVisualizationService: @unchecked Sendable {

    typealias Consumer = @MainActor ([Float]) -> Void

    private enum Constants {
        static let bandCount = 9
        static let uiUpdateHz: Double = 30
        static let staleDataThreshold: TimeInterval = 0.12
        static let staleRestartThreshold: TimeInterval = 0.80
        static let restartCooldown: TimeInterval = 1.20
        static let stopGracePeriod: TimeInterval = 0.35
        // Low so quiet passages still publish at ~30Hz instead of dropping to the
        // 0.25s forced cadence (which made low-volume bars lurch / look granular).
        static let publishEpsilon: Float = 0.003
        static let forcePublishInterval: TimeInterval = 0.25
        /// After this long paused, the idle pose has fully settled; stop ticking.
        static let idleSuspendSeconds: TimeInterval = 0.8
        static let defaultFFTSize = 1024
        static let defaultSampleRate: Float = 44_100
    }

    private let processor = SpectrumProcessor()
    #if DEBUG
    private let legacyProcessor = LegacySpectrumProcessor()
    private let useLegacySpectrum = ProcessInfo.processInfo.environment["KMGCCC_LEGACY_SPECTRUM"] == "1"
    #endif
    private let hub = AudioAnalysisHub.shared
    private let processingQueue = DispatchQueue(
        label: "AudioVisualizationService.processing",
        qos: .utility
    )
    private let consumerLock = NSLock()

    private var consumers: [UUID: Consumer] = [:]
    private var hubConsumerId: UUID?
    private var timer: DispatchSourceTimer?
    private var activeRefs = 0
    private var isRunning = false
    private var pendingStopWorkItem: DispatchWorkItem?

    private var isPlaying: Bool = false
    private var pauseStartTime: TimeInterval?
    /// True while the tick loop is frozen because playback is paused and the
    /// idle pose has settled. Cleared (and the timer restarted) on resume.
    private var isIdleSuspended = false
    /// Last play-state delivered by any consumer. Persists across start/stop so
    /// a fresh `startLocked()` (triggered by ref-count churn while audio is
    /// actually playing) restores the real state instead of assuming paused.
    /// Without this, a consumer re-appearing mid-playback would reset
    /// `isPlaying = false`, idle-suspend after ~0.8s, and freeze every spectrum
    /// surface (incl. the LED skin capsules) at the dim idle pose.
    private var lastObservedPlaying: Bool = false

    private var liveWave: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var outputWave: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var lastPublishedWave: [Float] = Array(repeating: 0, count: Constants.bandCount)

    private var pendingMagnitudes: [Float] = []
    private var pendingFFTSize: Int = Constants.defaultFFTSize
    private var pendingSampleRate: Float = Constants.defaultSampleRate
    private var pendingRms: Float = 0
    private var pendingPeak: Float = 0
    private var hasPendingFFT = false

    /// Player volume (0...1), used to volume-compensate the time-domain RMS so
    /// the spectrum's quiet/normal/loud classification tracks the source
    /// loudness instead of the slider position. Updated from the playback
    /// service; defaults to 1.0 (no compensation) until then.
    private var playerVolume: Float = 1.0

    // Latest-frame mailbox: coalesce main-actor publishes so a stalled main
    // thread can't backlog dozens of stale frames (which would replay old
    // spectrum state after recovery). The producer overwrites the latest wave;
    // at most one main-actor drain is in flight. OSAllocatedUnfairLock is
    // async-safe (unlike NSLock, which is banned from async contexts in Swift 6)
    // and touched from both processingQueue and the main actor.
    private struct MailboxState {
        var wave: [Float] = []
        var scheduled: Bool = false
        var producedUptime: TimeInterval = 0
        var displayedCount: UInt64 = 0
        var lastAgeMs: Float = -1
    }
    private let mailbox = OSAllocatedUnfairLock(initialState: MailboxState())
    // Producer-side counters (processingQueue only - no lock needed).
    private var producedFrameCount: UInt64 = 0
    private var coalescedFrameCount: UInt64 = 0

    private var poseBlend: Float = 0.0
    private let idlePattern: [Float] = [0.37, 0.20, 0.40, 0.20, 0.65, 0.20, 0.40, 0.20, 0.37]

    private var lastDataTime: TimeInterval = 0
    private var lastTickTime: TimeInterval = 0
    private var lastPublishTime: TimeInterval = 0
    private var lastRestartAttemptTime: TimeInterval = 0

    // MARK: - External Simulation

    private var isExternalMode = false

    static let shared = AudioVisualizationService()

    private init() {}

    func start() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.pendingStopWorkItem?.cancel()
            self.pendingStopWorkItem = nil
            self.activeRefs += 1
            guard self.activeRefs == 1 else { return }
            self.startLocked()
        }
    }

    func stop() {
        processingQueue.async { [weak self] in
            guard let self else { return }
            self.activeRefs = max(0, self.activeRefs - 1)
            guard self.activeRefs == 0, self.isRunning else { return }
            self.scheduleStopLocked()
        }
    }

    func updatePlaybackState(isPlaying: Bool) {
        // Gate the shared FFT hub so it stops doing FFTs on silent buffers while
        // paused. Idempotent; safe to call from any thread.
        hub.setPlaying(isPlaying)
        processingQueue.async { [weak self] in
            guard let self else { return }
            // Always record the latest known state so a later `startLocked()`
            // (ref-count churn) restores it instead of assuming paused.
            self.lastObservedPlaying = isPlaying

            if isPlaying {
                // Force-wake: clear paused / idle-suspended state and make sure
                // the tick is running whenever playback is active. Idempotent and
                // NOT blocked by a stale `isPlaying`/suspended flag, so a resume
                // that arrives after a teardown race still revives the spectrum.
                self.isPlaying = true
                self.pauseStartTime = nil
                if self.isRunning, self.isIdleSuspended || self.timer == nil {
                    self.isIdleSuspended = false
                    self.startTimerLocked()
                }
            } else {
                guard self.isPlaying else { return }
                self.isPlaying = false
                if self.pauseStartTime == nil {
                    self.pauseStartTime = Date().timeIntervalSinceReferenceDate
                }
            }
        }
    }

    func setExternalMode(_ enabled: Bool) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            let wasEnabled = self.isExternalMode
            self.isExternalMode = enabled

            if enabled && !wasEnabled {
                self.lastDataTime = Date().timeIntervalSinceReferenceDate
            } else if !enabled && wasEnabled {
                self.hasPendingFFT = false
            }
        }
    }

    /// Update the player volume so the spectrum processor can volume-compensate
    /// its time-domain loudness measurement. Safe to call from any thread; the
    /// value is read on the processing queue. Defaults to 1.0 until first call.
    func updateVolume(_ volume: Float) {
        let clamped = max(0, min(1, volume))
        processingQueue.async { [weak self] in
            self?.playerVolume = clamped
        }
    }

    func addConsumer(_ callback: @escaping Consumer) -> UUID {
        let id = UUID()

        consumerLock.lock()
        consumers[id] = callback
        consumerLock.unlock()

        let initialWave = processingQueue.sync { lastPublishedWave }
        Task { @MainActor in
            callback(initialWave)
        }

        return id
    }

    func removeConsumer(_ id: UUID) {
        consumerLock.lock()
        consumers.removeValue(forKey: id)
        consumerLock.unlock()
    }

    private func startLocked() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        let now = Date().timeIntervalSinceReferenceDate
        isRunning = true
        // Restore the last known play-state rather than assuming paused. Only arm
        // the idle-suspend countdown when we actually believe playback is paused;
        // otherwise a restart during active playback (consumer churn) would freeze
        // the spectrum at the idle pose even though audio is playing.
        isPlaying = lastObservedPlaying
        pauseStartTime = lastObservedPlaying ? nil : now
        isIdleSuspended = false
        if LogConfig.perfDebugEnabled {
            Log.debug(
                "[AudioViz] startLocked restored playing=\(lastObservedPlaying)",
                category: .audio
            )
        }
        processor.reset()
        #if DEBUG
        legacyProcessor.reset()
        #endif
        liveWave = Array(repeating: 0, count: Constants.bandCount)
        outputWave = Array(repeating: 0, count: Constants.bandCount)
        lastPublishedWave = Array(repeating: 0, count: Constants.bandCount)
        pendingMagnitudes = []
        pendingFFTSize = Constants.defaultFFTSize
        pendingSampleRate = Constants.defaultSampleRate
        pendingRms = 0
        pendingPeak = 0
        hasPendingFFT = false
        poseBlend = 0
        lastDataTime = now
        lastTickTime = now
        lastPublishTime = 0
        lastRestartAttemptTime = 0
        // Reset the latest-frame mailbox + scheduling counters.
        mailbox.withLock { state in
            state = MailboxState()
        }
        producedFrameCount = 0
        coalescedFrameCount = 0

        hub.start()
        hubConsumerId = hub.addConsumer { [weak self] data in
            self?.enqueue(data)
        }
        startTimerLocked()
    }

    private func stopLocked() {
        pendingStopWorkItem?.cancel()
        pendingStopWorkItem = nil
        if let id = hubConsumerId {
            hub.removeConsumer(id)
        }
        hubConsumerId = nil
        hub.stop()
        stopTimerLocked()

        let zeroWave = Array(repeating: Float(0), count: Constants.bandCount)
        let shouldPublishZero = lastPublishedWave.contains(where: { $0 > 0.001 })

        isRunning = false
        processor.reset()
        #if DEBUG
        legacyProcessor.reset()
        #endif
        liveWave = zeroWave
        outputWave = zeroWave
        lastPublishedWave = zeroWave
        pendingMagnitudes = []
        pendingRms = 0
        pendingPeak = 0
        hasPendingFFT = false
        poseBlend = 0
        pauseStartTime = nil
        lastPublishTime = 0

        if shouldPublishZero {
            publish(zeroWave)
        }
    }

    private func scheduleStopLocked() {
        pendingStopWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.activeRefs == 0, self.isRunning else { return }
            self.stopLocked()
        }

        pendingStopWorkItem = workItem
        processingQueue.asyncAfter(deadline: .now() + Constants.stopGracePeriod, execute: workItem)
    }

    private func enqueue(_ data: AudioAnalysisData) {
        processingQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.pendingMagnitudes = data.magnitudes
            self.pendingFFTSize = data.fftSize
            self.pendingSampleRate = data.sampleRate
            self.pendingRms = data.rms
            self.pendingPeak = data.peak
            self.hasPendingFFT = true
            self.lastDataTime = Date().timeIntervalSinceReferenceDate
        }
    }

    private func startTimerLocked() {
        stopTimerLocked()

        let interval = 1.0 / Constants.uiUpdateHz
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(4))
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        timer.resume()
        self.timer = timer
    }

    private func stopTimerLocked() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        guard isRunning else { return }

        let now = Date().timeIntervalSinceReferenceDate
        let dt = Float(max(0.001, min(0.1, now - lastTickTime)))
        lastTickTime = now

        // Idle-CPU: once paused and the idle pose has settled, stop ticking
        // (freeze the last published frame) until playback resumes. This applies
        // to external mode too — the simulator idle-suspends in parallel, so a
        // paused Apple Music / system source no longer drives a 30Hz spectrum
        // tick (nor the mesh background's 30Hz JS bridge calls). Resume is
        // driven by skins/mesh/fullscreen via updatePlaybackState(true).
        if !isPlaying, let ps = pauseStartTime,
           now - ps >= Constants.idleSuspendSeconds {
            isIdleSuspended = true
            stopTimerLocked()
            return
        }

        if isExternalMode {
            liveWave = ExternalPlaybackSpectrumSimulator.shared.lastWave
            lastDataTime = now
        } else if hasPendingFFT {
            liveWave = processWave(
                magnitudes: pendingMagnitudes,
                fftSize: pendingFFTSize,
                sampleRate: pendingSampleRate,
                rms: pendingRms,
                peak: pendingPeak,
                playerVolume: playerVolume,
                dt: dt
            )
            hasPendingFFT = false
        } else if isPlaying, now - lastDataTime > Constants.staleDataThreshold {
            // Only force a decay tick while playing; while paused we keep the
            // last processor output and let the idle-pose blend handle the slow
            // settle-down.
            liveWave = processWave(
                magnitudes: [],
                fftSize: pendingFFTSize,
                sampleRate: pendingSampleRate,
                rms: 0,
                peak: 0,
                playerVolume: playerVolume,
                dt: dt
            )
        }

        if !isExternalMode,
           isPlaying,
           activeRefs > 0,
           now - lastDataTime > Constants.staleRestartThreshold,
           now - lastRestartAttemptTime > Constants.restartCooldown
        {
            restartAnalysisChainLocked(now: now)
        }

        var targetBlend: Float = 0
        if !isPlaying, let start = pauseStartTime, now - start >= 0.05 {
            targetBlend = 1
        }

        // Asymmetric blend: pause-in is slow and silky; resume-out is fast so
        // the spectrum feels immediately attached to the music.
        let blendTau: Float = targetBlend > poseBlend ? 0.45 : 0.12
        let factor = 1.0 - exp(-dt / blendTau)
        poseBlend += (targetBlend - poseBlend) * factor

        for index in 0..<Constants.bandCount {
            let live = liveWave[index]
            let pose = idlePattern[index]
            outputWave[index] = live + (pose - live) * poseBlend
        }

        let maxDelta = zip(outputWave, lastPublishedWave).reduce(Float.zero) { partial, pair in
            max(partial, abs(pair.0 - pair.1))
        }
        let uiColdPathActive = FirstUseHitchDiagnostics.currentMainOperationDescription() != nil
        let minPublishInterval = uiColdPathActive ? (1.0 / 15.0) : 0
        let shouldPublish =
            (now - lastPublishTime) >= minPublishInterval
            && (maxDelta >= Constants.publishEpsilon
                || (now - lastPublishTime) >= Constants.forcePublishInterval)

        guard shouldPublish else { return }
        lastPublishTime = now
        lastPublishedWave = outputWave
        publish(outputWave)
    }

    private func publish(_ wave: [Float]) {
        consumerLock.lock()
        let callbacks = Array(consumers.values)
        consumerLock.unlock()

        guard callbacks.isEmpty == false else { return }

        producedFrameCount &+= 1
        let now = ProcessInfo.processInfo.systemUptime

        // Latest-frame mailbox: overwrite the pending wave. If a main-actor
        // drain is already scheduled, it will deliver this latest wave - don't
        // queue another Task. This caps pending main updates at 1, so a stalled
        // main thread can't backlog stale frames that would replay old state.
        let alreadyScheduled = mailbox.withLock { state -> Bool in
            state.wave = wave
            state.producedUptime = now
            let wasScheduled = state.scheduled
            state.scheduled = true
            return wasScheduled
        }

        if alreadyScheduled {
            coalescedFrameCount &+= 1
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            let snapshot = self.mailbox.withLock { state -> (wave: [Float], producedAt: TimeInterval) in
                let wave = state.wave
                let producedAt = state.producedUptime
                state.scheduled = false
                state.displayedCount &+= 1
                return (wave, producedAt)
            }
            let ageMs = Float((ProcessInfo.processInfo.systemUptime - snapshot.producedAt) * 1000)
            self.mailbox.withLock { state in state.lastAgeMs = ageMs }
            // Single coalesced main-actor hop: deliver the same latest wave to
            // every consumer (skin spectrum + mesh background + fullscreen).
            for callback in callbacks {
                callback(snapshot.wave)
            }
        }
    }

    /// Snapshot of the scheduling counters for diagnostics. Called on the
    /// processingQueue; the lock is async-safe.
    private func schedulingStats() -> (produced: UInt64, displayed: UInt64, coalesced: UInt64, pending: Int, frameAgeMs: Float) {
        let (displayed, pending, age) = mailbox.withLock { state -> (UInt64, Int, Float) in
            (state.displayedCount, state.scheduled ? 1 : 0, state.lastAgeMs)
        }
        return (producedFrameCount, displayed, coalescedFrameCount, pending, age)
    }

    private func restartAnalysisChainLocked(now: TimeInterval) {
        lastRestartAttemptTime = now

        if let id = hubConsumerId {
            hub.removeConsumer(id)
            hubConsumerId = nil
        }

        hub.reinstallTapIfActive()
        hubConsumerId = hub.addConsumer { [weak self] data in
            self?.enqueue(data)
        }
        lastDataTime = now
        startTimerLocked()
    }

    private func processWave(
        magnitudes: [Float],
        fftSize: Int,
        sampleRate: Float,
        rms: Float,
        peak: Float,
        playerVolume: Float,
        dt: Float
    ) -> [Float] {
        let scheduling = schedulingStats()
        #if DEBUG
        if useLegacySpectrum {
            return legacyProcessor.process(
                magnitudes: magnitudes,
                fftSize: fftSize,
                sampleRate: sampleRate
            )
        }
        #endif
        return processor.process(
            magnitudes: magnitudes,
            fftSize: fftSize,
            sampleRate: sampleRate,
            rms: rms,
            peak: peak,
            playerVolume: playerVolume,
            scheduling: scheduling,
            dt: dt
        )
    }
}

// MARK: - Legacy Spectrum Processor

//
//  LegacySpectrumProcessor.swift
//  myPlayer2
//
//  kmgccc_player - Legacy 9-band spectrum processor.
//
//  Preserved for Debug A/B comparison against the adaptive spectrum.
//  Activate with KMGCCC_LEGACY_SPECTRUM=1 (DEBUG builds only).
//

nonisolated final class LegacySpectrumProcessor: @unchecked Sendable {

    struct Constants {
        // 1. Upstream Gains & Headroom
        static let inputGainDb: Float = -75.0  // Added to initial dB to shift everything down
        static let minDb: Float = -85.0
        static let maxDb: Float = -15.0  // Raised from -25 to increase headroom (less sensitive)

        static let tiltAmount: Float = 0.28  // Spectral tilt to dampen highs before balancer

        // 2. Balancers [inMin, inMax] for 9 bands
        // User requested ranges to prevent middle bands from pegging
        // Lower sensitivity for Mid bands (2..7)
        static let balancers: [(min: Float, max: Float)] = [
            (0.20, 0.73),  // 0: Sub (20-60Hz)
            (0.44, 0.85),  // 1: Bass (60-140Hz)
            (0.35, 0.88),  // 2: Low-Mid (140-260Hz)
            (0.24, 0.80),  // 3: Mid (260-420Hz)
            (0.08, 0.600),  // 4: Low-Treble (420-650Hz)
            (0.06, 0.580),  // 5: Mid-Treble (650-1000Hz)
            (0.01, 0.400),  // 6: High-Treble (1000-3500Hz)
            (0.00, 0.280),  // 7: High+ (3500-12000Hz)
            (0.00, 0.07),  // 8: Air (12000-20000Hz) - Very High Sensitivity
        ]

        // 3. Dynamics (Soft-Knee & Smoothing)
        static let lowBoost: Float = 1.28  // Boost sensitivity for low-level signals
        static let knee: Float = 0.68 // Knee point for transition to compression
        static let hard: Float = 0.33  // Compression strength for high-level signals
        // Lowered from 3.0: cubed crushed quiet signals below the band gates so
        // low-volume bars flickered 0↔tiny (coarse/granular). 2.0 keeps quiet
        // detail above the gate while still expanding loud transients. Shared
        // with the mesh background (wave[0..1]); it reshapes/caps its own input
        // so a slightly stronger bass pulse is tolerated.
        static let cubicPower: Float = 2.0
        // Faster rise so bars track transients with less lag; release unchanged
        // to preserve the existing smooth fall / anti-flicker feel.
        static let attack: Float = 0.6
        static let release: Float = 0.35
        // 4. Per-band Small Gates
        static let bandGates: [Float] = [
            0.01, 0.01, 0.01, 0.008, 0.008, 0.005, 0.005, 0.003, 0.003,
        ]
    }

    private let bandCount: Int = 9
    private var smoothedBands: [Float]
    /// Reused per-bin scratch buffer (see `processBins`). Avoids a ~1024-float
    /// allocation + zero-fill on every 30Hz tick. Not published, so reuse is safe.
    private var scaledBinsBuffer: [Float] = []

    init() {
        self.smoothedBands = [Float](repeating: 0, count: bandCount)
    }

    func reset() {
        for i in 0..<bandCount {
            smoothedBands[i] = 0
        }
    }

    func process(magnitudes: [Float], fftSize: Int, sampleRate: Float) -> [Float] {
        // 1. Per-bin Preprocessing (dB -> Scaled -> Tilt)
        let scaledBins = processBins(magnitudes: magnitudes)

        // 2. Per-band Energy Calculation (Average of scaledBins)
        let bandEnergy = computeBandsFromScaledBins(
            scaledBins: scaledBins, fftSize: fftSize, sampleRate: sampleRate)

        var result = [Float](repeating: 0, count: bandCount)

        // 3. Per-band Balancer + Soft-Knee + Smoothing
        for i in 0..<bandCount {
            let energy = bandEnergy[i]
            let bal = Constants.balancers[i]

            // Map energy to normalized range (unclamped)
            let x = max(0.0, (energy - bal.min) / (bal.max - bal.min))

            // Soft-Knee Dynamic Curve
            let y: Float
            if x <= Constants.knee {
                // Low-level: Power curve boost to increase sensitivity
                y = pow(x / Constants.knee, 0.7) * (Constants.knee * Constants.lowBoost)
            } else {
                // High-level: Exponential compression to prevent harsh clipping
                let t = x - Constants.knee
                y = Constants.knee + (1.0 - exp(-t / Constants.hard)) * (1.0 - Constants.knee)
            }

            var amplitude = min(1.0, max(0.0, y))

            // Cubic Expansion (Applied before smoothing)
            amplitude = pow(amplitude, Constants.cubicPower)

            // Gate check
            if amplitude < Constants.bandGates[i] { amplitude = 0 }

            // 4. Envelope Smoothing (Attack/Release)
            var current = smoothedBands[i]
            if amplitude > current {
                current += (amplitude - current) * Constants.attack
            } else {
                current += (amplitude - current) * Constants.release
            }
            smoothedBands[i] = current

            result[i] = current
        }

        return result
    }

    private func processBins(magnitudes: [Float]) -> [Float] {
        guard !magnitudes.isEmpty else { return [] }
        let count = magnitudes.count
        // Reuse the scratch buffer across ticks; every element is overwritten in
        // the loop below, so no zero-fill is needed. The buffer is only read by
        // `computeBandsFromScaledBins` within the same tick and never escapes.
        if scaledBinsBuffer.count != count {
            scaledBinsBuffer = [Float](repeating: 0, count: count)
        }

        for i in 0..<count {
            // amp = sqrt(mag) if mag is |z|^2
            let mag = magnitudes[i]
            let db = 20 * log10(sqrt(mag) + 1e-7) + Constants.inputGainDb

            // Normalize to 0...1
            var scaled = (db - Constants.minDb) / (Constants.maxDb - Constants.minDb)
            scaled = min(1.0, max(0.0, scaled))

            // Spectral Tilt (simulating apple-audio-visualization logic)
            // tilt amount increases with frequency
            let progress = Float(i) / Float(count)
            let tilt = (0.4 + progress * 0.6) * Constants.tiltAmount
            scaled -= tilt

            scaledBinsBuffer[i] = max(0.0, scaled)
        }
        return scaledBinsBuffer
    }

    private func computeBandsFromScaledBins(scaledBins: [Float], fftSize: Int, sampleRate: Float)
        -> [Float]
    {
        guard !scaledBins.isEmpty else { return [Float](repeating: 0, count: bandCount) }

        let edges: [Float] = [20, 60, 140, 260, 420, 650, 1000, 3500, 12000, 20000]
        var bandEnergy = [Float](repeating: 0, count: bandCount)

        let binHz = sampleRate / Float(fftSize)
        let maxBin = scaledBins.count - 1

        for i in 0..<bandCount {
            let startHz = edges[i]
            let endHz = edges[i + 1]

            let startBin = min(maxBin, max(0, Int(startHz / binHz)))
            let endBin = min(maxBin, max(startBin + 1, Int(endHz / binHz)))

            if startBin >= endBin {
                bandEnergy[i] = 0
                continue
            }

            var sum: Float = 0
            for b in startBin..<endBin {
                sum += scaledBins[b]
            }
            bandEnergy[i] = sum / Float(endBin - startBin)
        }

        return bandEnergy
    }
}

// MARK: - Adaptive Spectrum Processor

//
//  SpectrumProcessor.swift
//  myPlayer2
//
//  kmgccc_player - Adaptive 9-band spectrum processor (v3).
//
//  v3 redesign (addresses v2 regressions: quiet music over-excited, loud music
//  stiff/flat, gourd silhouette lost, all bands jumping together):
//
//    1. Absolute loudness from time-domain RMS (AudioAnalysisData.rms), divided
//       by the known player volume so the quiet/normal/loud classification
//       tracks the SOURCE loudness and does not shift when the user moves the
//       volume slider. A three-segment curve (quiet / normal / loud) drives an
//       explicit baseScale + motionScale budget. Quiet gets a SMALL motion
//       budget (not near-full); loud gets a large one. No linear quiet->loud
//       interpolation of a single budget.
//
//    2. The "gourd" spectral silhouette is a fixed per-band shape weight
//       (baseShapeWeight / motionShapeWeight). It is the stable display curve
//       and is NOT flattened by any per-band adaptive trim. slowTrimDb and the
//       old staticBandCalibrationDb are removed. An equal-energy input
//       reproduces the gourd directly.
//
//    3. Base and Motion use SEPARATE time scales. Base is slow and stable
//       (attack 0.10s / release 0.19s) so the sustained profile does not twitch
//       on every onset; Motion is fast (attack 0.028s / release 0.090s) so
//       beats punch and release quickly. Two independent per-band envelopes.
//
//    4. Motion = spectral flux + slow-baseline excursion + local contrast
//       (all relative dB, volume-invariant), gated by an absolute per-band
//       energy gate AND a global quiet gate, boosted for low-crest (heavily
//       compressed) masters, normalized by a SHARED (not per-band) motion
//       scale, with common-mode removal so a broadband onset does not throw
//       every band up at once.
//
//    5. Hard clip only; no soft-clip compressor. Minimal spatial smoothing
//       (weak base kernel, motion unsmoothed) so per-band contrast survives.
//

nonisolated final class SpectrumProcessor: @unchecked Sendable {

    struct Constants {
        static let bandCount = 9
        // v5: high end redistributed. High+ (band 7) now covers the sibilance
        // core (3.5-8kHz) so vocal 呲呲 reads; Air (band 8) is the single
        // ultra-high bar (8-20kHz). Mid bands nudged so MTreb reaches 1.3kHz.
        static let frequencyEdges: [Float] = [20, 60, 140, 260, 420, 700, 1300, 3500, 8000, 20000]

        // dB math
        static let epsilon: Float = 1e-12
        static let noiseFloorDb: Float = -96

        // Fixed spectral tilt (dB). Counteracts the natural high-frequency
        // falloff of real music so highs stay visible WITHOUT adaptive per-band
        // flattening. Constant; never tracks song history. Mid is the 0 reference.
        // Tuned via the deterministic harness so Mid stays the peak in both the
        // equal-band and pink-spectrum cases.
        //   Sub  Bass  LMid  Mid  LTreb MTreb HTreb High+ Air
        static let fixedSpectralTiltDb: [Float] = [
            -3.0,  // 0: Sub
            -2.0,  // 1: Bass
            -1.0,  // 2: LMid   (extra-suppressed waist)
             0.0,  // 3: Mid      (reference)
            +0.8,  // 4: LTreb
            +1.8,  // 5: MTreb
            +3.0,  // 6: HTreb
            +5.0,  // 7: High+  (sibilance 3.5-8kHz, boosted for visibility)
            +6.0,  // 8: Air
        ]

        // "Mid-peak" silhouette: Mid is the highest, LMid is the waist (low
        // sensitivity), a small left hump at Bass, a second hump at LTreb,
        // gradual fall to Air. High+ (sibilance) kept visible. Tuned via the
        // harness so Mid peaks in both equal-band and pink-spectrum cases.
        static let baseShapeWeight: [Float] = [
            0.70,  // 0: Sub
            0.78,  // 1: Bass   (left hump)
            0.38,  // 2: LMid   (waist - low sensitivity)
            1.00,  // 3: Mid    (main peak)
            0.88,  // 4: LTreb  (second hump)
            0.78,  // 5: MTreb
            0.68,  // 6: HTreb
            0.66,  // 7: High+  (sibilance)
            0.45,  // 8: Air    (ultra-high, single bar)
        ]
        // Motion silhouette: low-freq extra-restrained, High+ (sibilance) kept
        // responsive so 呲呲 lifts band 7. v6: low-freq more sensitive (Sub/Bass
        // up), mid jumps less but stays tall (Mid/LTreb/MTreb motion weight down;
        // base weight unchanged so mid height holds).
        static let motionShapeWeight: [Float] = [
            0.55, 0.68, 0.50, 0.75, 0.76, 0.72, 0.74, 0.78, 0.50
        ]

        // --- Absolute loudness (time-domain RMS, volume-compensated) ---
        // These are TRUE dBFS values (20*log10(rms)) of the pre-volume signal.
        // Calibrate via KMGCCC_DEBUG_SPECTRUM=1 (watch rms=/state=).
        static let loudnessTau: Float = 0.60       // slow; modes must not flip per beat
        static let quietFloorDbFS: Float = -38     // below = pure quiet
        static let quietToNormalDbFS: Float = -30  // quiet -> normal transition
        static let normalToLoudDbFS: Float = -20   // normal -> loud transition
        static let loudFloorDbFS: Float = -14      // above = pure loud

        // Three-segment display budgets. v5: quiet is much shorter (was 0.24)
        // so quiet music reads as genuinely low bars, not lifted by the mapping.
        // v6: quiet lowered further (0.12 -> 0.09).
        static let baseScaleQuiet: Float = 0.09
        static let baseScaleNormal: Float = 0.39
        static let baseScaleLoud: Float = 0.33
        static let motionScaleQuiet: Float = 0.04
        static let motionScaleNormal: Float = 0.28
        static let motionScaleLoud: Float = 0.50
        // Fraction of motion retained at quiet (15-35% per spec).
        static let quietMotionGateFloor: Float = 0.20

        // Crest-factor compression boost: engages only when LOUD and LOW-crest
        // (heavily compressed master). Dynamic music is unaffected. Boosts motion
        // only, never base.
        static let crestTau: Float = 0.60
        static let compressedCrestDb: Float = 5.0    // below = compressed
        static let dynamicCrestDb: Float = 10.0      // above = dynamic
        static let compressionBoostMax: Float = 0.55 // up to +55% motion

        // --- Base layer ---
        // Band dB relative to the global mean band power (volume-invariant: both
        // come from the same FFT tap). The offset is deliberately large/negative
        // so the reference sits below most bands; the shape weight then becomes
        // the dominant contour factor (Mid weight 1.0 wins) and the tilt can
        // lift highs without exceeding Mid. Tuned via the harness.
        static let fftMeanPowerTau: Float = 0.50
        static let baseReferenceOffsetDb: Float = -16.0
        static let baseRangeDb: Float = 26.0

        // --- Low-frequency prominence gate (motion) ---
        // Low-freq motion is only allowed when the Sub/Bass energy actually
        // exceeds the vocal-body bands (LMid/Mid) by a clear margin. Without
        // this, vocal fundamentals, spectral leakage, and broadband common-mode
        // changes flap the left side. Real kicks/bass still rise because their
        // energy dominates. v6: thresholds raised (+3/+10) and floors lowered
        // (0.10/0.15) so small/quiet low-freq energy barely moves but big
        // obvious kicks still punch (ceil 0.85/0.92).
        static let lowProminenceStartDb: Float = 3.0    // below = minimal low motion
        static let lowProminenceFullDb: Float = 10.0    // above = full low motion
        static let subMotionFloor: Float = 0.10         // retained when not prominent
        static let subMotionCeil: Float = 0.85          // v6: was 0.65, boost real kicks
        static let bassMotionFloor: Float = 0.15        // v6: was 0.30
        static let bassMotionCeil: Float = 0.92         // v6: was 0.78, boost real kicks

        // --- High-frequency visibility (base + motion) ---
        // Highs need a noise gate (no fake floor when silent) plus a one-shot soft
        // gamma so they read as visible-but-low. No global gamma < 1.
        static let highBandStartIndex: Int = 6          // HTreb, High+, Air
        static let highBandNoiseFloorDb: Float = -30.0  // relative to global mean: below = silent
        static let highBandVisibleDb: Float = -16.0     // relative to global mean: above = full
        static let highBandGamma: Float = 0.88          // one-shot soft shaping (>= 1 would crush)

        // --- Motion extraction (relative dB, volume-invariant) ---
        static let fluxWeight: Float = 0.45
        static let excursionWeight: Float = 0.25
        static let contrastWeight: Float = 0.30
        static let bandMeanTau: Float = 2.0       // slow baseline (excursion)
        static let localMeanTau: Float = 0.08     // fast local mean (contrast)
        static let motionSoftKneeDb: Float = 4.0
        static let motionMaxDb: Float = 20.0

        // Per-band energy gate: a band far below the mix average is near-silent
        // and must not produce motion even if it fluctuates in relative dB.
        static let bandEnergyGateFloorDb: Float = -34   // relative to global mean
        static let bandEnergyGateCeilDb: Float = -14

        // Shared motion scale (ALL bands share ONE scale; no per-band AGC).
        static let sharedMotionPercentile: Float = 0.85
        static let sharedMotionTau: Float = 1.5
        static let sharedMotionMinDb: Float = 3.0
        static let sharedMotionMaxDb: Float = 16.0

        // Common-mode removal: subtract a fraction of the cross-band median so a
        // broadband onset doesn't throw every band up. Sub/Bass use a STRONGER
        // removal so a broadband vocal onset doesn't average into a row of low-freq
        // pulses. A small residual global pulse is kept so the spectrum breathes.
        static let commonModeRemoval: [Float] = [
            0.75,  // 0: Sub   (stronger)
            0.70,  // 1: Bass  (stronger)
            0.55, 0.55, 0.55, 0.55, 0.55, 0.55, 0.55
        ]
        static let globalPulseGain: Float = 0.12
        static let globalPulseCapDb: Float = 2.0

        // Separate base / motion envelopes (frame-rate-independent). v5 shortens
        // release so peaks fall more crisply; attack is barely changed.
        static let baseAttackTau: Float = 0.095
        static let baseReleaseTau: Float = 0.165
        // v5: per-band motion taus. Low (Sub/Bass) faster so kicks punch and
        // release quickly; Mid (LMid..MTreb) slower so the body doesn't flicker;
        // High medium. v6: low-freq attack snappier (0.018) for more sensitivity.
        static let motionAttackTau: [Float] =  [0.018, 0.018, 0.030, 0.030, 0.030, 0.030, 0.026, 0.026, 0.026]
        static let motionReleaseTau: [Float] = [0.050, 0.050, 0.090, 0.090, 0.090, 0.090, 0.065, 0.065, 0.065]
        // Slow fade when the stream stalls (no input): a brief glitch doesn't
        // freeze bars, but a dead stream still fades.
        static let stallDecayTau: Float = 0.35

        // Spatial smoothing: base keeps a weak kernel (tuned down so neighbors
        // don't pull LTreb up toward Mid and blur the Mid-peak); motion is
        // unsmoothed so per-band contrast survives.
        static let baseSpatialKernel: [Float] = [0.05, 0.90, 0.05]

        // Diagnostics emitted every N seconds when KMGCCC_DEBUG_SPECTRUM=1
        static let diagnosticsInterval: TimeInterval = 2.0
    }

    // MARK: - State

    private var initialized = false
    private var lastDt: Float = 1.0 / 30.0

    private var bandDb: [Float] = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
    private var previousBandDb: [Float] = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
    private var bandMeanDb: [Float] = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
    private var localMeanDb: [Float] = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)

    private var fftMeanPower: Float = 0
    private var fftMeanPowerDb: Float = Constants.noiseFloorDb

    private var shortTermRmsDbFS: Float = Constants.noiseFloorDb
    private var shortTermPeakDbFS: Float = Constants.noiseFloorDb
    private var crestDb: Float = 12

    private var sharedMotionScaleDb: Float = 8

    // Two independent per-band envelopes.
    private var baseCurrent: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var motionCurrent: [Float] = Array(repeating: 0, count: Constants.bandCount)

    // Reusable scratch buffers (avoid per-frame allocations).
    private var rawBaseBuffer: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var calibratedBandDbBuffer: [Float] = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
    private var rawMotionDbBuffer: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var motionDbBuffer: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var normalizedMotionBuffer: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var baseFinalBuffer: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var motionFinalBuffer: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var targetBuffer: [Float] = Array(repeating: 0, count: Constants.bandCount)

    // Last-frame classification (for diagnostics).
    private var lastBaseScale: Float = 0
    private var lastMotionScale: Float = 0
    private var lastGlobalMotionGate: Float = 0
    private var lastCompressionBoost: Float = 1
    private var lastCommonMotionDb: Float = 0
    private var lastLowProminenceGate: Float = 0
    private var lastLoudnessState: String = "-"
    // Volume-compensation diagnostics (raw vs compensated RMS).
    private var lastRawRms: Float = 0
    private var lastPlayerVolume: Float = 1
    private var lastCompensatedRms: Float = 0

    private var diagnostics = SpectrumDiagnostics()

    // MARK: - Public API

    init() {}

    func reset() {
        initialized = false
        lastDt = 1.0 / 30.0
        bandDb = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
        previousBandDb = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
        bandMeanDb = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
        localMeanDb = Array(repeating: Constants.noiseFloorDb, count: Constants.bandCount)
        fftMeanPower = 0
        fftMeanPowerDb = Constants.noiseFloorDb
        shortTermRmsDbFS = Constants.noiseFloorDb
        shortTermPeakDbFS = Constants.noiseFloorDb
        crestDb = 12
        sharedMotionScaleDb = 8
        baseCurrent = Array(repeating: 0, count: Constants.bandCount)
        motionCurrent = Array(repeating: 0, count: Constants.bandCount)
        diagnostics.reset()
    }

    func process(
        magnitudes: [Float],
        fftSize: Int,
        sampleRate: Float,
        rms: Float,
        peak: Float,
        playerVolume: Float,
        scheduling: (produced: UInt64, displayed: UInt64, coalesced: UInt64, pending: Int, frameAgeMs: Float),
        dt: Float
    ) -> [Float] {
        let dtClamped = max(0.001, min(0.1, dt))
        lastDt = dtClamped
        let hasInput = !magnitudes.isEmpty && fftSize > 0 && sampleRate > 0

        if hasInput {
            computeBandEnergies(magnitudes: magnitudes, fftSize: fftSize, sampleRate: sampleRate)
            updateLoudness(dt: dtClamped, magnitudes: magnitudes, rms: rms, peak: peak, playerVolume: playerVolume)
            updateBandMeans(dt: dtClamped)
        }

        if !initialized {
            guard hasInput else {
                for i in 0..<Constants.bandCount { targetBuffer[i] = 0 }
                return targetBuffer
            }
            seedState(magnitudes: magnitudes, rms: rms, peak: peak, playerVolume: playerVolume)
            computeTarget()
            // Snap envelopes to the initial target so the first frame isn't a ramp.
            baseCurrent = baseFinalBuffer
            motionCurrent = motionFinalBuffer
            for i in 0..<Constants.bandCount {
                targetBuffer[i] = clamp(baseCurrent[i] + motionCurrent[i], min: 0, max: 1)
            }
            initialized = true
            return targetBuffer
        }

        if hasInput {
            computeTarget()
        }

        applyEnvelopes(dt: dtClamped, hasInput: hasInput)

        if hasInput, LogConfig.spectrumDebugEnabled {
            diagnostics.recordFrame(
                rmsDbFS: shortTermRmsDbFS,
                peakDbFS: shortTermPeakDbFS,
                crestDb: crestDb,
                loudnessState: lastLoudnessState,
                baseScale: lastBaseScale,
                motionScale: lastMotionScale,
                globalMotionGate: lastGlobalMotionGate,
                compressionBoost: lastCompressionBoost,
                sharedMotionScaleDb: sharedMotionScaleDb,
                commonMotionDb: lastCommonMotionDb,
                lowProminenceGate: lastLowProminenceGate,
                rawRms: lastRawRms,
                playerVolume: lastPlayerVolume,
                compensatedRms: lastCompensatedRms,
                scheduling: scheduling,
                baseBands: baseCurrent,
                motionBands: motionCurrent,
                finalBands: targetBuffer
            )
            diagnostics.emitIfNeeded()
        }

        return targetBuffer
    }

    // MARK: - Energy / dB

    private func computeBandEnergies(magnitudes: [Float], fftSize: Int, sampleRate: Float) {
        let binHz = sampleRate / Float(fftSize)
        let maxBin = magnitudes.count - 1

        for i in 0..<Constants.bandCount {
            let startHz = Constants.frequencyEdges[i]
            let endHz = Constants.frequencyEdges[i + 1]

            let startBin = min(maxBin, max(0, Int(startHz / binHz)))
            let endBin = min(maxBin, max(startBin + 1, Int(endHz / binHz)))

            guard endBin > startBin else {
                bandDb[i] = Constants.noiseFloorDb
                continue
            }

            var sum: Float = 0
            for b in startBin..<endBin {
                sum += magnitudes[b]
            }
            let power = sum / Float(endBin - startBin)
            bandDb[i] = 10 * log10(power + Constants.epsilon)
        }
    }

    // MARK: - Loudness (time-domain RMS, volume-compensated)

    private func updateLoudness(
        dt: Float, magnitudes: [Float], rms: Float, peak: Float, playerVolume: Float
    ) {
        // Compensate for the player volume so the classification tracks the
        // source loudness, not the slider position. The tap sits on
        // playbackMixer (downstream of playerNode.volume); dividing by the
        // known volume recovers the pre-volume level. Below 5% the tap signal is
        // too close to the noise floor to divide safely, so hold the last
        // classification (muted/very-quiet must not amplify noise into "loud").
        // Compensated values are clamped to full-scale so a tiny divisor can't
        // explode a noise floor into a high-level signal.
        lastRawRms = rms
        lastPlayerVolume = playerVolume
        if playerVolume > 0.05 {
            let compRms = min(rms / playerVolume, 1.0)
            let compPeak = min(peak / playerVolume, 1.0)
            lastCompensatedRms = compRms
            let instantRmsDb = 20 * log10(compRms + Constants.epsilon)
            let instantPeakDb = 20 * log10(compPeak + Constants.epsilon)

            let alpha = 1 - exp(-dt / Constants.loudnessTau)
            shortTermRmsDbFS += alpha * (instantRmsDb - shortTermRmsDbFS)
            shortTermPeakDbFS += alpha * (instantPeakDb - shortTermPeakDbFS)

            let instantCrest = instantPeakDb - instantRmsDb
            let crestAlpha = 1 - exp(-dt / Constants.crestTau)
            crestDb += crestAlpha * (instantCrest - crestDb)
        }

        // FFT mean power: volume-invariant reference for the base layer. Both
        // this and bandDb come from the same tap, so bandDb - fftMeanPowerDb is
        // independent of the volume slider.
        let meanPower = magnitudes.reduce(Float.zero) { $0 + $1 } / Float(magnitudes.count)
        let powerAlpha = 1 - exp(-dt / Constants.fftMeanPowerTau)
        fftMeanPower += powerAlpha * (meanPower - fftMeanPower)
        fftMeanPowerDb = 10 * log10(fftMeanPower + Constants.epsilon)
    }

    private func updateBandMeans(dt: Float) {
        let meanAlpha = 1 - exp(-dt / Constants.bandMeanTau)
        let localAlpha = 1 - exp(-dt / Constants.localMeanTau)
        for i in 0..<Constants.bandCount {
            bandMeanDb[i] += meanAlpha * (bandDb[i] - bandMeanDb[i])
            localMeanDb[i] += localAlpha * (bandDb[i] - localMeanDb[i])
        }
    }

    private func seedState(magnitudes: [Float], rms: Float, peak: Float, playerVolume: Float) {
        let meanPower = magnitudes.reduce(Float.zero) { $0 + $1 } / Float(magnitudes.count)
        fftMeanPower = meanPower
        fftMeanPowerDb = 10 * log10(fftMeanPower + Constants.epsilon)

        lastRawRms = rms
        lastPlayerVolume = playerVolume
        let comp = playerVolume > 0.05 ? min(playerVolume, 1.0) : 1.0
        let compRms = min(rms / comp, 1.0)
        let compPeak = min(peak / comp, 1.0)
        lastCompensatedRms = compRms
        shortTermRmsDbFS = 20 * log10(compRms + Constants.epsilon)
        shortTermPeakDbFS = 20 * log10(compPeak + Constants.epsilon)
        crestDb = shortTermPeakDbFS - shortTermRmsDbFS

        for i in 0..<Constants.bandCount {
            bandMeanDb[i] = bandDb[i]
            localMeanDb[i] = bandDb[i]
            previousBandDb[i] = bandDb[i]
        }
        sharedMotionScaleDb = (Constants.sharedMotionMinDb + Constants.sharedMotionMaxDb) * 0.5
    }

    // MARK: - Classification

    private func classifyLoudness() {
        let qToN = smoothstep(Constants.quietFloorDbFS, Constants.quietToNormalDbFS, shortTermRmsDbFS)
        let nToL = smoothstep(Constants.normalToLoudDbFS, Constants.loudFloorDbFS, shortTermRmsDbFS)

        let quietWeight = 1 - qToN
        let normalWeight = qToN * (1 - nToL)
        let loudWeight = nToL

        lastBaseScale =
            Constants.baseScaleQuiet * quietWeight +
            Constants.baseScaleNormal * normalWeight +
            Constants.baseScaleLoud * loudWeight
        lastMotionScale =
            Constants.motionScaleQuiet * quietWeight +
            Constants.motionScaleNormal * normalWeight +
            Constants.motionScaleLoud * loudWeight

        // At quiet, retain only a fraction of motion; full motion from normal up.
        lastGlobalMotionGate = lerp(Constants.quietMotionGateFloor, 1.0, t: qToN)

        // Compression boost: loud AND low-crest (compressed master) -> more motion.
        let crestGate = smoothstep(Constants.compressedCrestDb, Constants.dynamicCrestDb, crestDb)
        lastCompressionBoost = 1.0 + Constants.compressionBoostMax * loudWeight * (1 - crestGate)

        if quietWeight >= normalWeight, quietWeight >= loudWeight {
            lastLoudnessState = "quiet"
        } else if loudWeight >= normalWeight {
            lastLoudnessState = "loud"
        } else {
            lastLoudnessState = "normal"
        }
    }

    // MARK: - Target computation

    private func computeTarget() {
        // 1. Three-segment loudness -> budgets + gates.
        classifyLoudness()

        // 2. Calibrate band dB with the fixed (non-adaptive) spectral tilt. This
        //    counteracts real music's high-frequency falloff so highs stay
        //    visible; it never tracks song history (no per-band AGC).
        for i in 0..<Constants.bandCount {
            calibratedBandDbBuffer[i] = bandDb[i] + Constants.fixedSpectralTiltDb[i]
        }

        // 3. Base: calibrated band dB relative to global mean power, shaped by
        //    the mid-peak silhouette. High bands get an absolute noise gate (no
        //    fake floor when silent) plus a one-shot soft gamma so they read as
        //    visible-but-low. No global gamma < 1.
        let baseReferenceDb = fftMeanPowerDb + Constants.baseReferenceOffsetDb
        for i in 0..<Constants.bandCount {
            let rawBase = clamp((calibratedBandDbBuffer[i] - baseReferenceDb) / Constants.baseRangeDb, min: 0, max: 1)
            var shaped = rawBase * Constants.baseShapeWeight[i]
            if i >= Constants.highBandStartIndex {
                let rel = calibratedBandDbBuffer[i] - fftMeanPowerDb
                let highGate = smoothstep(Constants.highBandNoiseFloorDb, Constants.highBandVisibleDb, rel)
                shaped *= highGate
                shaped = pow(shaped, Constants.highBandGamma)
            }
            rawBaseBuffer[i] = shaped
        }
        spatialSmooth(&rawBaseBuffer, kernel: Constants.baseSpatialKernel)
        for i in 0..<Constants.bandCount {
            baseFinalBuffer[i] = rawBaseBuffer[i] * lastBaseScale
        }

        // 4. Motion (separate path).
        computeMotion()

        // 5. Advance previous-frame band dB for next tick's flux.
        for i in 0..<Constants.bandCount {
            previousBandDb[i] = bandDb[i]
        }
    }

    private func computeMotion() {
        // 3a. Raw motion dB per band: positive flux + slow excursion + contrast.
        for i in 0..<Constants.bandCount {
            let fluxDb = max(0, bandDb[i] - previousBandDb[i])
            let excursionDb = max(0, bandDb[i] - bandMeanDb[i])
            let contrastDb = max(0, bandDb[i] - localMeanDb[i])
            var m =
                Constants.fluxWeight * fluxDb +
                Constants.excursionWeight * excursionDb +
                Constants.contrastWeight * contrastDb
            // Soft knee to keep extreme onsets from saturating a single band.
            if m > Constants.motionSoftKneeDb {
                let excess = m - Constants.motionSoftKneeDb
                let ceiling = Constants.motionMaxDb - Constants.motionSoftKneeDb
                m = Constants.motionSoftKneeDb + ceiling * (1 - exp(-excess / max(1, ceiling)))
            }
            m = min(m, Constants.motionMaxDb)
            rawMotionDbBuffer[i] = m
        }

        // 3b. Common-mode removal (per-band factor; Sub/Bass stronger so a
        //     broadband vocal onset doesn't average into low-freq pulses). A
        //     small residual global pulse is kept so the spectrum breathes.
        let commonMotionDb = median(rawMotionDbBuffer)
        lastCommonMotionDb = commonMotionDb
        let globalPulseDb = min(commonMotionDb * Constants.globalPulseGain, Constants.globalPulseCapDb)
        for i in 0..<Constants.bandCount {
            let specific = max(0, rawMotionDbBuffer[i] - commonMotionDb * Constants.commonModeRemoval[i])
            motionDbBuffer[i] = specific + globalPulseDb
        }

        // 3c. Shared motion scale (ALL bands share ONE; no per-band AGC). Track
        //     a high percentile slowly, clamped to a sane range.
        let percentile = percentileValue(motionDbBuffer, fraction: Constants.sharedMotionPercentile)
        let scaleAlpha = 1 - exp(-lastDt / Constants.sharedMotionTau)
        let targetScale = clamp(percentile, min: Constants.sharedMotionMinDb, max: Constants.sharedMotionMaxDb)
        sharedMotionScaleDb += scaleAlpha * (targetScale - sharedMotionScaleDb)
        sharedMotionScaleDb = clamp(sharedMotionScaleDb, min: Constants.sharedMotionMinDb, max: Constants.sharedMotionMaxDb)

        // 3d. Low-frequency prominence gate: only let Sub/Bass move when their
        //     energy actually exceeds the vocal-body bands (LMid/Mid). Vocal
        //     fundamentals, leakage, and broadband common-mode then can't flap
        //     the left side; real kicks/bass still rise.
        let lowEnergy = max(bandDb[0], bandDb[1])
        let neighborEnergy = (bandDb[2] + bandDb[3]) * 0.5
        let lowProminenceDb = lowEnergy - neighborEnergy
        lastLowProminenceGate = smoothstep(
            Constants.lowProminenceStartDb, Constants.lowProminenceFullDb, lowProminenceDb
        )

        // 3e. Normalize, then apply: per-band energy gate (absolute silence),
        //     global quiet gate, compression boost, low-prominence restraint
        //     (Sub/Bass), and high-band noise gate. Shape weight is applied last.
        for i in 0..<Constants.bandCount {
            var norm = clamp(motionDbBuffer[i] / sharedMotionScaleDb, min: 0, max: 1)
            let relRaw = bandDb[i] - fftMeanPowerDb
            let energyGate = smoothstep(Constants.bandEnergyGateFloorDb, Constants.bandEnergyGateCeilDb, relRaw)
            norm *= energyGate
            norm *= lastGlobalMotionGate
            norm *= lastCompressionBoost
            if i == 0 {
                norm *= lerp(Constants.subMotionFloor, Constants.subMotionCeil, t: lastLowProminenceGate)
            } else if i == 1 {
                norm *= lerp(Constants.bassMotionFloor, Constants.bassMotionCeil, t: lastLowProminenceGate)
            }
            if i >= Constants.highBandStartIndex {
                let relCal = calibratedBandDbBuffer[i] - fftMeanPowerDb
                let highGate = smoothstep(Constants.highBandNoiseFloorDb, Constants.highBandVisibleDb, relCal)
                norm *= highGate
            }
            normalizedMotionBuffer[i] = norm
        }

        // 3f. Final motion target = normalized * motionScale * motionShapeWeight.
        //     No spatial smoothing on motion (keeps per-band contrast).
        for i in 0..<Constants.bandCount {
            motionFinalBuffer[i] = normalizedMotionBuffer[i] * lastMotionScale * Constants.motionShapeWeight[i]
        }
    }

    // MARK: - Envelopes (separate base / motion time scales)

    private func applyEnvelopes(dt: Float, hasInput: Bool) {
        if hasInput {
            let baseAttack = 1 - exp(-dt / Constants.baseAttackTau)
            let baseRelease = 1 - exp(-dt / Constants.baseReleaseTau)
            for i in 0..<Constants.bandCount {
                let bt = baseFinalBuffer[i]
                let bc = baseCurrent[i]
                baseCurrent[i] = bt > bc
                    ? bc + (bt - bc) * baseAttack
                    : bc + (bt - bc) * baseRelease
                let mt = motionFinalBuffer[i]
                let mc = motionCurrent[i]
                let mAttack = 1 - exp(-dt / Constants.motionAttackTau[i])
                let mRelease = 1 - exp(-dt / Constants.motionReleaseTau[i])
                motionCurrent[i] = mt > mc
                    ? mc + (mt - mc) * mAttack
                    : mc + (mt - mc) * mRelease
            }
        } else {
            // Slow fade on stall so a glitch doesn't freeze bars.
            let alpha = 1 - exp(-dt / Constants.stallDecayTau)
            for i in 0..<Constants.bandCount {
                baseCurrent[i] += (0 - baseCurrent[i]) * alpha
                motionCurrent[i] += (0 - motionCurrent[i]) * alpha
            }
        }
        for i in 0..<Constants.bandCount {
            targetBuffer[i] = clamp(baseCurrent[i] + motionCurrent[i], min: 0, max: 1)
        }
    }

    // MARK: - Helpers

    private func spatialSmooth(_ values: inout [Float], kernel: [Float]) {
        guard values.count >= 3, kernel.count == 3 else { return }
        let k0 = kernel[0], k1 = kernel[1], k2 = kernel[2]
        let first = values[0]
        let last = values[values.count - 1]

        var prev = values[0]
        for i in 1..<(values.count - 1) {
            let curr = values[i]
            let next = values[i + 1]
            let old = values[i]
            values[i] = k0 * prev + k1 * curr + k2 * next
            prev = old
        }

        values[0] = (1 - k0) * first + k0 * values[1]
        values[values.count - 1] = (1 - k2) * last + k2 * values[values.count - 2]
    }

    private func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        sorted.sort()
        let n = sorted.count
        return n % 2 == 0 ? (sorted[n / 2 - 1] + sorted[n / 2]) * 0.5 : sorted[n / 2]
    }

    private func percentileValue(_ values: [Float], fraction: Float) -> Float {
        guard !values.isEmpty else { return 0 }
        var sorted = values
        sorted.sort()
        let idx = Swift.max(0, Swift.min(sorted.count - 1, Int(fraction * Float(sorted.count - 1))))
        return sorted[idx]
    }

    private func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = clamp((x - edge0) / (edge1 - edge0), min: 0, max: 1)
        return t * t * (3 - 2 * t)
    }

    private func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.max(min, Swift.min(max, value))
    }

    private func lerp(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * t
    }
}

// MARK: - Diagnostics

nonisolated private struct SpectrumDiagnostics {
    var lastEmitTime: TimeInterval = 0
    var frameCount: Int = 0

    var sumRmsDbFS: Float = 0
    var sumPeakDbFS: Float = 0
    var sumCrestDb: Float = 0
    var sumBaseScale: Float = 0
    var sumMotionScale: Float = 0
    var sumGlobalMotionGate: Float = 0
    var sumCompressionBoost: Float = 0
    var sumSharedMotionScale: Float = 0
    var sumCommonMotion: Float = 0
    var sumLowProminence: Float = 0

    // Volume-compensation diagnostics.
    var sumRawRms: Float = 0
    var sumPlayerVolume: Float = 0
    var sumCompensatedRms: Float = 0

    var sumBaseMean: Float = 0
    var basePeak: Float = 0
    var sumMotionMean: Float = 0
    var motionPeak: Float = 0
    var sumFinalMean: Float = 0
    var finalPeak: Float = 0
    var sumBandStdDev: Float = 0

    // Scheduling diagnostics.
    var sumPending: Float = 0
    var maxFrameAgeMs: Float = -1
    var firstProduced: UInt64 = 0
    var firstDisplayed: UInt64 = 0
    var firstCoalesced: UInt64 = 0
    var lastProduced: UInt64 = 0
    var lastDisplayed: UInt64 = 0
    var lastCoalesced: UInt64 = 0
    var schedulingCaptured = false

    var loudnessCounts: [String: Int] = [:]

    var perBandBaseSum: [Float] = Array(repeating: 0, count: SpectrumProcessor.Constants.bandCount)
    var perBandMotionSum: [Float] = Array(repeating: 0, count: SpectrumProcessor.Constants.bandCount)
    var perBandFinalSum: [Float] = Array(repeating: 0, count: SpectrumProcessor.Constants.bandCount)

    mutating func reset() {
        lastEmitTime = 0
        frameCount = 0
        sumRmsDbFS = 0
        sumPeakDbFS = 0
        sumCrestDb = 0
        sumBaseScale = 0
        sumMotionScale = 0
        sumGlobalMotionGate = 0
        sumCompressionBoost = 0
        sumSharedMotionScale = 0
        sumCommonMotion = 0
        sumLowProminence = 0
        sumRawRms = 0
        sumPlayerVolume = 0
        sumCompensatedRms = 0
        sumBaseMean = 0
        basePeak = 0
        sumMotionMean = 0
        motionPeak = 0
        sumFinalMean = 0
        finalPeak = 0
        sumBandStdDev = 0
        sumPending = 0
        maxFrameAgeMs = -1
        firstProduced = 0
        firstDisplayed = 0
        firstCoalesced = 0
        lastProduced = 0
        lastDisplayed = 0
        lastCoalesced = 0
        schedulingCaptured = false
        loudnessCounts.removeAll()
        perBandBaseSum = Array(repeating: 0, count: SpectrumProcessor.Constants.bandCount)
        perBandMotionSum = Array(repeating: 0, count: SpectrumProcessor.Constants.bandCount)
        perBandFinalSum = Array(repeating: 0, count: SpectrumProcessor.Constants.bandCount)
    }

    mutating func recordFrame(
        rmsDbFS: Float,
        peakDbFS: Float,
        crestDb: Float,
        loudnessState: String,
        baseScale: Float,
        motionScale: Float,
        globalMotionGate: Float,
        compressionBoost: Float,
        sharedMotionScaleDb: Float,
        commonMotionDb: Float,
        lowProminenceGate: Float,
        rawRms: Float,
        playerVolume: Float,
        compensatedRms: Float,
        scheduling: (produced: UInt64, displayed: UInt64, coalesced: UInt64, pending: Int, frameAgeMs: Float),
        baseBands: [Float],
        motionBands: [Float],
        finalBands: [Float]
    ) {
        frameCount += 1
        sumRmsDbFS += rmsDbFS
        sumPeakDbFS += peakDbFS
        sumCrestDb += crestDb
        sumBaseScale += baseScale
        sumMotionScale += motionScale
        sumGlobalMotionGate += globalMotionGate
        sumCompressionBoost += compressionBoost
        sumSharedMotionScale += sharedMotionScaleDb
        sumCommonMotion += commonMotionDb
        sumLowProminence += lowProminenceGate
        sumRawRms += rawRms
        sumPlayerVolume += playerVolume
        sumCompensatedRms += compensatedRms
        loudnessCounts[loudnessState, default: 0] += 1

        // Scheduling: capture the window-start cumulative counters on the first
        // frame so the emit can report per-window deltas.
        if !schedulingCaptured {
            firstProduced = scheduling.produced
            firstDisplayed = scheduling.displayed
            firstCoalesced = scheduling.coalesced
            schedulingCaptured = true
        }
        lastProduced = scheduling.produced
        lastDisplayed = scheduling.displayed
        lastCoalesced = scheduling.coalesced
        sumPending += Float(scheduling.pending)
        if scheduling.frameAgeMs > maxFrameAgeMs { maxFrameAgeMs = scheduling.frameAgeMs }

        let bands = SpectrumProcessor.Constants.bandCount
        var baseSum: Float = 0
        var motionSum: Float = 0
        var finalSum: Float = 0
        for i in 0..<bands {
            baseSum += baseBands[i]
            motionSum += motionBands[i]
            finalSum += finalBands[i]
            perBandBaseSum[i] += baseBands[i]
            perBandMotionSum[i] += motionBands[i]
            perBandFinalSum[i] += finalBands[i]
            if baseBands[i] > basePeak { basePeak = baseBands[i] }
            if motionBands[i] > motionPeak { motionPeak = motionBands[i] }
            if finalBands[i] > finalPeak { finalPeak = finalBands[i] }
        }
        let fmean = finalSum / Float(bands)
        sumFinalMean += fmean
        sumBaseMean += baseSum / Float(bands)
        sumMotionMean += motionSum / Float(bands)

        // Cross-band std dev of the final output: low values mean the bands have
        // been flattened to near-equal height (the v2 regression).
        var variance: Float = 0
        for i in 0..<bands {
            let d = finalBands[i] - fmean
            variance += d * d
        }
        sumBandStdDev += sqrt(variance / Float(bands))
    }

    mutating func emitIfNeeded() {
        guard LogConfig.spectrumDebugEnabled, frameCount > 0 else { return }

        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastEmitTime >= SpectrumProcessor.Constants.diagnosticsInterval else { return }

        let n = Float(frameCount)
        let bands = Float(SpectrumProcessor.Constants.bandCount)

        let avgRms = sumRmsDbFS / n
        let avgPeak = sumPeakDbFS / n
        let avgCrest = sumCrestDb / n
        let avgBaseScale = sumBaseScale / n
        let avgMotionScale = sumMotionScale / n
        let avgGate = sumGlobalMotionGate / n
        let avgBoost = sumCompressionBoost / n
        let avgSharedScale = sumSharedMotionScale / n
        let avgCommon = sumCommonMotion / n
        let avgLowProm = sumLowProminence / n
        let avgRawRms = sumRawRms / n
        let avgVol = sumPlayerVolume / n
        let avgCompRms = sumCompensatedRms / n
        let avgBaseMean = sumBaseMean / n
        let avgMotionMean = sumMotionMean / n
        let avgFinalMean = sumFinalMean / n
        let avgBandStd = sumBandStdDev / n
        let avgPending = sumPending / n
        let dProduced = lastProduced &- firstProduced
        let dDisplayed = lastDisplayed &- firstDisplayed
        let dCoalesced = lastCoalesced &- firstCoalesced

        let state = loudnessCounts.max { $0.value < $1.value }?.key ?? "-"

        let baseBands = perBandBaseSum.map { String(format: "%.2f", $0 / n) }.joined(separator: " ")
        let motionBands = perBandMotionSum.map { String(format: "%.2f", $0 / n) }.joined(separator: " ")
        let finalBands = perBandFinalSum.map { String(format: "%.2f", $0 / n) }.joined(separator: " ")

        Log.debug(
            "[Spectrum] rms=\(fmt(avgRms)) peak=\(fmt(avgPeak)) crest=\(fmt(avgCrest)) state=\(state) " +
            "baseScale=\(fmt(avgBaseScale)) motionScale=\(fmt(avgMotionScale)) " +
            "gate=\(fmt(avgGate)) boost=\(fmt(avgBoost)) lowProm=\(fmt(avgLowProm)) " +
            "sharedScale=\(fmt(avgSharedScale)) common=\(fmt(avgCommon)) " +
            "rawRms=\(sci(avgRawRms)) vol=\(fmt(avgVol)) compRms=\(sci(avgCompRms)) " +
            "baseMean=\(fmt(avgBaseMean)) basePeak=\(fmt(basePeak)) " +
            "motionMean=\(fmt(avgMotionMean)) motionPeak=\(fmt(motionPeak)) " +
            "finalMean=\(fmt(avgFinalMean)) finalPeak=\(fmt(finalPeak)) bandStd=\(fmt(avgBandStd))",
            category: .audio
        )
        Log.debug(
            "[Spectrum] sched: produced=\(dProduced) displayed=\(dDisplayed) coalesced=\(dCoalesced) " +
            "avgPending=\(fmt(avgPending)) maxAgeMs=\(fmt(maxFrameAgeMs)) frames=\(frameCount)",
            category: .audio
        )
        Log.debug(
            "[Spectrum] base=[\(baseBands)] motion=[\(motionBands)] final=[\(finalBands)]",
            category: .audio
        )

        reset()
        lastEmitTime = now
    }

    private func fmt(_ value: Float) -> String {
        String(format: "%.2f", value)
    }
    private func sci(_ value: Float) -> String {
        String(format: "%.3g", value)
    }
}
