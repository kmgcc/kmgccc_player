//
//  AudioVisualizationService.swift
//  myPlayer2
//
//  kmgccc_player - 9-Band Audio Visualizer Service
//  Provides smoothed, cubic-eased 9-band spectrum for skins.
//  Subscribes to AudioAnalysisHub for FFT data.
//

import Accelerate
import Foundation

nonisolated final class AudioVisualizationService: @unchecked Sendable {

    typealias Consumer = @MainActor ([Float]) -> Void

    private enum Constants {
        static let bandCount = 9
        static let uiUpdateHz: Double = 30
        static let staleDataThreshold: TimeInterval = 0.12
        static let staleRestartThreshold: TimeInterval = 0.80
        static let restartCooldown: TimeInterval = 1.20
        static let stopGracePeriod: TimeInterval = 0.35
        static let publishEpsilon: Float = 0.015
        static let forcePublishInterval: TimeInterval = 0.25
        static let defaultFFTSize = 1024
        static let defaultSampleRate: Float = 44_100
    }

    private let processor = SpectrumProcessor()
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

    private var liveWave: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var outputWave: [Float] = Array(repeating: 0, count: Constants.bandCount)
    private var lastPublishedWave: [Float] = Array(repeating: 0, count: Constants.bandCount)

    private var pendingMagnitudes: [Float] = []
    private var pendingFFTSize: Int = Constants.defaultFFTSize
    private var pendingSampleRate: Float = Constants.defaultSampleRate
    private var hasPendingFFT = false

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
        processingQueue.async { [weak self] in
            guard let self else { return }
            guard self.isPlaying != isPlaying else { return }

            self.isPlaying = isPlaying
            if isPlaying {
                self.pauseStartTime = nil
            } else if self.pauseStartTime == nil {
                self.pauseStartTime = Date().timeIntervalSinceReferenceDate
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
        isPlaying = false
        pauseStartTime = nil
        processor.reset()
        liveWave = Array(repeating: 0, count: Constants.bandCount)
        outputWave = Array(repeating: 0, count: Constants.bandCount)
        lastPublishedWave = Array(repeating: 0, count: Constants.bandCount)
        pendingMagnitudes = []
        pendingFFTSize = Constants.defaultFFTSize
        pendingSampleRate = Constants.defaultSampleRate
        hasPendingFFT = false
        poseBlend = 0
        lastDataTime = now
        lastTickTime = now
        lastPublishTime = 0
        lastRestartAttemptTime = 0

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
        liveWave = zeroWave
        outputWave = zeroWave
        lastPublishedWave = zeroWave
        pendingMagnitudes = []
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

        if isExternalMode {
            liveWave = ExternalPlaybackSpectrumSimulator.shared.lastWave
            lastDataTime = now
        } else if hasPendingFFT {
            liveWave = processor.process(
                magnitudes: pendingMagnitudes,
                fftSize: pendingFFTSize,
                sampleRate: pendingSampleRate
            )
            hasPendingFFT = false
        } else if now - lastDataTime > Constants.staleDataThreshold {
            liveWave = processor.process(
                magnitudes: [],
                fftSize: pendingFFTSize,
                sampleRate: pendingSampleRate
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

        let tau: Float = 0.10
        let factor = 1.0 - exp(-dt / tau)
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

        for callback in callbacks {
            Task { @MainActor in
                callback(wave)
            }
        }
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
}

// MARK: - Spectrum Processing

nonisolated final class SpectrumProcessor: @unchecked Sendable {

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
        static let cubicPower: Float = 3.0
        static let attack: Float = 0.47
        static let release: Float = 0.35
        // 4. Per-band Small Gates
        static let bandGates: [Float] = [
            0.01, 0.01, 0.01, 0.008, 0.008, 0.005, 0.005, 0.003, 0.003,
        ]
    }

    private let bandCount: Int = 9
    private var smoothedBands: [Float]

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
        var scaledBins = [Float](repeating: 0, count: count)

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

            scaledBins[i] = max(0.0, scaled)
        }
        return scaledBins
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
